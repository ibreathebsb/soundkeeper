import AppKit
import Foundation
import SoundKeeperCore
import SoundKeeperUI
import Testing

private struct LoginItemError: Error {}

/// The app model and its menu with a fake outside world.
@MainActor
private final class MenuBench {
    final class World {
        var started: [Settings] = []
        var pauses = 0
        var sessions: [KeeperStatus.Session] = []
        var sleeping: [String] = []
        var snapshot = AudioSnapshot(devices: [Fixture.jbl, Fixture.speakers], defaultOutputID: Fixture.jbl.id)
        var startsAtLogin = false
        var loginItemFails = false
    }

    let world = World()
    let model: AppModel
    let menu: StatusMenu
    let store: SettingsStore
    private let defaults: UserDefaults
    private let suite: String

    private(set) var parametersRequests = 0
    private(set) var errors = 0

    init(_ line: String = "", enabled: Bool = true) throws {
        suite = "local.soundkeeper.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = SettingsStore(defaults: defaults)
        store.settings = try SettingsParser.parse(arguments: line.split(separator: " ").map(String.init)).settings
        store.isEnabled = enabled

        let world = self.world
        model = AppModel(store: store, environment: AppModel.Environment(
            start: { world.started.append($0) },
            pause: { world.pauses += 1 },
            status: { KeeperStatus(frontend: "test", arguments: [], settings: "", sleeping: world.sleeping, sessions: world.sessions) },
            snapshot: { world.snapshot },
            startsAtLogin: { world.startsAtLogin },
            setStartsAtLogin: { enabled in
                if world.loginItemFails { throw LoginItemError() }
                world.startsAtLogin = enabled
            }
        ))

        menu = StatusMenu(model: model)
        menu.showParameters = { [weak self] in self?.parametersRequests += 1 }
        menu.reportError = { [weak self] _ in self?.errors += 1 }
        model.activate()
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Finds an item by its identifier in the menu that is rebuilt like it is when it's opened.
    func item(_ id: String) -> NSMenuItem? {
        menu.rebuild()
        return Self.find(id, in: menu.menu)
    }

    private static func find(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == id { return item }
            if let submenu = item.submenu, let found = find(id, in: submenu) { return found }
        }
        return nil
    }

    /// Chooses an item like the user does.
    func choose(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let item = item(id), item.isEnabled, let action = item.action, let target = item.target else {
            Issue.record("There is no enabled item \"\(id)\" to choose", sourceLocation: sourceLocation)
            return
        }
        _ = target.perform(action, with: item)
    }

    func isChecked(_ id: String) -> Bool { item(id)?.state == .on }

    var topLevel: [String] {
        menu.rebuild()
        return menu.menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "?") }
    }

    func ids(of submenu: String) -> [String] {
        (item(submenu)?.submenu?.items ?? []).map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "?") }
    }
}

private func session(_ device: OutputDevice, _ health: SessionHealth = .active) -> KeeperStatus.Session {
    KeeperStatus.Session(name: device.name, uid: device.uid, transport: device.transport.name, health: health, state: "streaming (44100 Hz, 2 ch)")
}

@MainActor
@Suite struct MenuTests {

