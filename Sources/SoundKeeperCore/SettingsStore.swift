import Foundation

/// Settings of the menu bar app, saved in user defaults.
///
/// The settings are stored as the same command line arguments the command line tool understands, so there is
/// just one format, and `defaults read local.soundkeeper` shows something meaningful.
public final class SettingsStore {
    private enum Key {
        static let settings = "settings"
        static let enabled = "enabled"
        static let knownDevices = "knownDevices"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: Settings {
        get {
            guard let arguments = defaults.stringArray(forKey: Key.settings),
                  let invocation = try? SettingsParser.parse(arguments: arguments),
                  invocation.command == .run else {
                return Settings()
            }
            return invocation.settings
        }
        set {
            defaults.set(newValue.arguments, forKey: Key.settings)
        }
    }

    /// Whether Sound Keeper is turned on.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Names of devices that were seen, by UID. Selected devices have to be shown even when they are disconnected.
    public var knownDevices: [String: String] {
        get { defaults.dictionary(forKey: Key.knownDevices) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.knownDevices) }
    }

    public func remember(_ devices: [OutputDevice]) {
        var known = knownDevices
        for device in devices { known[device.uid] = device.name }
        if known != knownDevices { knownDevices = known }
    }
}

// What the user can do in the menu.
extension Settings {
    /// Explicitly selected devices: their UIDs or parts of their names.
    public var selectedDevices: [String] {
        if case .named(let patterns) = devices { return patterns }
        return []
    }

    /// Adds the device to the explicit selection or removes it from there. An empty selection means the default output.
    public mutating func toggleDevice(_ device: OutputDevice) {
        var selected = selectedDevices
        if selected.contains(where: { device.matches(pattern: $0) }) {
            // The device could be selected by a part of its name using the command line tool.
            selected.removeAll { device.matches(pattern: $0) }
        } else {
            selected.append(device.uid)
        }
        devices = selected.isEmpty ? .primary : .named(selected)
    }

    /// Removes a pattern (of a device that is not connected) from the explicit selection.
    public mutating func deselect(pattern: String) {
        let selected = selectedDevices.filter { $0 != pattern }
        devices = selected.isEmpty ? .primary : .named(selected)
    }

    /// Changes the stream type. Parameters that mean the same for the old and the new types are kept.
    public mutating func changeStream(to newStream: StreamType) {
        let old = self
        setStream(newStream)

        if old.stream.usesAmplitude && newStream.usesAmplitude {
            amplitudePercent = old.amplitudePercent
            fadeSeconds = old.fadeSeconds
        }
        if old.stream.hasParameters && newStream.hasParameters {
            playSeconds = old.playSeconds
            waitSeconds = old.waitSeconds
        }
    }

    /// Default parameters of the current stream type.
    public mutating func resetStreamParameters() {
        setStream(stream)
    }
}
