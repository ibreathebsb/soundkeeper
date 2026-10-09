import Foundation
import SoundKeeperCore

/// State of the menu bar app and everything the user can do with it. It knows nothing about menus and windows.
public final class AppModel {

    /// The outside world. Tests replace it with fakes.
    public struct Environment {
        /// Starts keeping outputs awake with the settings, or restarts it if it's already started.
        public var start: (Settings) -> Void
        public var pause: () -> Void
        public var status: () -> KeeperStatus
        public var snapshot: () -> AudioSnapshot
        public var startsAtLogin: () -> Bool
        public var setStartsAtLogin: (Bool) throws -> Void

        public init(
            start: @escaping (Settings) -> Void,
            pause: @escaping () -> Void,
            status: @escaping () -> KeeperStatus,
            snapshot: @escaping () -> AudioSnapshot,
            startsAtLogin: @escaping () -> Bool,
            setStartsAtLogin: @escaping (Bool) throws -> Void
        ) {
            self.start = start
            self.pause = pause
            self.status = status
            self.snapshot = snapshot
            self.startsAtLogin = startsAtLogin
            self.setStartsAtLogin = setStartsAtLogin
        }
    }

    /// What the icon in the menu bar shows.
    public enum Activity: Equatable {
        /// Turned off by the user.
        case off
        /// Turned on, but there is nothing to keep awake right now.
        case idle
        /// At least one output is being kept awake.
        case active
        /// Some output can't be kept awake.
        case problem
    }

    public private(set) var settings: Settings
    public private(set) var isEnabled: Bool

    /// Called when anything that is shown to the user is changed.
    public var onChange: (() -> Void)?

    private let store: SettingsStore
    private let environment: Environment

    public init(store: SettingsStore, environment: Environment) {
        self.store = store
        self.environment = environment
        self.settings = store.settings
        self.isEnabled = store.isEnabled
    }

    /// Called once when the app is started.
    public func activate() {
        if isEnabled { environment.start(settings) }
        onChange?()
    }

    public var status: KeeperStatus { environment.status() }

    public var activity: Activity {
        guard isEnabled else { return .off }

        let sessions = status.sessions
        if sessions.contains(where: { $0.health == .failing }) { return .problem }
        if sessions.contains(where: { $0.health == .active }) { return .active }
        return .idle
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        isEnabled = enabled
        store.isEnabled = enabled
        if enabled { environment.start(settings) } else { environment.pause() }
        onChange?()
    }

    /// Changes settings. They are saved, and they are applied immediately.
    public func update(_ change: (inout Settings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }

        settings = changed
        store.settings = changed
        if isEnabled { environment.start(changed) }
        onChange?()
    }

    public var startsAtLogin: Bool { environment.startsAtLogin() }

    public func setStartsAtLogin(_ enabled: Bool) throws {
        try environment.setStartsAtLogin(enabled)
        onChange?()
    }

    /// Outputs that are present right now. Their names are remembered for the time when they are disconnected.
    public func outputs() -> AudioSnapshot {
        let snapshot = environment.snapshot()
        store.remember(snapshot.devices)
        return snapshot
    }

    /// Name of a device that was seen at least once.
    public func knownDeviceName(uid: String) -> String? {
        store.knownDevices[uid]
    }

    /// The status of the keeper is changed: sessions, their states, reasons to be silent.
    public func statusChanged() {
        onChange?()
    }
}
