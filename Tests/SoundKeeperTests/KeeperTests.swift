import CoreAudio
import Foundation
import SoundKeeperCore
import Testing

private final class FakeAudio: AudioSystem {
    var devices: [OutputDevice] = []
    var defaultDevice: OutputDevice?
    var onDevicesChanged: (() -> Void)?
    var onServiceRestarted: (() -> Void)?

    private(set) var isObserving = false
    private(set) var configurations: [Bool] = []
    private(set) var snapshotCount = 0

    func configureProcess(preventSystemSleep: Bool) { configurations.append(preventSystemSleep) }

    func snapshot() -> AudioSnapshot {
        snapshotCount += 1
        return AudioSnapshot(devices: devices, defaultOutputID: defaultDevice?.id)
    }

    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
}

private final class FakeSession: KeepSession {
    let device: OutputDevice
    var isDead = false
    var health = SessionHealth.inactive
    var onInvalidated: (() -> Void)?
    var onStateChanged: (() -> Void)?

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var checks = 0

    init(device: OutputDevice) { self.device = device }

    var isRunning: Bool { health == .active }
    var stateDescription: String { isRunning ? "streaming" : "stopped" }

    func start() {
        starts += 1
        health = .active
        onStateChanged?()
    }

    func stop() {
        stops += 1
        health = .inactive
    }

    func checkHealth() { checks += 1 }

    /// The device is unplugged.
    func die() {
        isDead = true
        health = .inactive
        onInvalidated?()
    }
}

/// A keeper with fake hardware. All sessions that were ever created are remembered.
@MainActor
private final class Bench {
    let audio = FakeAudio()
    let keeper: SoundKeeper
    private(set) var created: [FakeSession] = []
    private(set) var statusChanges = 0

    init(_ line: String = "", devices: [OutputDevice] = [Fixture.jbl, Fixture.speakers], default defaultDevice: OutputDevice? = Fixture.jbl) throws {
        Log.consoleLevel = nil

        let settings = try SettingsParser.parse(arguments: line.split(separator: " ").map(String.init)).settings
        audio.devices = devices
        audio.defaultDevice = defaultDevice

        let box = Box()
        keeper = SoundKeeper(settings: settings, audio: audio) { device in
            let session = FakeSession(device: device)
            box.sessions.append(session)
            return session
        }
        self.box = box
        keeper.onStatusChanged = { [weak self] in self?.statusChanges += 1 }
    }

    private final class Box { var sessions: [FakeSession] = [] }
    private let box: Box

    var sessions: [FakeSession] { box.sessions }
    var running: [String] { box.sessions.filter(\.isRunning).map(\.device.name).sorted() }
    func session(_ device: OutputDevice) -> FakeSession? { box.sessions.last { $0.device.id == device.id } }
}

/// Waits until the condition becomes true. Timers can be late on a busy machine, so tests wait for what has to
/// happen instead of sleeping for a fixed time.
@MainActor
private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

@MainActor
@Suite struct KeeperTests {

    @Test func keepsTheDefaultOutput() throws {
        let bench = try Bench()
        #expect(bench.running == [])

        bench.keeper.start()
        #expect(bench.running == ["JBL GO 2"])
        #expect(bench.keeper.activeDeviceIDs == [Fixture.jbl.id])
        #expect(bench.audio.isObserving)
        #expect(bench.audio.configurations == [false])
        #expect(bench.statusChanges > 0)

        bench.keeper.shutdown()
        #expect(bench.running == [])
        #expect(bench.keeper.activeDeviceIDs.isEmpty)
        #expect(!bench.audio.isObserving)
    }

    @Test func tellsTheHardwareToKeepTheMacAwakeWhenAsked() throws {
        let bench = try Bench("nosleep")
        bench.keeper.start()
        #expect(bench.audio.configurations == [true])
    }