    @Test func structure() throws {
        let bench = try MenuBench()
        bench.world.sessions = [session(Fixture.jbl)]

        #expect(bench.topLevel == [
            "status", "session.\(Fixture.jbl.uid)", "-", "enabled", "-", "outputs", "signal", "sleep", "-", "login", "-", "about", "quit",
        ])
        #expect(bench.ids(of: "outputs") == [
            "devices.primary", "devices.all", "devices.digital", "devices.analog", "-", "devices.header",
            "device.\(Fixture.jbl.uid)", "device.\(Fixture.speakers.uid)", "-", "devices.remote",
        ])
        #expect(bench.item("stream.fluctuate")?.title == "Fluctuate — default")
        #expect(bench.item("stream.sine")?.title == "Sine Wave")
        #expect(bench.ids(of: "signal") == [
            "stream.openonly", "stream.zero", "stream.fluctuate", "stream.sine", "stream.white", "stream.brown", "stream.pink", "-",
            "frequency", "amplitude", "signal.parameters", "-", "signal.reset",
        ])
        #expect(bench.ids(of: "sleep") == ["sleep.nosleep", "-", "sleep.display", "sleep.lock"])

        // Every item that can be chosen has a title, and the menu doesn't enable or disable items on its own.
        #expect(bench.item("quit")?.keyEquivalent == "q")
        #expect(bench.menu.menu.autoenablesItems == false)
        #expect(bench.item("outputs")?.submenu?.autoenablesItems == false)
    }

    @Test func startsWithSavedSettings() throws {
        let bench = try MenuBench("all brown -a 0.1 sleepd")
        #expect(bench.world.started.count == 1)
        #expect(bench.world.started.first?.devices == .all)
        #expect(bench.world.started.first?.stream == .brown)
        #expect(bench.isChecked("enabled"))
        #expect(bench.isChecked("devices.all") && !bench.isChecked("devices.primary"))
        #expect(bench.isChecked("stream.brown") && !bench.isChecked("stream.fluctuate"))
        #expect(bench.isChecked("sleep.display") && !bench.isChecked("sleep.lock") && !bench.isChecked("sleep.nosleep"))

        // Turned off by the user before: nothing is started.
        let off = try MenuBench(enabled: false)
        #expect(off.world.started.isEmpty)
        #expect(!off.isChecked("enabled"))
        #expect(off.model.activity == .off)
    }

    @Test func showsWhatIsGoingOn() throws {
        let bench = try MenuBench()

        #expect(bench.item("status")?.title == "No output to keep awake")
        #expect(bench.item("status")?.isEnabled == false)
        #expect(bench.model.activity == .idle)

        bench.world.sessions = [session(Fixture.jbl), session(Fixture.speakers, .waiting)]
        #expect(bench.item("status")?.title == "Keeping Awake")
        #expect(bench.item("session.\(Fixture.jbl.uid)")?.title == "JBL GO 2")
        #expect(bench.item("session.\(Fixture.jbl.uid)")?.image != nil)
        #expect(bench.item("session.\(Fixture.jbl.uid)")?.toolTip == "Bluetooth: streaming (44100 Hz, 2 ch)")
        #expect(bench.item("session.\(Fixture.speakers.uid)")?.title == "MacBook Pro Speakers — waiting, in exclusive use")
        #expect(bench.model.activity == .active)

        bench.world.sessions = [session(Fixture.jbl, .failing)]
        #expect(bench.item("session.\(Fixture.jbl.uid)")?.title == "JBL GO 2 — can't start, retrying")
        #expect(bench.model.activity == .problem)

        bench.world.sessions = []
        bench.world.sleeping = ["display is off", "screen is locked"]
        #expect(bench.item("status")?.title == "Paused: display is off, screen is locked")
        #expect(bench.model.activity == .idle)

        bench.choose("enabled")
        #expect(bench.item("status")?.title == "Sound Keeper is turned off")
    }

    @Test func turnsOnAndOff() throws {
        let bench = try MenuBench()
        #expect(bench.world.started.count == 1)

        bench.choose("enabled")
        #expect(!bench.model.isEnabled)
        #expect(bench.world.pauses == 1)
        #expect(!bench.store.isEnabled)
        #expect(!bench.isChecked("enabled"))

        // Settings can be changed while it's off. Nothing is started.
        bench.choose("stream.sine")
        #expect(bench.world.started.count == 1)

        bench.choose("enabled")
        #expect(bench.model.isEnabled && bench.store.isEnabled)
        #expect(bench.world.started.count == 2)
        #expect(bench.world.started.last?.stream == .sine)
    }

    @Test func choosesOutputs() throws {
        let bench = try MenuBench()
        #expect(bench.item("devices.primary")?.title == "Default Output (JBL GO 2)")
        #expect(bench.item("device.\(Fixture.jbl.uid)")?.title == "JBL GO 2 — Bluetooth")
        #expect(bench.isChecked("devices.primary"))

        bench.choose("devices.all")
        #expect(bench.model.settings.devices == .all)
        #expect(bench.world.started.last?.devices == .all)
        #expect(bench.store.settings.devices == .all)

        // Choosing a device switches to explicit selection.
        bench.choose("device.\(Fixture.speakers.uid)")
        #expect(bench.model.settings.devices == .named([Fixture.speakers.uid]))
        #expect(bench.isChecked("device.\(Fixture.speakers.uid)") && !bench.isChecked("device.\(Fixture.jbl.uid)"))
        #expect(!bench.isChecked("devices.all") && !bench.isChecked("devices.primary"))

        bench.choose("device.\(Fixture.jbl.uid)")
        #expect(bench.model.settings.devices == .named([Fixture.speakers.uid, Fixture.jbl.uid]))

        // The speaker is turned off: it stays selected, and it can be deselected.
        bench.world.snapshot = AudioSnapshot(devices: [Fixture.speakers], defaultOutputID: Fixture.speakers.id)
        #expect(bench.item("device.\(Fixture.jbl.uid)")?.title == "JBL GO 2 (not connected)")
        #expect(bench.isChecked("device.\(Fixture.jbl.uid)"))
        #expect(bench.item("devices.primary")?.title == "Default Output (MacBook Pro Speakers)")

        bench.choose("device.\(Fixture.jbl.uid)")
        #expect(bench.model.settings.devices == .named([Fixture.speakers.uid]))

        // Nothing is selected: back to the default output.
        bench.choose("device.\(Fixture.speakers.uid)")
        #expect(bench.model.settings.devices == .primary)
        #expect(bench.isChecked("devices.primary"))

        bench.choose("devices.remote")
        #expect(bench.model.settings.allowRemote && bench.isChecked("devices.remote"))

        // Choosing what is already chosen changes nothing and restarts nothing.
        let starts = bench.world.started.count
        bench.choose("devices.primary")
        #expect(bench.world.started.count == starts)
    }

    @Test func choosesSignal() throws {
        let bench = try MenuBench()
        #expect(bench.isChecked("stream.fluctuate"))
        #expect(bench.item("frequency")?.title == "Frequency: 50 Hz")
        #expect(bench.item("frequency")?.isEnabled == true)
        #expect(bench.item("amplitude")?.title == "Amplitude")
        #expect(bench.item("amplitude")?.isEnabled == false)
        #expect(bench.item("frequency.50")?.title == "50 Hz — default")
        #expect(bench.isChecked("frequency.50"))

        bench.choose("frequency.10")
        #expect(bench.model.settings.frequency == 10)
        #expect(bench.isChecked("frequency.10") && !bench.isChecked("frequency.50"))

        bench.choose("stream.sine")
        #expect(bench.model.settings.stream == .sine)
        #expect(bench.model.settings.frequency == 1 && bench.model.settings.amplitudePercent == 1)
        #expect(bench.item("frequency")?.title == "Frequency: 1 Hz")
        #expect(bench.item("amplitude")?.title == "Amplitude: 1%")
        #expect(bench.item("amplitude")?.isEnabled == true)
        #expect(bench.item("frequency.1000")?.title == "1000 Hz — audible, for testing")
        #expect(bench.item("amplitude.1")?.title == "1% — default")

        bench.choose("amplitude.0.1")
        #expect(bench.model.settings.amplitudePercent == 0.1)
        #expect(bench.world.started.last?.amplitudePercent == 0.1)

        // Noise has no frequency, and amplitude is kept.
        bench.choose("stream.pink")
        #expect(bench.model.settings.amplitudePercent == 0.1)
        #expect(bench.item("frequency")?.isEnabled == false)
        #expect(bench.item("signal.parameters")?.isEnabled == true)

        bench.choose("signal.reset")
        #expect(bench.model.settings.stream == .pink && bench.model.settings.amplitudePercent == 1)

        bench.choose("stream.zero")
        #expect(bench.item("frequency")?.isEnabled == false)
        #expect(bench.item("amplitude")?.isEnabled == false)
        #expect(bench.item("signal.parameters")?.isEnabled == false)
        #expect(bench.item("signal.reset")?.isEnabled == false)
    }

    @Test func showsCustomValuesAmongPresets() throws {
        let bench = try MenuBench("sine -f 12.5 -a 3")
        #expect(bench.isChecked("frequency.12.5"))
        #expect(bench.item("frequency.12.5")?.title == "12.5 Hz")
        #expect(bench.isChecked("amplitude.3"))

        let ids = bench.ids(of: "frequency")
        #expect(ids == ["frequency.1", "frequency.5", "frequency.10", "frequency.12.5", "frequency.20", "frequency.50", "frequency.100", "frequency.1000", "-", "frequency.custom"])

        bench.choose("frequency.custom")
        bench.choose("amplitude.custom")
        bench.choose("signal.parameters")
        #expect(bench.parametersRequests == 3)
    }

    @Test func sleepSettings() throws {
        let bench = try MenuBench()

        bench.choose("sleep.display")
        bench.choose("sleep.lock")
        #expect(bench.model.settings.sleepWithDisplay && bench.model.settings.sleepWithLock)

        // Keeping the Mac awake and pausing are opposite things.
        bench.choose("sleep.nosleep")
        #expect(bench.model.settings.preventSystemSleep)
        #expect(!bench.model.settings.sleepWithDisplay && !bench.model.settings.sleepWithLock)
        #expect(bench.item("sleep.display")?.isEnabled == false)
        #expect(bench.item("sleep.lock")?.isEnabled == false)

        // Whatever is chosen, it can be saved and restored.
        #expect(bench.store.settings == bench.model.settings)

        bench.choose("sleep.nosleep")
        #expect(!bench.model.settings.preventSystemSleep)
        #expect(bench.item("sleep.display")?.isEnabled == true)
    }

    @Test func startAtLogin() throws {
        let bench = try MenuBench()
        #expect(!bench.isChecked("login"))

        bench.choose("login")
        #expect(bench.world.startsAtLogin && bench.isChecked("login"))

        bench.choose("login")
        #expect(!bench.world.startsAtLogin && !bench.isChecked("login"))

        bench.world.loginItemFails = true
        bench.choose("login")
        #expect(bench.errors == 1)
        #expect(!bench.isChecked("login"))
    }

    @Test func everySettingIsSaved() throws {
        let bench = try MenuBench()
        for id in ["devices.digital", "devices.remote", "stream.brown", "amplitude.5", "sleep.display", "device.\(Fixture.speakers.uid)", "stream.sine", "frequency.20"] {
            bench.choose(id)
            #expect(bench.store.settings == bench.model.settings, "\(id)")
            #expect(bench.world.started.last == bench.model.settings, "\(id)")
        }
    }
}

