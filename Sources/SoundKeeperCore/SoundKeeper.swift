import CoreAudio
import Foundation

/// Why Sound Keeper has to be silent for a while.
public enum SleepReason: String, CaseIterable, Codable {
    /// The Mac is going to sleep.
    case systemSleep = "system sleep"
    /// All displays are sleeping (enabled by the "sleepd" setting).
    case displayOff = "display is off"
    /// The screen is locked (enabled by the "sleepl" setting).
    case screenLocked = "screen is locked"
    /// Another user is at the Mac (fast user switching), so audio hardware belongs to that user.
    case sessionInactive = "user session is inactive"
}

/// A rough state of a session, for status indicators.
public enum SessionHealth: String, Codable {
    /// The output is being kept awake.
    case active
    /// It is waiting for something that is not an error, like the end of exclusive use of the device.
    case waiting
    /// It can't start. It keeps trying.
    case failing
    /// It is stopped, or the device is gone.
    case inactive
}

/// What Sound Keeper is doing right now.
public struct KeeperStatus: Codable, Equatable {
    public struct Session: Codable, Equatable {
        public var name: String
        public var uid: String
        public var transport: String
        public var health: SessionHealth
        public var state: String

        public init(name: String, uid: String, transport: String, health: SessionHealth, state: String) {
            self.name = name
            self.uid = uid
            self.transport = transport
            self.health = health
            self.state = state
        }
    }

    public var pid: Int32
    public var version: String
    /// What kind of instance it is: "command line tool" or "menu bar app".
    public var frontend: String
    public var started: Date
    public var arguments: [String]
    public var settings: String
    /// Sound Keeper is turned off by the user (the menu bar app only).
    public var paused: Bool
    /// Why it is silent at the moment.
    public var sleeping: [String]
    public var sessions: [Session]

    public init(
        pid: Int32 = getpid(),
        version: String = AppInfo.version,
        frontend: String,
        started: Date = Date(),
        arguments: [String],
        settings: String,
        paused: Bool = false,
        sleeping: [String] = [],
        sessions: [Session] = []
    ) {
        self.pid = pid
        self.version = version
        self.frontend = frontend
        self.started = started
        self.arguments = arguments
        self.settings = settings
        self.paused = paused
        self.sleeping = sleeping
        self.sessions = sessions
    }
}

/// Decides which devices have to be kept awake right now and runs a session for each of them.
/// The counterpart of CSoundKeeper of the original.
///
/// Everything happens on the main queue.
public final class SoundKeeper {
    public typealias SessionFactory = (OutputDevice) -> KeepSession

    public let settings: Settings
    /// Called on the main queue when sessions or their states are changed.
    public var onStatusChanged: (() -> Void)?

    private let audio: AudioSystem
    private let makeSession: SessionFactory
    private let queue = DispatchQueue.main

    private var isStarted = false
    private var sessions: [AudioDeviceID: KeepSession] = [:]
    private var sleepReasons: Set<SleepReason> = []
    private var reconcileWork: DispatchWorkItem?
    private var reconcileDeadline: DispatchTime?
    private var watchdog: DispatchSourceTimer?
    private var isDummy = false

    /// Device notifications come in bursts, so they are collapsed.
    public static let debounceInterval: TimeInterval = 0.2
    /// Audio devices need some time to come back after the Mac wakes up.
    public static let wakeDelay: TimeInterval = 1.0
    public static let watchdogInterval: TimeInterval = 10

    public init(settings: Settings, audio: AudioSystem, makeSession: @escaping SessionFactory) {
        self.settings = settings
        self.audio = audio
        self.makeSession = makeSession
    }

    public var activeDeviceIDs: Set<AudioDeviceID> { Set(sessions.keys) }
    /// Why it is silent at the moment, in a stable order.
    public var currentSleepReasons: [SleepReason] { SleepReason.allCases.filter(sleepReasons.contains) }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        audio.configureProcess(preventSystemSleep: settings.preventSystemSleep)
        audio.onDevicesChanged = { [weak self] in self?.scheduleReconcile() }
        audio.onServiceRestarted = { [weak self] in self?.audioServiceRestarted() }
        audio.startObserving()

