import Foundation

/// Whether a device is kept awake with the given settings, and why.
public struct DeviceDecision: Equatable {
    public var device: OutputDevice
    public var isDefault: Bool
    public var keep: Bool
    public var reason: String
}

/// Decides which output devices have to be kept awake. A pure function, so it's easy to test.
public func decideDevices(settings: Settings, snapshot: AudioSnapshot) -> [DeviceDecision] {
    snapshot.devices.map { device in
        let isDefault = device.id == snapshot.defaultOutputID
        let (keep, reason) = decide(device, isDefault: isDefault, settings: settings)
        return DeviceDecision(device: device, isDefault: isDefault, keep: keep, reason: reason)
    }
}

private let remoteReason = "AirPlay is ignored (add \"remote\" to allow it)"

private func decide(_ device: OutputDevice, isDefault: Bool, settings: Settings) -> (Bool, String) {
    switch settings.devices {
    case .primary:
        guard isDefault else { return (false, "not the default output") }
        if device.isRemote && !settings.allowRemote { return (false, remoteReason) }
        return (true, "default output")

    case .named(let patterns):
        // The device is explicitly requested by the user, so no other filters are applied.
        if let pattern = patterns.first(where: { device.matches(pattern: $0) }) {
            return (true, "matches \"\(pattern)\"")
        }
        return (false, "name doesn't match")

    case .marked:
        guard device.name.contains("!") else { return (false, "not marked with \"!\"") }
        if device.isRemote && !settings.allowRemote { return (false, remoteReason) }
        return (true, "marked with \"!\"")

    case .all, .digital, .analog:
        if device.isRemote && !settings.allowRemote { return (false, remoteReason) }

        // Group modes are about real hardware. Virtual devices have nothing to keep awake, and sub-devices of
        // aggregate devices are handled on their own.
        if device.transport == .virtual { return (false, "virtual device") }
        if device.transport == .aggregate { return (false, "aggregate device") }
        if device.isHidden { return (false, "hidden device") }
        if !device.canBeDefault { return (false, "can't be an output for apps") }

        if settings.devices == .digital && !device.isDigital { return (false, "not a digital output") }
        if settings.devices == .analog && device.isDigital { return (false, "digital output") }

        return (true, device.isDigital ? "digital output" : "analog output")
    }
}

extension OutputDevice {
    /// Whether the device is selected by the pattern: its UID is equal to it, or its name contains it.
    public func matches(pattern: String) -> Bool {
        if uid == pattern { return true }

        // Names like "Someone’s AirPods" have a typographic apostrophe that is hard to type.
        func normalized(_ string: String) -> String { string.replacingOccurrences(of: "’", with: "'") }

        return normalized(name).range(of: normalized(pattern), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