@MainActor
@Suite struct ParametersFormTests {

    @Test func appliesWhatIsEntered() throws {
        let settings = try SettingsParser.parse(arguments: ["sine"]).settings
        let form = ParametersForm(settings: settings)
        #expect(form.result == settings)

        form.enter(frequency: "440", amplitude: "0,5", play: " 2 ", wait: "10.5", fade: "0")
        let result = form.result
        #expect(result.frequency == 440)
        #expect(result.amplitudePercent == 0.5)
        #expect(result.playSeconds == 2)
        #expect(result.waitSeconds == 10.5)
        #expect(result.fadeSeconds == 0)
        #expect(result.stream == .sine && result.devices == .primary)
    }

    @Test func ignoresNonsenseAndLimitsValues() throws {
        let settings = try SettingsParser.parse(arguments: ["sine"]).settings

        let nonsense = ParametersForm(settings: settings)
        nonsense.enter(frequency: "abc", amplitude: "-5", play: "", wait: "1e999", fade: "nan")
        #expect(nonsense.result == settings)

        let huge = ParametersForm(settings: settings)
        huge.enter(frequency: "1000000", amplitude: "500")
        #expect(huge.result.frequency == 96000)
        #expect(huge.result.amplitudePercent == 100)
    }

    @Test func fieldsThatDoNotApplyAreIgnored() throws {
        // Fluctuate has a frequency and periodicity, but no amplitude and fading.
        let fluctuate = ParametersForm(settings: Settings())
        fluctuate.enter(frequency: "10", amplitude: "50", play: "1", wait: "2", fade: "3")
        #expect(fluctuate.result.frequency == 10)
        #expect(fluctuate.result.amplitudePercent == 0)
        #expect(fluctuate.result.playSeconds == 1 && fluctuate.result.waitSeconds == 2)
        #expect(fluctuate.result.fadeSeconds == 0)

        // Noise has no frequency.
        let noise = ParametersForm(settings: try SettingsParser.parse(arguments: ["white"]).settings)
        noise.enter(frequency: "10", amplitude: "0.1")
        #expect(noise.result.frequency == 0)
        #expect(noise.result.amplitudePercent == 0.1)

        // Zero has nothing.
        let zero = ParametersForm(settings: try SettingsParser.parse(arguments: ["zero"]).settings)
        zero.enter(frequency: "10", amplitude: "50", play: "1", wait: "2", fade: "3")
        #expect(zero.result == (try SettingsParser.parse(arguments: ["zero"]).settings))
        #expect(zero.initialFirstResponder == nil)
    }
}

