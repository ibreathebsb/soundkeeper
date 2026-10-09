import AppKit
import SoundKeeperCore

/// A menu item that runs a closure when it is chosen.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, id: String, checked: Bool = false, enabled: Bool = true, toolTip: String? = nil, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(performHandler), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.identifier = NSUserInterfaceItemIdentifier(id)
        self.state = checked ? .on : .off
        self.isEnabled = enabled
        self.toolTip = toolTip
    }

    @objc private func performHandler() {
        handler?()
    }
}

/// The menu of the status bar item: what is going on, and all the settings.
///
/// It is rebuilt from the model every time it is about to be shown, so there is no state to keep in sync.
public final class StatusMenu: NSObject, NSMenuDelegate {
    public let menu = NSMenu()

    /// The user asked for the panel with numeric parameters of the signal.
    public var showParameters: (() -> Void)?
    public var showAbout: (() -> Void)?
    public var quit: (() -> Void)?
    public var reportError: ((Error) -> Void)?

    private let model: AppModel
    private var statusItemCount = 0
    private var isOpen = false

    public init(model: AppModel) {
        self.model = model
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        rebuild()
    }

    // -----------------------------------------------------------------------------------------------------------------

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    /// The status can change while the menu is open: a device is connected, the stream is started.
    public func modelChanged() {
        guard isOpen else { return }

        for _ in 0..<statusItemCount { menu.removeItem(at: 0) }
        let items = statusItems()
        statusItemCount = items.count
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    public func rebuild() {
        menu.removeAllItems()

        let status = statusItems()
        statusItemCount = status.count
        status.forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(
            L("Keep Outputs Awake"), id: "enabled", checked: model.isEnabled,
            toolTip: L("Turns Sound Keeper on and off.")
        ) { [model] in
            model.setEnabled(!model.isEnabled)
        })

        menu.addItem(.separator())
        menu.addItem(submenu(L("Outputs"), id: "outputs", items: outputItems()))
        menu.addItem(submenu(L("Signal"), id: "signal", items: signalItems()))
        menu.addItem(submenu(L("Sleep"), id: "sleep", items: sleepItems()))

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("Start at Login"), id: "login", checked: model.startsAtLogin) { [weak self] in
            self?.toggleStartsAtLogin()
        })

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("About Sound Keeper"), id: "about") { [weak self] in self?.showAbout?() })

        let quitItem = ActionMenuItem(L("Quit Sound Keeper"), id: "quit") { [weak self] in self?.quit?() }
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    // -----------------------------------------------------------------------------------------------------------------
    // What is going on.
    // -----------------------------------------------------------------------------------------------------------------

    private func statusItems() -> [NSMenuItem] {
        guard model.isEnabled else {
            return [info(L("Sound Keeper is turned off"), id: "status")]
        }

        let status = model.status

        if !status.sleeping.isEmpty {
            let reasons = status.sleeping.map { L($0) }.joined(separator: ", ")
            return [info(L("Paused: %@", reasons), id: "status")]
        }

        if status.sessions.isEmpty {
            return [info(L("No output to keep awake"), id: "status")]
        }

        var items = [header(L("Keeping Awake"), id: "status")]
        for session in status.sessions {
            let title: String
            let color: NSColor
            switch session.health {
            case .active:
                title = session.name
                color = .systemGreen
            case .waiting:
                title = L("%@ — waiting, in exclusive use", session.name)
                color = .systemYellow
            case .failing:
                title = L("%@ — can't start, retrying", session.name)
                color = .systemRed
            case .inactive:
                title = L("%@ — stopped", session.name)
                color = .systemGray
            }

            let item = info(title, id: "session.\(session.uid)")
            item.image = Self.dot(color)
            item.toolTip = "\(session.transport): \(session.state)"
            items.append(item)
        }
        return items
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Which outputs are kept awake.
    // -----------------------------------------------------------------------------------------------------------------

    private func outputItems() -> [NSMenuItem] {
        let model = self.model
        let settings = model.settings
        let snapshot = model.outputs()
        var items: [NSMenuItem] = []

        let defaultName = snapshot.devices.first { $0.id == snapshot.defaultOutputID }?.name
        let modes: [(selector: DeviceSelector, title: String, toolTip: String)] = [
            (.primary, defaultName.map { L("Default Output (%@)", $0) } ?? L("Default Output"),
             L("The output that is selected in Sound settings. It is followed when you switch outputs.")),
            (.all, L("All Outputs"), L("All hardware outputs. Virtual devices are skipped.")),
            (.digital, L("Digital Outputs"), L("HDMI, DisplayPort and S/PDIF outputs.")),
            (.analog, L("Analog Outputs"), L("All hardware outputs except HDMI, DisplayPort and S/PDIF.")),
        ]
        for mode in modes {
            items.append(ActionMenuItem(mode.title, id: "devices.\(mode.selector.keyword)", checked: settings.devices == mode.selector, toolTip: mode.toolTip) {
                model.update { $0.devices = mode.selector }
            })
        }

        if settings.devices == .marked {
            // It can be set by the command line tool only.
            items.append(ActionMenuItem(L("Outputs Marked with \"!\""), id: "devices.marked", checked: true) {})
        }

        items.append(.separator())
        items.append(header(L("Only Selected"), id: "devices.header"))

        let selected = settings.selectedDevices
        for device in snapshot.devices {
            let isSelected = selected.contains { device.matches(pattern: $0) }
            let title = "\(device.name) — \(device.transport.name)"
            items.append(ActionMenuItem(title, id: "device.\(device.uid)", checked: isSelected) {
                model.update { $0.toggleDevice(device) }
            })
        }

        // Selected devices that are not connected right now.
        for pattern in selected where !snapshot.devices.contains(where: { $0.matches(pattern: pattern) }) {
            let name = model.knownDeviceName(uid: pattern) ?? pattern
            items.append(ActionMenuItem(L("%@ (not connected)", name), id: "device.\(pattern)", checked: true) {
                model.update { $0.deselect(pattern: pattern) }
            })
        }

        items.append(.separator())
        items.append(ActionMenuItem(
            L("Include AirPlay Outputs"), id: "devices.remote", checked: settings.allowRemote,
            toolTip: L("AirPlay outputs are ignored by default: keeping them awake means streaming over the network all the time.")
        ) {
            model.update { $0.allowRemote.toggle() }
        })

        return items
    }

    // -----------------------------------------------------------------------------------------------------------------
    // What is played.
    // -----------------------------------------------------------------------------------------------------------------

    private func signalItems() -> [NSMenuItem] {
        let model = self.model
        let settings = model.settings
        var items: [NSMenuItem] = []

        let types: [(stream: StreamType, title: String, toolTip: String)] = [
            (.openOnly, L("Open Only"), L("Opens the output, but doesn't play anything. Sometimes it is enough.")),
            (.zero, L("Zero"), L("Plays a stream of zeroes. It may be not enough for some hardware.")),
            (.fluctuate, L("Fluctuate"), L("Plays zeroes with the smallest non-zero samples now and then. It is inaudible. Used by default.")),
            (.sine, L("Sine Wave"), L("Plays a sine wave. A low frequency is inaudible, but it is a real signal for outputs that detect silence.")),
            (.white, L("White Noise"), L("Plays white noise. Use a low amplitude to make it inaudible.")),
            (.brown, L("Brown Noise"), L("Plays brown noise. Use a low amplitude to make it inaudible.")),
            (.pink, L("Pink Noise"), L("Plays pink noise. Use a low amplitude to make it inaudible.")),
        ]
        for type in types {
            let title = type.stream == Settings().stream ? type.title + " — " + L("default") : type.title
            items.append(ActionMenuItem(title, id: "stream.\(type.stream.keyword)", checked: settings.stream == type.stream, toolTip: type.toolTip) {
                model.update { $0.changeStream(to: type.stream) }
            })
        }

        items.append(.separator())

        // Frequency.
        var defaults = Settings()
        defaults.setStream(settings.stream)

        let frequencyTitle = settings.stream.usesFrequency ? L("Frequency: %@ Hz", formatNumber(settings.frequency)) : L("Frequency")
        let frequencies: [Double] = settings.stream == .sine ? [1, 5, 10, 20, 50, 100, 1000] : [1, 10, 25, 50, 100]
        var frequencyItems = presets(frequencies, current: settings.frequency, id: "frequency") { value in
            var title = L("%@ Hz", formatNumber(value))
            if value == defaults.frequency { title += " — " + L("default") }
            if settings.stream == .sine && value >= 200 { title += " — " + L("audible, for testing") }
            return title
        } apply: { value in
            model.update { $0.frequency = value }
        }
        frequencyItems.append(.separator())
        frequencyItems.append(ActionMenuItem(L("Custom…"), id: "frequency.custom") { [weak self] in self?.showParameters?() })

        let frequencyMenu = submenu(frequencyTitle, id: "frequency", items: frequencyItems)
        frequencyMenu.isEnabled = settings.stream.usesFrequency
        items.append(frequencyMenu)

        // Amplitude.
        let amplitudeTitle = settings.stream.usesAmplitude ? L("Amplitude: %@%%", formatNumber(settings.amplitudePercent)) : L("Amplitude")
        var amplitudeItems = presets([0.01, 0.1, 1, 5, 15], current: settings.amplitudePercent, id: "amplitude") { value in
            var title = formatNumber(value) + "%"
            if value == defaults.amplitudePercent { title += " — " + L("default") }
            return title
        } apply: { value in
            model.update { $0.amplitudePercent = value }
        }
        amplitudeItems.append(.separator())
        amplitudeItems.append(ActionMenuItem(L("Custom…"), id: "amplitude.custom") { [weak self] in self?.showParameters?() })

        let amplitudeMenu = submenu(amplitudeTitle, id: "amplitude", items: amplitudeItems)
        amplitudeMenu.isEnabled = settings.stream.usesAmplitude
        items.append(amplitudeMenu)

        items.append(ActionMenuItem(
            L("More Parameters…"), id: "signal.parameters", enabled: settings.stream.hasParameters,
            toolTip: L("Length of the sound, pauses between sounds, and fading.")
        ) { [weak self] in
            self?.showParameters?()
        })

        items.append(.separator())
        items.append(ActionMenuItem(L("Reset to Defaults"), id: "signal.reset", enabled: settings.stream.hasParameters) {
            model.update { $0.resetStreamParameters() }
        })

        return items
    }

    /// Items to choose one of predefined values. The current value is always among them.
    private func presets(_ values: [Double], current: Double, id: String, title: (Double) -> String, apply: @escaping (Double) -> Void) -> [NSMenuItem] {
        var values = values
        if !values.contains(current) {
            values.append(current)
            values.sort()
        }

        return values.map { value in
            ActionMenuItem(title(value), id: "\(id).\(formatNumber(value))", checked: value == current) { apply(value) }
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Sleep.
    // -----------------------------------------------------------------------------------------------------------------

    private func sleepItems() -> [NSMenuItem] {
        let model = self.model
        let settings = model.settings

        return [
            ActionMenuItem(
                L("Keep the Mac Awake"), id: "sleep.nosleep", checked: settings.preventSystemSleep,
                toolTip: L("By default the Mac is free to go to sleep while Sound Keeper is playing. Turn it on to keep the Mac awake, like a usual audio player does.")
            ) {
                model.update {
                    $0.preventSystemSleep.toggle()
                    if $0.preventSystemSleep {
                        $0.sleepWithDisplay = false
                        $0.sleepWithLock = false
                    }
                }
            },
            .separator(),
            ActionMenuItem(
                L("Pause While Displays Are Off"), id: "sleep.display", checked: settings.sleepWithDisplay, enabled: !settings.preventSystemSleep,
                toolTip: L("Lets your speakers fall asleep when you are away.")
            ) {
                model.update { $0.sleepWithDisplay.toggle() }
            },
            ActionMenuItem(
                L("Pause While the Screen Is Locked"), id: "sleep.lock", checked: settings.sleepWithLock, enabled: !settings.preventSystemSleep,
                toolTip: L("Lets your speakers fall asleep when you are away.")
            ) {
                model.update { $0.sleepWithLock.toggle() }
            },
        ]
    }

    private func toggleStartsAtLogin() {
        do {
            try model.setStartsAtLogin(!model.startsAtLogin)
        } catch {
            reportError?(error)
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Building blocks.
    // -----------------------------------------------------------------------------------------------------------------

    private func submenu(_ title: String, id: String, items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.submenu = submenu
        return item
    }

    /// A line of text that can't be chosen.
    private func info(_ title: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.isEnabled = false
        return item
    }

    private func header(_ title: String, id: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            let item = NSMenuItem.sectionHeader(title: title)
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        }
        return info(title, id: id)
    }

    private static func dot(_ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}
