import Foundation

public enum Command: Equatable {
    case run, list, kill, install, uninstall, status, help, version
}

public struct Invocation: Equatable {
    public var command: Command
    public var settings: Settings

    public init(command: Command, settings: Settings) {
        self.command = command
        self.settings = settings
    }
}

public struct ParseError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// Parses settings the way Sound Keeper for Windows does: setting names are case insensitive, they can be passed
/// as command line arguments ("sine -f 1000 -a 15") or be glued together ("SineF1000A15"), and they can be a part
/// of the executable file name ("SoundKeeperSineF10A5").
///
/// Unlike the original, unknown command line arguments are reported instead of being silently ignored.
public enum SettingsParser {

    public static func parse(arguments: [String], executableName: String? = nil) throws -> Invocation {
        var arguments = arguments
        var command = Command.run

        if let first = arguments.first, let word = commandWords[first.lowercased()] {
            command = word
            arguments.removeFirst()
        }

        // Defaults from the executable file name. It's parsed leniently since it can be anything.
        var fromName = Scanner(lenient: true)
        if let executableName {
            var name = executableName.lowercased()
            if let range = name.range(of: "soundkeeper") { name.removeSubrange(range) }
            try fromName.scan(name)
        }

        var fromArguments = Scanner(lenient: false)
        var patterns: [String] = []
        var verbose = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let lowered = argument.lowercased()
            index += 1

            if fromArguments.pendingParameter == nil {
                switch lowered {
                case "-h", "--help", "help":
                    command = .help
                    continue
                case "--version":
                    command = .version
                    continue
                case "-v", "--verbose", "verbose", "debug", "trace":
                    verbose = true
                    continue
                case "-d", "--device":
                    guard index < arguments.count, !arguments[index].isEmpty else {
                        throw ParseError("missing device name after '\(argument)'")
                    }
                    patterns.append(arguments[index])
                    index += 1
                    continue
                default:
                    if lowered.hasPrefix("--device=") {
                        let pattern = String(argument.dropFirst("--device=".count))
                        guard !pattern.isEmpty else { throw ParseError("missing device name in '\(argument)'") }
                        patterns.append(pattern)
                        continue
                    }
                }
            }

            try fromArguments.scan(lowered)
        }

        if let parameter = fromArguments.pendingParameter {
            throw ParseError("missing value for '-\(parameter)'")
        }

        // Command line arguments are strict: conflicting settings are errors.

        let argumentDevices = fromArguments.devices.uniqued()
        if argumentDevices.count > 1 || (!argumentDevices.isEmpty && !patterns.isEmpty) {
            let names = argumentDevices.map(\.keyword) + (patterns.isEmpty ? [] : ["--device"])
            throw ParseError("conflicting device settings: \(names.joined(separator: ", "))")
        }

        let argumentStreams = fromArguments.streams.uniqued()
        if argumentStreams.count > 1 {
            throw ParseError("conflicting stream settings: \(argumentStreams.map(\.keyword).joined(separator: ", "))")
        }

        if fromArguments.noSleep && (fromArguments.sleepDisplay || fromArguments.sleepLock) {
            throw ParseError("conflicting sleep settings: nosleep can't be combined with other sleep settings")
        }

        // Combine: arguments override what the file name says.

        var settings = Settings()
        settings.verbose = verbose

        if !patterns.isEmpty {
            settings.devices = .named(patterns)
        } else if let device = argumentDevices.first {
            settings.devices = device
        } else if let device = Scanner.devicePriority.first(where: { fromName.devices.contains($0) }) {
            settings.devices = device
        }

        settings.allowRemote = fromName.remote || fromArguments.remote

        var parameters: [Character: Double] = [:]
        if let stream = argumentStreams.first {
            settings.setStream(stream)
        } else if let stream = Scanner.streamPriority.first(where: { fromName.streams.contains($0) }) {
            settings.setStream(stream)
            parameters = fromName.parameters
        }
        parameters.merge(fromArguments.parameters) { _, new in new }

        for (parameter, value) in parameters {
            switch parameter {
            case "f": settings.frequency = min(value, 96000)
            case "a": settings.amplitudePercent = min(value, 100)
            case "l": settings.playSeconds = value
            case "w": settings.waitSeconds = value
            case "t": settings.fadeSeconds = value
            default: break
            }
        }

        let sleep = fromArguments.hasSleepSettings ? fromArguments : fromName
        if sleep.noSleep {
            settings.preventSystemSleep = true
        } else {
            settings.sleepWithDisplay = sleep.sleepDisplay
            settings.sleepWithLock = sleep.sleepLock
        }

        if fromName.kill || fromArguments.kill {
            command = .kill
        }

        return Invocation(command: command, settings: settings)
    }

    private static let commandWords: [String: Command] = [
        "run": .run, "start": .run,
        "list": .list, "devices": .list, "ls": .list,
        "kill": .kill, "stop": .kill, "quit": .kill,
        "install": .install,
        "uninstall": .uninstall, "remove": .uninstall,
        "status": .status,
        "help": .help,
        "version": .version,
    ]
}

// ---------------------------------------------------------------------------------------------------------------------

private enum Keyword: CaseIterable {
    case primary, all, marked, analog, digital, remote
    case noSleep, sleepy, sleep
    case openOnly, zero, null, fluctuate, sine, white, brown, pink
    case kill