    @Test func followsTheDefaultOutput() throws {
        let bench = try Bench()
        bench.keeper.start()

        // The Bluetooth speaker is turned off: built-in speakers become the default output.
        bench.audio.devices = [Fixture.speakers]
        bench.audio.defaultDevice = Fixture.speakers
        bench.keeper.reconcile()

        #expect(bench.running == ["MacBook Pro Speakers"])
        #expect(bench.session(Fixture.jbl)?.stops == 1)

        // And it is turned on again.
        bench.audio.devices = [Fixture.speakers, Fixture.jbl]
        bench.audio.defaultDevice = Fixture.jbl
        bench.keeper.reconcile()

        #expect(bench.running == ["JBL GO 2"])
        #expect(bench.sessions.count == 3)
    }

    @Test func doesNotTouchSessionsThatAreStillWanted() throws {
        let bench = try Bench("all")
        bench.keeper.start()
        #expect(bench.running == ["JBL GO 2", "MacBook Pro Speakers"])

        // Nothing is changed, a new device appears, the default output is changed: streams are not interrupted.
        bench.keeper.reconcile()
        bench.audio.devices.append(Fixture.display)
        bench.keeper.reconcile()
        bench.audio.defaultDevice = Fixture.display
        bench.keeper.reconcile()

        #expect(bench.running == ["JBL GO 2", "LG HDR 4K", "MacBook Pro Speakers"])
        #expect(bench.sessions.count == 3)
        #expect(bench.sessions.allSatisfy { $0.starts == 1 && $0.stops == 0 })

        bench.audio.devices.removeAll { $0.id == Fixture.jbl.id }
        bench.keeper.reconcile()
        #expect(bench.running == ["LG HDR 4K", "MacBook Pro Speakers"])
        #expect(bench.session(Fixture.speakers)?.starts == 1)
    }

    @Test func worksAsADummyWithoutDevices() throws {
        let bench = try Bench(devices: [], default: nil)
        bench.keeper.start()
        #expect(bench.sessions.isEmpty)

        bench.audio.devices = [Fixture.jbl]
        bench.audio.defaultDevice = Fixture.jbl
        bench.keeper.reconcile()
        #expect(bench.running == ["JBL GO 2"])
    }

    @Test func isSilentWhileThereAreReasonsToSleep() throws {
        let bench = try Bench("all")
        bench.keeper.start()
        #expect(bench.running.count == 2)

        // Everything is stopped right away, without waiting for anything.
        bench.keeper.setSleepReason(.displayOff, active: true)
        #expect(bench.running == [])
        #expect(bench.keeper.currentSleepReasons == [.displayOff])

        bench.keeper.setSleepReason(.screenLocked, active: true)
        bench.keeper.setSleepReason(.displayOff, active: true)

        // Device changes don't start anything while it's silent.
        bench.audio.devices.append(Fixture.display)
        bench.keeper.reconcile()
        #expect(bench.running == [])

        // One reason is gone, another one is still here.
        bench.keeper.setSleepReason(.displayOff, active: false)
        bench.keeper.reconcile()
        #expect(bench.running == [])
        #expect(bench.keeper.currentSleepReasons == [.screenLocked])

        bench.keeper.setSleepReason(.screenLocked, active: false)
        bench.keeper.reconcile()
        #expect(bench.running == ["JBL GO 2", "LG HDR 4K", "MacBook Pro Speakers"])
        #expect(bench.keeper.currentSleepReasons == [])
    }

    @Test func startsOnItsOwnWhenTheReasonToSleepIsGone() async throws {
        let bench = try Bench()
        bench.keeper.start()

        bench.keeper.setSleepReason(.screenLocked, active: true)
        #expect(bench.running == [])

        bench.keeper.setSleepReason(.screenLocked, active: false)
        #expect(bench.running == [])
        #expect(try await eventually { bench.running == ["JBL GO 2"] })
    }

    @Test func doesNotStartWhenItIsStartedAsleep() throws {
        let bench = try Bench()
        bench.keeper.setSleepReason(.screenLocked, active: true)
        bench.keeper.start()
        #expect(bench.sessions.isEmpty)

        bench.keeper.setSleepReason(.screenLocked, active: false)
        bench.keeper.reconcile()
        #expect(bench.running == ["JBL GO 2"])
    }

