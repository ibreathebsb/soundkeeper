import Foundation

/// A running Sound Keeper: the single instance lock, the keeper, power events and the status file.
/// It is what the command line tool and the menu bar app have in common.
///
/// Everything happens on the main queue.
public final class KeeperService {
    public let paths: Paths
    public let frontend: String

    /// Called when something is changed: sessions, their states, settings, reasons to be silent.
    public var onStatusChanged: ((KeeperStatus) -> Void)?

    /// Settings of the last start. They are still reported when the service is paused.
    public private(set) var settings = Settings()

    private let lock: InstanceLock
    private let statusFile: StatusFile
    private let startDate = Date()
    private var keeper: SoundKeeper?
    private var monitor: PowerMonitor?

    public init(paths: Paths = .standard(), frontend: String) {
        self.paths = paths
        self.frontend = frontend
        self.lock = InstanceLock(url: paths.lockFile)
        self.statusFile = StatusFile(url: paths.statusFile)
    }

    /// Becomes the only Sound Keeper of the user. A previously started instance is stopped, like the original does.
    public func acquireLock() throws {
        try lock.acquire(replacingExisting: true)
    }

    public var isRunning: Bool { keeper != nil }

    /// Starts keeping audio outputs awake. If it's already running, it is restarted with the new settings.
    public func start(settings: Settings) {
        stopKeeper()
        self.settings = settings

        let keeper = SoundKeeper(settings: settings, audio: CoreAudioSystem()) { device in
            SoundSession(device: device, settings: settings)
        }
        keeper.onStatusChanged = { [weak self] in self?.publishStatus() }

        for reason in PowerMonitor.currentReasons(observeDisplay: settings.sleepWithDisplay, observeLock: settings.sleepWithLock) {
            keeper.setSleepReason(reason, active: true)
        }
        monitor = PowerMonitor(observeDisplay: settings.sleepWithDisplay, observeLock: settings.sleepWithLock) { [weak keeper] reason, active in
            keeper?.setSleepReason(reason, active: active)
        }

        self.keeper = keeper
        keeper.start()
        publishStatus()
    }

    /// Stops all streams, but stays the running instance.
    public func pause() {
        stopKeeper()
        publishStatus()
    }

    /// Stops everything before the process exits.
    public func shutdown() {
        stopKeeper()
        statusFile.remove()
        lock.release()
    }

    public var status: KeeperStatus {
        KeeperStatus(
            pid: getpid(),
            version: AppInfo.version,
            frontend: frontend,
            started: startDate,
            arguments: settings.arguments,
            settings: settings.summary,
            paused: keeper == nil,
            sleeping: keeper?.currentSleepReasons.map(\.rawValue) ?? [],
            sessions: keeper?.sessionStatuses ?? []
        )
    }

    private func stopKeeper() {
        monitor = nil
        keeper?.onStatusChanged = nil
        keeper?.shutdown()
        keeper = nil
    }

    private func publishStatus() {
        let status = self.status
        if lock.isHeld { statusFile.write(status) }
        onStatusChanged?(status)
    }
}
