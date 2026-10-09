import Foundation
import SoundKeeperCore
import Testing

private func temporaryDefaults() -> (UserDefaults, String) {
    let suite = "local.soundkeeper.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private func temporaryPaths() -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("soundkeeper-tests-\(UUID().uuidString)", isDirectory: true)
    return Paths(
        home: root.appendingPathComponent("home", isDirectory: true),
        launchAgents: root.appendingPathComponent("agents", isDirectory: true),
        // Never the real label: tests must not touch the real login item.
        agentLabel: "local.soundkeeper.tests.\(UUID().uuidString)"
    )
}

@Suite struct SettingsStoreTests {

    @Test func defaultsForTheFirstLaunch() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings == Settings())
        #expect(store.isEnabled)
        #expect(store.knownDevices.isEmpty)
    }

    @Test func settingsSurviveARestart() throws {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = try SettingsParser.parse(arguments: ["pink", "-a", "0.1", "-l", "5", "-w", "30", "sleepld"]).settings
        settings.devices = .named(["00-11-22-33-44-55:output", "BuiltInSpeakerDevice"])
        settings.allowRemote = true

        let store = SettingsStore(defaults: defaults)
        store.settings = settings
        store.isEnabled = false

        let restarted = SettingsStore(defaults: defaults)
        #expect(restarted.settings == settings)
        #expect(!restarted.isEnabled)
        #expect(defaults.stringArray(forKey: "settings") == settings.arguments)
    }

    @Test func brokenSettingsAreReplacedWithDefaults() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        for broken in [["nonsense"], ["sine", "-f"], ["kill"], ["install", "all"]] {
            defaults.set(broken, forKey: "settings")
            #expect(store.settings == Settings(), "\(broken)")
        }
        defaults.set("not an array", forKey: "settings")
        #expect(store.settings == Settings())
    }

    @Test func remembersNamesOfDevices() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.remember([Fixture.jbl, Fixture.speakers])
        store.remember([Fixture.speakers])
        #expect(store.knownDevices == [Fixture.jbl.uid: "JBL GO 2", Fixture.speakers.uid: "MacBook Pro Speakers"])
    }

    @Test func togglingDevices() {
        var settings = Settings()
        #expect(settings.selectedDevices == [])

        settings.toggleDevice(Fixture.jbl)
        settings.toggleDevice(Fixture.speakers)
        #expect(settings.devices == .named([Fixture.jbl.uid, Fixture.speakers.uid]))

        settings.toggleDevice(Fixture.jbl)
        #expect(settings.devices == .named([Fixture.speakers.uid]))

        // Nothing is selected: back to the default output.
        settings.toggleDevice(Fixture.speakers)
        #expect(settings.devices == .primary)

        settings.devices = .all
        settings.toggleDevice(Fixture.display)
        #expect(settings.devices == .named([Fixture.display.uid]))

        // A device that was selected by a part of its name is deselected by removing that pattern.
        settings.devices = .named(["jbl", "denon"])
        settings.toggleDevice(Fixture.jbl)
        #expect(settings.devices == .named(["denon"]))

        settings.deselect(pattern: "denon")
        #expect(settings.devices == .primary)
    }

    @Test func changingStreamKeepsCompatibleParameters() throws {
        var settings = try SettingsParser.parse(arguments: ["brown", "-a", "0.1", "-t", "2", "-l", "5", "-w", "30"]).settings

        settings.changeStream(to: .pink)
        #expect(settings.stream == .pink)
        #expect(settings.amplitudePercent == 0.1 && settings.fadeSeconds == 2 && settings.playSeconds == 5 && settings.waitSeconds == 30)

        // Sine has its own frequency, amplitude is still the same thing.
        settings.changeStream(to: .sine)
        #expect(settings.frequency == 1 && settings.amplitudePercent == 0.1)

        // Fluctuate has no amplitude, and its frequency means something else.
        settings.changeStream(to: .fluctuate)
        #expect(settings.frequency == 50 && settings.amplitudePercent == 0 && settings.fadeSeconds == 0 && settings.playSeconds == 5)

        settings.changeStream(to: .sine)
        #expect(settings.frequency == 1 && settings.amplitudePercent == 1 && settings.fadeSeconds == 0.1)

        settings.changeStream(to: .zero)
        #expect(settings.frequency == 0 && settings.amplitudePercent == 0 && settings.playSeconds == 0)

        settings = try SettingsParser.parse(arguments: ["sine", "-f", "440", "-a", "7"]).settings
        settings.resetStreamParameters()
        #expect(settings.stream == .sine && settings.frequency == 1 && settings.amplitudePercent == 1)
    }
}