    @Test func collapsesBurstsOfNotifications() async throws {
        let bench = try Bench()
        bench.keeper.start()
        let before = bench.audio.snapshotCount

        for _ in 0..<20 { bench.audio.onDevicesChanged?() }
        #expect(bench.audio.snapshotCount == before)

        #expect(try await eventually { bench.audio.snapshotCount > before })

        // It was done once, and nothing else is going to happen.
        try await Task.sleep(nanoseconds: UInt64(SoundKeeper.debounceInterval * 3 * 1_000_000_000))
        #expect(bench.audio.snapshotCount == before + 1)
    }

    @Test func anUrgentRequestIsNotDelayedByAPendingSlowOne() async throws {
        let bench = try Bench()
        bench.keeper.start()
        let before = bench.audio.snapshotCount

        // The speaker is turned off. Something asked for a reconciliation in the far future, and then the system
        // tells that the list of devices is changed, which has to be handled soon.
        bench.audio.devices = [Fixture.speakers]
        bench.audio.defaultDevice = Fixture.speakers
        bench.keeper.scheduleReconcile(after: 3600)
        bench.audio.onDevicesChanged?()

        #expect(try await eventually { bench.running == ["MacBook Pro Speakers"] })
        #expect(bench.audio.snapshotCount == before + 1)

        // A later request doesn't postpone the pending one either.
        bench.audio.devices = [Fixture.speakers, Fixture.jbl]
        bench.audio.defaultDevice = Fixture.jbl
        bench.audio.onDevicesChanged?()
        bench.keeper.scheduleReconcile(after: 3600)

        #expect(try await eventually { bench.running == ["JBL GO 2"] })
        #expect(bench.audio.snapshotCount == before + 2)
    }

    @Test func replacesSessionsOfDevicesThatAreGone() throws {
        let bench = try Bench()
        bench.keeper.start()
        let first = try #require(bench.session(Fixture.jbl))

        // The device died, but it is still in the list: a new session is made for it.
        first.die()
        bench.keeper.reconcile()
        #expect(bench.sessions.count == 2)
        #expect(bench.running == ["JBL GO 2"])
        #expect(first.stops == 1)

        // The device died and it is really gone.
        bench.session(Fixture.jbl)?.die()
        bench.audio.devices = [Fixture.speakers]
        bench.audio.defaultDevice = Fixture.speakers
        bench.keeper.reconcile()
        #expect(bench.running == ["MacBook Pro Speakers"])
    }

    @Test func startsFromScratchWhenTheAudioServerIsRestarted() throws {
        let bench = try Bench("all")
        bench.keeper.start()
        #expect(bench.sessions.count == 2)

        bench.audio.onServiceRestarted?()
        #expect(bench.running == [])
        #expect(bench.audio.configurations == [false, false])

        bench.keeper.reconcile()
        #expect(bench.running == ["JBL GO 2", "MacBook Pro Speakers"])
        #expect(bench.sessions.count == 4)
    }

    @Test func reportsSessions() throws {
        let bench = try Bench("all")
        #expect(bench.keeper.sessionStatuses.isEmpty)

        bench.keeper.start()
        let statuses = bench.keeper.sessionStatuses
        #expect(statuses.map(\.name) == ["JBL GO 2", "MacBook Pro Speakers"])
        #expect(statuses.map(\.transport) == ["Bluetooth", "Built-in"])
        #expect(statuses.allSatisfy { $0.health == .active && $0.state == "streaming" })
    }

    @Test func ignoresEverythingAfterShutdown() throws {
        let bench = try Bench()
        bench.keeper.start()
        bench.keeper.shutdown()

        bench.keeper.reconcile()
        bench.keeper.scheduleReconcile()
        bench.keeper.setSleepReason(.displayOff, active: true)
        bench.keeper.setSleepReason(.displayOff, active: false)
        #expect(bench.running == [])
        #expect(bench.sessions.count == 1)
    }
}