    var text: String {
        switch self {
        case .primary: return "primary"
        case .all: return "all"
        case .marked: return "marked"
        case .analog: return "analog"
        case .digital: return "digital"
        case .remote: return "remote"
        case .noSleep: return "nosleep"
        case .sleepy: return "sleepy"
        case .sleep: return "sleep"
        case .openOnly: return "openonly"
        case .zero: return "zero"
        case .null: return "null"
        case .fluctuate: return "fluctuate"
        case .sine: return "sine"
        case .white: return "white"
        case .brown: return "brown"
        case .pink: return "pink"
        case .kill: return "kill"
        }
    }

    var device: DeviceSelector? {
        switch self {
        case .primary: return .primary
        case .all: return .all
        case .marked: return .marked
        case .analog: return .analog
        case .digital: return .digital
        default: return nil
        }
    }

    var stream: StreamType? {
        switch self {
        case .openOnly: return .openOnly
        case .zero, .null: return .zero
        case .fluctuate: return .fluctuate
        case .sine: return .sine
        case .white: return .white
        case .brown: return .brown
        case .pink: return .pink
        default: return nil
        }
    }

    /// The longest keywords go first, so "sleepy" and "nosleep" are not taken for "sleep".
    static let table: [(keyword: Keyword, characters: [Character])] = allCases
        .map { (keyword: $0, characters: Array($0.text)) }
        .sorted { $0.characters.count > $1.characters.count }
}

private struct Scanner {
    /// When several settings of the same kind are found in a file name, these win (the same order as in the original).
    static let devicePriority: [DeviceSelector] = [.digital, .analog, .marked, .all, .primary]
    static let streamPriority: [StreamType] = [.openOnly, .zero, .fluctuate, .sine, .white, .brown, .pink]

    private static let separators: Set<Character> = ["-", "_", "=", ",", ".", "+", " ", "\t"]
    private static let parameterLetters: Set<Character> = ["f", "a", "l", "w", "t"]

    let lenient: Bool

    var devices: [DeviceSelector] = []
    var streams: [StreamType] = []
    var parameters: [Character: Double] = [:]
    var remote = false
    var noSleep = false
    var sleepDisplay = false
    var sleepLock = false
    var kill = false

    /// A parameter letter whose value is expected in the next argument ("-f 1000").
    var pendingParameter: Character?

    /// File names are parsed like the original does: parameters are expected right after the stream type only.
    private var parameterContext: Bool

    init(lenient: Bool) {
        self.lenient = lenient
        self.parameterContext = !lenient
    }

    var hasSleepSettings: Bool { noSleep || sleepDisplay || sleepLock }

    mutating func scan(_ token: String) throws {
        let characters = Array(token)

        if let parameter = pendingParameter {
            guard let (value, end) = Self.number(characters, at: 0), end == characters.count else {
                throw ParseError("missing value for '-\(parameter)'")
            }
            parameters[parameter] = value
            pendingParameter = nil
            return
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if Self.separators.contains(character) {
                index += 1
                continue
            }

            if let (keyword, length) = Self.keyword(characters, at: index) {
                index += length
                apply(keyword)

                if keyword == .sleep {
                    // "sleepd", "sleepl", "sleepld", "sleep-d-l".
                    while index < characters.count {
                        if characters[index] == "d" { sleepDisplay = true }
                        else if characters[index] == "l" { sleepLock = true }
                        else if !Self.separators.contains(characters[index]) { break }
                        index += 1
                    }
                }
                continue
            }

            if parameterContext && Self.parameterLetters.contains(character) {
                var valueStart = index + 1
                while valueStart < characters.count, characters[valueStart] == "=" || characters[valueStart] == " " || characters[valueStart] == "\t" {
                    valueStart += 1
                }

                if let (value, end) = Self.number(characters, at: valueStart) {
                    parameters[character] = value
                    index = end
                    continue
                }

                if !lenient && valueStart == characters.count {
                    pendingParameter = character
                    return
                }
            }

            guard lenient else { throw ParseError("unknown setting '\(token)'") }

            parameterContext = false
            index += 1
        }
    }

    private mutating func apply(_ keyword: Keyword) {
        if let device = keyword.device { devices.append(device) }
        if let stream = keyword.stream { streams.append(stream) }

        switch keyword {
        case .remote: remote = true
        case .noSleep: noSleep = true
        case .sleepy:
            sleepDisplay = true
            sleepLock = true
        case .kill: kill = true
        default: break
        }

        if lenient {
            parameterContext = keyword.stream?.hasParameters ?? false
        }
    }

    private static func keyword(_ characters: [Character], at index: Int) -> (Keyword, Int)? {
        for entry in Keyword.table {
            let end = index + entry.characters.count
            if end <= characters.count && characters[index..<end].elementsEqual(entry.characters) {
                return (entry.keyword, entry.characters.count)
            }
        }
        return nil
    }

    /// A non-negative decimal number that starts with a digit.
    private static func number(_ characters: [Character], at start: Int) -> (Double, Int)? {
        func isDigit(_ index: Int) -> Bool {
            index < characters.count && characters[index] >= "0" && characters[index] <= "9"
        }

        var end = start
        while isDigit(end) { end += 1 }
        guard end > start else { return nil }

        if end < characters.count && characters[end] == "." && isDigit(end + 1) {
            end += 1
            while isDigit(end) { end += 1 }
        }

        guard let value = Double(String(characters[start..<end])), value.isFinite else { return nil }
        return (value, end)
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) { result.append(element) }
        return result
    }
}
