import CoreAudio
import Foundation
import SoundKeeperCore
import Testing

/// Tests with real audio hardware. They are silent, but they are not run by default:
///
///     SOUNDKEEPER_HARDWARE_TESTS=1 make test
///
/// They use built-in speakers when those are not the default output and nothing is playing on them, so nothing
/// that the user is listening to is touched. It is a good idea to run them with sanitizers too:
///
///     SOUNDKEEPER_HARDWARE_TESTS=1 swift test --sanitize=address --filter HardwareTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOUNDKEEPER_HARDWARE_TESTS"] != nil), .serialized)
struct HardwareTests {

    private func idleDevice() -> OutputDevice? {
        let snapshot = CoreAudioSystem().snapshot()
        return snapshot.devices.first { $0.transport == .builtIn && $0.id != snapshot.defaultOutputID && !$0.isRunningSomewhere }
    }

    private func isAwake(_ device: OutputDevice) -> Bool {
        CoreAudioSystem().snapshot().devices.first { $0.id == device.id }?.isRunningSomewhere ?? false
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// All stream types. Amplitudes are so low that nothing can be heard.
    private var allStreams: [Settings] {
        get throws {
            try ["fluctuate", "zero", "openonly", "sine -f 1 -a 0.001", "white -a 0.001", "brown -a 0.001 -l 0.05 -w 0.05", "pink -a 0.001"].map {
                try SettingsParser.parse(arguments: $0.split(separator: " ").map(String.init)).settings
            }
        }
    }

    @Test func keepsTheDeviceAwakeWhileItIsRunning() async throws {
        let device = try #require(idleDevice(), "there is no idle built-in output to test with")
        Log.consoleLevel = nil
        CoreAudioSystem().configureProcess(preventSystemSleep: false)

        for settings in try allStreams {
            #expect(!isAwake(device))

            let session = SoundSession(device: device, settings: settings)
            var stateChanges = 0
            session.onStateChanged = { stateChanges += 1 }

            session.start()
            #expect(session.health == .active, "\(settings.stream)")
            #expect(stateChanges == 1)

            try await pause(0.4)
            #expect(isAwake(device), "\(settings.stream)")

            // The stream is flowing, so the watchdog has nothing to do.
            session.checkHealth()
            try await pause(0.3)
            session.checkHealth()
            session.checkHealth()
            #expect(session.health == .active, "\(settings.stream)")
            #expect(stateChanges == 1)

            session.stop()
            #expect(session.health == .inactive)

            // The hardware goes to sleep as soon as nobody is playing: this is what Sound Keeper is for.
            try await pause(0.4)
            #expect(!isAwake(device), "\(settings.stream)")
        }
    }

    @Test func survivesRapidStartsAndStops() async throws {
        let device = try #require(idleDevice(), "there is no idle built-in output to test with")
        Log.consoleLevel = nil
        CoreAudioSystem().configureProcess(preventSystemSleep: false)

        for settings in try allStreams {
            for round in 0..<40 {
                let session = SoundSession(device: device, settings: settings)
                session.start()
                #expect(session.health == .active)

                // Sometimes the IO thread has time to render something, sometimes it's stopped right away.
                if round % 4 == 1 { try await pause(0.03) }
                if round % 10 == 5 { session.start() }
                if round % 7 == 3 { session.checkHealth() }

                session.stop()
                if round % 5 == 2 { session.stop() }
            }
        }

        // Sessions that are just dropped stop themselves.
        for _ in 0..<10 {
            let session = SoundSession(device: device, settings: Settings())
            session.start()
            #expect(session.health == .active)
        }

        // Render contexts are freed two seconds after they are stopped. Nothing may touch them by then.
        try await pause(2.5)
        #expect(!isAwake(device))
    }

    @Test func aDeviceThatDoesNotExistIsDead() {
        Log.consoleLevel = nil

        let ghost = OutputDevice(id: 999_999, uid: "ghost", name: "Ghost", transport: .usb)
        let session = SoundSession(device: ghost, settings: Settings())
        var invalidated = 0
        session.onInvalidated = { invalidated += 1 }

        session.start()
        #expect(session.isDead)
        #expect(invalidated == 1)
        #expect(session.health == .inactive)

        // Nothing happens with a dead session anymore.
        session.start()
        session.checkHealth()
        session.stop()
        #expect(session.isDead)
        #expect(invalidated == 1)
    }
}