@Suite struct ResourcesTests {
    /// The root of the repository, found from the location of this file.
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// Every text of the user interface: L("...") in the sources, and reasons to be silent that come from the keeper.
    private func textsInSources() throws -> Set<String> {
        let directory = root.appendingPathComponent("Sources/SoundKeeperUI")
        let expression = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var texts = Set(SleepReason.allCases.map(\.rawValue))

        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[Range(match.range(at: 1), in: source)!])
                texts.insert(literal.replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        return texts
    }

    @Test func everyTextIsTranslated() throws {
        let texts = try textsInSources()
        #expect(texts.count > 60)

        let chinese = try strings("zh-Hans")
        #expect(texts.subtracting(chinese.keys).sorted() == [], "texts without a translation")
        #expect(Set(chinese.keys).subtracting(texts).sorted() == [], "translations of texts that don't exist anymore")

        // Placeholders of a translation must be the same as in the original.
        for (key, value) in chinese {
            func placeholders(_ text: String) -> [String] {
                var result: [String] = []
                var previous: Character?
                for character in text {
                    if previous == "%" && (character == "@" || character == "%") {
                        result.append("%\(character)")
                        previous = nil
                    } else {
                        previous = character
                    }
                }
                return result
            }
            #expect(placeholders(key) == placeholders(value), "\(key)")
        }

        #expect(try strings("en")["Sound Keeper"] == "Sound Keeper")
    }

