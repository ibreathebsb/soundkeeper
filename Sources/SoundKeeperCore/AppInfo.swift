import Foundation

public enum AppInfo {
    public static let name = "Sound Keeper for macOS"
    public static let version = "1.0.0"

    /// Version of Sound Keeper for Windows this port follows.
    public static let upstreamVersion = "1.3.7"

    /// Subsystem of the unified log, and the default label of the login item.
    public static let identifier = "local.soundkeeper"

    public static var banner: String {
        "\(name) v\(version) (a port of Sound Keeper v\(upstreamVersion) for Windows)"
    }
}

/// Where Sound Keeper keeps its files. Everything is per user.
public struct Paths {
    /// Lock file, status file and the copy of the executable used by the login item.
    public var home: URL
    /// The directory with per-user launchd agents.
    public var launchAgents: URL
    /// launchd label of the login item.
    public var agentLabel: String

    public init(home: URL, launchAgents: URL, agentLabel: String) {
        self.home = home
        self.launchAgents = launchAgents
        self.agentLabel = agentLabel
    }

    /// The standard locations. They can be overridden using environment variables, which is handy for experiments
    /// and for testing without touching the real instance:
    /// `SOUNDKEEPER_HOME`, `SOUNDKEEPER_AGENTS_DIR` and `SOUNDKEEPER_AGENT_LABEL`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)

        func directory(_ variable: String, default fallback: URL) -> URL {
            if let value = environment[variable], !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            }
            return fallback
        }

        var label = AppInfo.identifier
        if let value = environment["SOUNDKEEPER_AGENT_LABEL"], !value.isEmpty { label = value }

        return Paths(
            home: directory("SOUNDKEEPER_HOME", default: library.appendingPathComponent("Application Support/SoundKeeper", isDirectory: true)),
            launchAgents: directory("SOUNDKEEPER_AGENTS_DIR", default: library.appendingPathComponent("LaunchAgents", isDirectory: true)),
            agentLabel: label
        )
    }

    public var lockFile: URL { home.appendingPathComponent("soundkeeper.lock") }
    public var statusFile: URL { home.appendingPathComponent("status.json") }
    public var installedExecutable: URL { home.appendingPathComponent("soundkeeper") }
    public var agentPlist: URL { launchAgents.appendingPathComponent("\(agentLabel).plist") }
}