        reconcile()
        startWatchdog()
    }

    public func shutdown() {
        guard isStarted else { return }
        isStarted = false

        reconcileWork?.cancel()
        reconcileWork = nil
        reconcileDeadline = nil
        watchdog?.cancel()
        watchdog = nil
        audio.stopObserving()
        audio.onDevicesChanged = nil
        audio.onServiceRestarted = nil

        stopSessions(Array(sessions.keys))
    }

    /// Stops everything immediately when a reason to sleep appears, and starts again when the last one is gone.
    public func setSleepReason(_ reason: SleepReason, active: Bool) {
        if active {
            guard sleepReasons.insert(reason).inserted else { return }
            Log.info("Going silent: \(reason.rawValue).")
            // It has to be done right now: the system waits for it when it goes to sleep.
            if isStarted { reconcile() }
        } else {
            guard sleepReasons.remove(reason) != nil else { return }
            Log.info("No longer applies: \(reason.rawValue).")
            if isStarted { scheduleReconcile(after: reason == .systemSleep ? Self.wakeDelay : Self.debounceInterval) }
        }
    }

    /// Requests are collapsed into one reconciliation. The earliest requested time wins.
    public func scheduleReconcile(after delay: TimeInterval = SoundKeeper.debounceInterval) {
        guard isStarted else { return }

        let deadline = DispatchTime.now() + delay
        if let pending = reconcileDeadline, pending <= deadline { return }

        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        reconcileDeadline = deadline
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    /// Makes the set of running sessions match the set of devices that have to be kept awake.
    /// Sessions of devices that are still wanted are not touched, so their streams are not interrupted.
    public func reconcile() {
        reconcileWork?.cancel()
        reconcileWork = nil
        reconcileDeadline = nil
        guard isStarted else { return }

        var wanted: [OutputDevice] = []
        if sleepReasons.isEmpty {
            wanted = decideDevices(settings: settings, snapshot: audio.snapshot()).filter(\.keep).map(\.device)
        }
        let wantedIDs = Set(wanted.map(\.id))

        stopSessions(sessions.filter { !wantedIDs.contains($0.key) || $0.value.isDead }.map(\.key))

        for device in wanted where sessions[device.id] == nil {
            let session = makeSession(device)
            // Not too fast: a dying device can stay in the list of devices for a moment.
            session.onInvalidated = { [weak self] in self?.scheduleReconcile(after: Self.wakeDelay) }
            session.onStateChanged = { [weak self] in self?.publishStatus() }
            sessions[device.id] = session
            session.start()
        }

        let isDummyNow = sessions.isEmpty && sleepReasons.isEmpty
        if isDummyNow && !isDummy {
            Log.info("No suitable devices found. Working as a dummy...")
        }
        isDummy = isDummyNow

        publishStatus()
    }

    public var sessionStatuses: [KeeperStatus.Session] {
        sessions.values
            .sorted { $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending }
            .map {
                KeeperStatus.Session(
                    name: $0.device.name,
                    uid: $0.device.uid,
                    transport: $0.device.transport.name,
                    health: $0.health,
                    state: $0.stateDescription
                )
            }
    }

    private func stopSessions(_ ids: [AudioDeviceID]) {
        for id in ids {
            guard let session = sessions.removeValue(forKey: id) else { continue }
            session.onInvalidated = nil
            session.onStateChanged = nil
            session.stop()
            if !session.isDead {
                Log.info("Stopped keeping \"\(session.device.name)\" awake.")
            }
        }
    }

    private func publishStatus() {
        onStatusChanged?()
    }

    /// All audio objects are gone together with the old audio server. Start from scratch.
    private func audioServiceRestarted() {
        Log.warning("The audio server was restarted. Restarting all streams.")
        stopSessions(Array(sessions.keys))
        audio.configureProcess(preventSystemSleep: settings.preventSystemSleep)

        // Listeners of the hardware are expected to survive it, but nothing is lost by registering them again.
        audio.stopObserving()
        audio.startObserving()

        scheduleReconcile(after: Self.wakeDelay)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.watchdogFired() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogFired() {
        guard isStarted, sleepReasons.isEmpty else { return }

        for session in Array(sessions.values) {
            session.checkHealth()
        }

        // There are no notifications when a device is renamed, so selection by name is re-evaluated periodically.
        switch settings.devices {
        case .marked, .named: scheduleReconcile()
        default: break
        }
    }
}
