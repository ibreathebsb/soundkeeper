import Foundation

/// Autorun at login. It is what copying the exe to the startup directory is on Windows: a per-user launchd agent
/// (~/Library/LaunchAgents/local.soundkeeper.plist) that runs a private copy of the executable with the given settings.
public struct LaunchAgent {

    public enum AgentError: Error, CustomStringConvertible {
        case file(String)
        case launchctl(arguments: [String], status: Int32, output: String)

        public var description: String {
            switch self {
            case .file(let message):
                return message
            case .launchctl(let arguments, let status, let output):
                return "launchctl \(arguments.joined(separator: " ")) failed (\(status))" + (output.isEmpty ? "" : ": \(output)")
            }
        }
    }

    public let paths: Paths

    /// Environment of the agent. When locations of files are overridden (see `Paths.standard`), the agent has to
    /// use the same locations as the one who installs it.
    public let environment: [String: String]

    public init(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = environment.filter { $0.key.hasPrefix("SOUNDKEEPER_") }
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(paths.agentLabel)" }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.agentPlist.path)
    }

    /// The agent is known to launchd in the current login session.
    public var isLoaded: Bool {
        launchctl(["print", service]).status == 0
    }

    /// What the installed agent runs: the path of the program and its arguments.
    public var installedCommand: [String]? {
        guard let data = try? Data(contentsOf: paths.agentPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], !arguments.isEmpty else {
            return nil
        }
        return arguments
    }

    /// Whether the menu bar app with the specified executable is started at login.
    public func isAppInstalled(executable: URL) -> Bool {
        guard let program = installedCommand?.first else { return false }
        return URL(fileURLWithPath: program).resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path
    }

    /// The agent of the command line tool: it runs with the given settings.
    public func propertyList(executable: String, settings: Settings) -> [String: Any] {
        propertyList(command: [executable, "run"] + settings.arguments)
    }

    private func propertyList(command: [String], bundleIdentifier: String? = nil) -> [String: Any] {
        var plist = basePropertyList(command: command)
        if let bundleIdentifier {
            // Lets System Settings show the app instead of a bare executable in the list of login items.
            plist["AssociatedBundleIdentifiers"] = [bundleIdentifier]
        }
        if !environment.isEmpty {
            plist["EnvironmentVariables"] = environment
        }
        return plist
    }

    private func basePropertyList(command: [String]) -> [String: Any] {
        [
            "Label": paths.agentLabel,
            "ProgramArguments": command,
            "RunAtLoad": true,
            // Restart after a crash, but not when it is stopped by "soundkeeper kill" or replaced by a new instance.
            "KeepAlive": ["SuccessfulExit": false],
            // Audio hardware belongs to the graphical login session.
            "LimitLoadToSessionType": "Aqua",
            // It renders audio in real time, so launchd must not throttle it like a background job.
            "ProcessType": "Interactive",
        ]
    }

    /// Copies the executable to its permanent place, writes the agent, and starts it.
    public func install(executable source: URL, settings: Settings) throws {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        } catch {
            throw AgentError.file(error.localizedDescription)
        }

        // The agent must not depend on the build directory, so it gets its own copy. The copy is renamed into place:
        // overwriting an executable that is running is not safe.
        let destination = paths.installedExecutable
        if source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path {
            let temporary = destination.appendingPathExtension("new")
            do {
                try? fileManager.removeItem(at: temporary)
                try fileManager.copyItem(at: source, to: temporary)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            } catch {
                throw AgentError.file("unable to copy \(source.path) to \(destination.path): \(error.localizedDescription)")
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw AgentError.file("unable to replace \(destination.path): \(String(cString: strerror(errno)))")
            }
        }

        try write(propertyList(executable: destination.path, settings: settings))

        unload()

        // The agent could be disabled by "launchctl disable" earlier.
        _ = launchctl(["enable", service])

        // launchd may still be busy with the old job for a moment.
        let arguments = ["bootstrap", domain, paths.agentPlist.path]
        var result = launchctl(arguments)
        var attempts = 1
        while result.status != 0 && attempts < 10 {
            usleep(300_000)
            if isLoaded { return }
            result = launchctl(arguments)
            attempts += 1
        }

        guard result.status == 0 else {
            throw AgentError.launchctl(arguments: arguments, status: result.status, output: result.output)
        }
    }

    /// Makes the menu bar app start at login. Nothing is started now, since the app is what calls it.
    /// There is just one login item: it replaces the one of the command line tool, if it was installed.
    public func installApp(executable: URL, bundleIdentifier: String?) throws {
        do {
            try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        } catch {
            throw AgentError.file(error.localizedDescription)
        }

        unloadUnlessCurrentProcess()
        try write(propertyList(command: [executable.path], bundleIdentifier: bundleIdentifier))
    }

    /// Removes the login item without stopping what is running now.
    public func removeApp() {
        unloadUnlessCurrentProcess()
        try? FileManager.default.removeItem(at: paths.agentPlist)
    }

    /// Stops the agent and removes its files. Returns false if there was nothing to remove.
    @discardableResult
    public func uninstall() -> Bool {
        let fileManager = FileManager.default
        let wasLoaded = unload()
        let wasInstalled = isInstalled || fileManager.fileExists(atPath: paths.installedExecutable.path)

        try? fileManager.removeItem(at: paths.agentPlist)
        try? fileManager.removeItem(at: paths.installedExecutable)

        return wasLoaded || wasInstalled
    }

    /// Removes the agent from launchd, which also stops it. Returns false if it was not loaded.
    @discardableResult
    public func unload() -> Bool {
        guard isLoaded else { return false }

        _ = launchctl(["bootout", service])

        // It returns before the job is completely gone.
        var attempts = 0
        while attempts < 50 && isLoaded {
            usleep(100_000)
            attempts += 1
        }
        return true
    }

    /// PID of the process of the agent, if launchd runs it now.
    public var loadedPID: pid_t? {
        let result = launchctl(["print", service])
        guard result.status == 0 else { return nil }

        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = pid_t(parts[1]) { return pid }
        }
        return nil
    }

    /// An agent that is known to launchd is removed from there, unless it is this very process: removing a job
    /// stops its process, and the app must not quit just because its login item is changed.
    private func unloadUnlessCurrentProcess() {
        guard isLoaded, loadedPID != getpid() else { return }
        unload()
    }

    private func write(_ plist: [String: Any]) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: paths.agentPlist, options: .atomic)
        } catch {
            throw AgentError.file("unable to write \(paths.agentPlist.path): \(error.localizedDescription)")
        }
    }

    private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