@Suite struct LaunchAgentTests {

    @Test func agentOfTheCommandLineTool() throws {
        let paths = temporaryPaths()
        let settings = try SettingsParser.parse(arguments: ["-d", "JBL GO 2", "sine", "-f", "10", "-a", "5", "sleepd"]).settings
        let plist = LaunchAgent(paths: paths, environment: [:]).propertyList(executable: "/somewhere/soundkeeper", settings: settings)

        #expect(plist["Label"] as? String == paths.agentLabel)
        #expect(plist["ProgramArguments"] as? [String] == ["/somewhere/soundkeeper", "run", "--device", "JBL GO 2", "sine", "-f", "10", "-a", "5", "-t", "0.1", "sleepd"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")

        // What launchd runs is what the parser understands.
        let arguments = Array((plist["ProgramArguments"] as! [String]).dropFirst())
        #expect(try SettingsParser.parse(arguments: arguments) == Invocation(command: .run, settings: settings))

        // Nothing is overridden, so the agent has no special environment.
        #expect(plist["EnvironmentVariables"] == nil)

        let overridden = LaunchAgent(paths: paths, environment: ["SOUNDKEEPER_HOME": "/elsewhere", "PATH": "/usr/bin", "HOME": "/Users/someone"])
        #expect(overridden.propertyList(executable: "/somewhere/soundkeeper", settings: settings)["EnvironmentVariables"] as? [String: String] == ["SOUNDKEEPER_HOME": "/elsewhere"])

        // And it is a valid property list.
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(String(decoding: data, as: UTF8.self).contains("<key>ProgramArguments</key>"))
    }

    @Test func loginItemOfTheApp() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }

        let agent = LaunchAgent(paths: paths, environment: [:])
        let executable = URL(fileURLWithPath: "/Applications/SoundKeeper.app/Contents/MacOS/SoundKeeper")

        #expect(!agent.isInstalled)
        #expect(!agent.isAppInstalled(executable: executable))
        #expect(agent.installedCommand == nil)

        try agent.installApp(executable: executable, bundleIdentifier: "local.soundkeeper")
        #expect(agent.isInstalled)
        #expect(agent.isAppInstalled(executable: executable))
        #expect(!agent.isAppInstalled(executable: URL(fileURLWithPath: "/elsewhere/SoundKeeper")))
        #expect(agent.installedCommand == [executable.path])

        let data = try Data(contentsOf: paths.agentPlist)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == paths.agentLabel)
        #expect(plist["ProgramArguments"] as? [String] == [executable.path])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["local.soundkeeper"])
        #expect(plist["RunAtLoad"] as? Bool == true)

        agent.removeApp()
        #expect(!agent.isInstalled)
        #expect(!agent.isAppInstalled(executable: executable))
    }
}

@Suite struct InstanceLockTests {

    @Test func lockLifecycle() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }

        let lock = InstanceLock(url: paths.lockFile)
        #expect(lock.holder() == nil)
        #expect(try lock.stopRunningInstance() == nil)

        try lock.acquire(replacingExisting: false)
        #expect(lock.isHeld)
        #expect(lock.holder() == getpid())
        #expect(try String(contentsOf: paths.lockFile, encoding: .utf8) == "\(getpid())\n")

        // The owner never stops itself.
        #expect(try lock.stopRunningInstance() == nil)

        lock.release()
        #expect(!lock.isHeld)
        #expect(lock.holder() == nil)
    }

    @Test func standardPathsCanBeOverridden() {
        let paths = Paths.standard(environment: ["SOUNDKEEPER_HOME": "/tmp/sk home", "SOUNDKEEPER_AGENTS_DIR": "/tmp/agents", "SOUNDKEEPER_AGENT_LABEL": "local.test"])
        #expect(paths.lockFile.path == "/tmp/sk home/soundkeeper.lock")
        #expect(paths.statusFile.path == "/tmp/sk home/status.json")
        #expect(paths.installedExecutable.path == "/tmp/sk home/soundkeeper")
        #expect(paths.agentPlist.path == "/tmp/agents/local.test.plist")

        let standard = Paths.standard(environment: [:])
        #expect(standard.agentLabel == "local.soundkeeper")
        #expect(standard.home.path.hasSuffix("/Library/Application Support/SoundKeeper"))
        #expect(standard.agentPlist.path.hasSuffix("/Library/LaunchAgents/local.soundkeeper.plist"))
    }
}