    @Test func infoPlistMatchesTheCode() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["CFBundleShortVersionString"] as? String == AppInfo.version)
        #expect(plist["CFBundleIdentifier"] as? String == AppInfo.identifier)
        #expect(plist["CFBundleExecutable"] as? String == "SoundKeeper")
        // An icon in the menu bar only: no Dock icon, no main menu.
        #expect(plist["LSUIElement"] as? Bool == true)
    }
}

@MainActor
@Suite struct StatusIconTests {

    @Test func iconsHaveTheSameSize() {
        for activity in [AppModel.Activity.off, .idle, .active, .problem] {
            let image = StatusIcon.image(for: activity)
            #expect(image.size == StatusIcon.size)
            #expect(image.isTemplate)
        }
    }

    @Test func toolTips() {
        #expect(StatusIcon.toolTip(for: .active, outputs: ["JBL GO 2", "LG HDR 4K"]) == "Sound Keeper keeps awake: JBL GO 2, LG HDR 4K")
        #expect(StatusIcon.toolTip(for: .off, outputs: []) == "Sound Keeper is turned off")
    }

    /// Not a test: saves pictures of what can't be checked by code, to look at them.
    /// SOUNDKEEPER_RENDER_DIR=/some/dir make test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOUNDKEEPER_RENDER_DIR"] != nil))
    func renderPictures() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOUNDKEEPER_RENDER_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Icons of all states in a row, the way they look in a light and in a dark menu bar.
        let activities: [AppModel.Activity] = [.active, .idle, .off, .problem]
        let scale: CGFloat = 8
        let cell = NSSize(width: StatusIcon.size.width + 14, height: StatusIcon.size.height + 12)
        let strip = NSImage(size: NSSize(width: cell.width * CGFloat(activities.count), height: cell.height * 2), flipped: false) { _ in
            for (row, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(row) * cell.height, width: cell.width * CGFloat(activities.count), height: cell.height).fill()

                for (column, activity) in activities.enumerated() {
                    let icon = StatusIcon.image(for: activity)
                    let rect = NSRect(x: CGFloat(column) * cell.width + 7, y: CGFloat(row) * cell.height + 6, width: icon.size.width, height: icon.size.height)

                    // A template image is a mask: it is filled with the color of the menu bar text.
                    let tinted = NSImage(size: icon.size, flipped: false) { bounds in
                        icon.draw(in: bounds)
                        (dark ? NSColor.white : NSColor.black).set()
                        bounds.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)

                    NSColor.systemRed.withAlphaComponent(0.35).setStroke()
                    NSBezierPath(rect: rect.insetBy(dx: -0.25, dy: -0.25)).stroke()
                }
            }
            return true
        }
        try png(of: strip, scale: scale).write(to: directory.appendingPathComponent("status-icons.png"))

        // The form with parameters.
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (name, arguments) in [("sine", ["sine", "-f", "10", "-a", "5", "-l", "2", "-w", "60"]), ("fluctuate", []), ("zero", ["zero"])] {
            for dark in [false, true] {
                let form = ParametersForm(settings: try SettingsParser.parse(arguments: arguments).settings)
                let view = form.view

                let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size).insetBy(dx: -16, dy: -16), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // A plain view is transparent, and a window draws its background on its own.
                let content = NSBox(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
                content.boxType = .custom
                content.borderWidth = 0
                content.fillColor = .windowBackgroundColor
                content.contentViewMargins = .zero
                window.contentView = content
                view.setFrameOrigin(NSPoint(x: 16, y: 16))
                content.addSubview(view)
                content.layoutSubtreeIfNeeded()

                let representation = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: representation)
                let data = try #require(representation.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("parameters-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func png(of image: NSImage, scale: CGFloat) throws -> Data {
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        representation.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        return try #require(representation.representation(using: .png, properties: [:]))
    }
}
