import AppKit
import SoundKeeperCore

/// The menu bar app: an icon in the status bar with a menu. No windows, no Dock icon.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: KeeperService?
    private var model: AppModel?
    private var statusMenu: StatusMenu?
    private var statusItem: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.configure(verbose: CommandLine.arguments.contains("-v") || CommandLine.arguments.contains("--verbose"))

        let paths = Paths.standard()
        let service = KeeperService(paths: paths, frontend: "menu bar app")

        // When a user starts a new Sound Keeper instance, the previous one is stopped automatically.
        do {
            try service.acquireLock()
        } catch {
            showError(error)
            NSApp.terminate(nil)
            return
        }
        self.service = service

        Log.info(AppInfo.banner)

        let agent = LaunchAgent(paths: paths)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleIdentifier = Bundle.main.bundleIdentifier

        let model = AppModel(store: SettingsStore(), environment: AppModel.Environment(
            start: { service.start(settings: $0) },
            pause: { service.pause() },
            status: { service.status },
            snapshot: { CoreAudioSystem().snapshot() },
            startsAtLogin: { agent.isAppInstalled(executable: executable) },
            setStartsAtLogin: { enabled in
                if enabled {
                    try agent.installApp(executable: executable, bundleIdentifier: bundleIdentifier)
                } else {
                    agent.removeApp()
                }
            }
        ))
        self.model = model

        let statusMenu = StatusMenu(model: model)
        statusMenu.showParameters = { [weak model] in
            guard let model, let changed = ParametersPanel.run(settings: model.settings) else { return }
            model.update { $0 = changed }
        }
        statusMenu.showAbout = { [weak self] in self?.showAbout() }
        statusMenu.quit = { NSApp.terminate(nil) }
        statusMenu.reportError = { [weak self] in self?.showError($0) }
        self.statusMenu = statusMenu

        let statusItem = StatusItemController(model: model, menu: statusMenu.menu)
        self.statusItem = statusItem

        model.onChange = { [weak statusItem, weak statusMenu] in
            statusItem?.refresh()
            statusMenu?.modelChanged()
        }
        service.onStatusChanged = { [weak model] _ in model?.statusChanged() }

        // "soundkeeper kill", a newer instance, and logout stop the app the same way: by SIGTERM.
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        // The app has no windows, so the system would consider it idle and slow it down (App Nap).
        // It is still fine for the Mac to go to sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Keeping audio outputs awake")

        model.activate()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Log.info("Shutdown.")
        service?.shutdown()
    }

    /// The app is opened once again while it's running: show where it lives.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.showMenu()
        return false
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(
            string: L("Keeps audio outputs awake by always playing an inaudible stream.") + "\n\n"
                + L("A macOS port of Sound Keeper for Windows by Evgeny Vrublevsky.") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor]
        )
        let link = "https://github.com/vrubleg/soundkeeper"
        credits.append(NSAttributedString(string: link, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: URL(string: link) as Any,
        ]))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("Sound Keeper"),
            .applicationVersion: AppInfo.version,
            .version: "",
            .credits: credits,
        ])
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Sound Keeper")
        alert.informativeText = "\(error)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

public enum SoundKeeperApplication {
    /// Runs the menu bar app. Never returns.
    public static func run() -> Never {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)

        withExtendedLifetime(delegate) {
            application.run()
        }
        exit(0)
    }
}
