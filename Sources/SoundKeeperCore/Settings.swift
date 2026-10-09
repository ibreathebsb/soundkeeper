import CSoundKeeperRender
import Foundation

/// What is sent to the audio output to keep it awake.
public enum StreamType: String, CaseIterable, Equatable {
    /// Opens the audio output, but doesn't play anything.
    case openOnly = "openonly"
    /// Stream of zeroes.
    case zero
    /// Stream of zeroes with the smallest non-zero samples now and then.
    case fluctuate
    case sine
    case white
    case brown
    case pink

    public var keyword: String { rawValue }

    public var isNoise: Bool { self == .white || self == .brown || self == .pink }
    public var usesFrequency: Bool { self == .fluctuate || self == .sine }
    public var usesAmplitude: Bool { self == .sine || isNoise }
    public var hasParameters: Bool { usesFrequency || usesAmplitude }

    var renderType: SKStreamType {
        switch self {
        case .openOnly: return .openOnly
        case .zero: return .zero
        case .fluctuate: return .fluctuate
        case .sine: return .sine
        case .white: return .whiteNoise
        case .brown: return .brownNoise
        case .pink: return .pinkNoise
        }
    }
}

/// Which audio outputs are kept awake.
public enum DeviceSelector: Equatable {
    /// The default output device. It is followed when the default device is changed.
    case primary
    /// All real output devices.
    case all
    /// HDMI, DisplayPort and S/PDIF outputs.
    case digital
    /// All real output devices except HDMI, DisplayPort and S/PDIF.
    case analog
    /// Outputs that have an exclamation mark "!" in their name.
    case marked
    /// Outputs whose name contains one of the patterns (case insensitive), or whose UID is equal to it.
    case named([String])

    public var keyword: String {
        switch self {
        case .primary: return "primary"
        case .all: return "all"
        case .digital: return "digital"
        case .analog: return "analog"
        case .marked: return "marked"
        case .named: return "device"
        }
    }
}

public struct Settings: Equatable {
    public var devices: DeviceSelector = .primary
    /// Keep AirPlay devices too. They are remote network devices, so they are ignored by default.
    public var allowRemote = false

    public var stream: StreamType = .fluctuate
    /// Hz. Fluctuate and Sine.
    public var frequency: Double = 50
    /// Percents, 0...100. Sine and noise.
    public var amplitudePercent: Double = 0
    /// Length of sound in seconds. 0 is infinite.
    public var playSeconds: Double = 0
    /// Waiting time between sounds in seconds.
    public var waitSeconds: Double = 0
    /// Fading time in seconds. Sine and noise.
    public var fadeSeconds: Double = 0

    /// Stop when all displays are sleeping.
    public var sleepWithDisplay = false
    /// Stop when the screen is locked.
    public var sleepWithLock = false
    /// Behave like any other audio player: the Mac doesn't go to idle sleep while the stream is playing.
    public var preventSystemSleep = false

    public var verbose = false

    public init() {}

    public var amplitude: Double { amplitudePercent / 100.0 }

    /// Sets stream type and its default parameters.
    public mutating func setStream(_ stream: StreamType) {
        self.stream = stream
        frequency = 0
        amplitudePercent = 0
        playSeconds = 0
        waitSeconds = 0
        fadeSeconds = 0

        switch stream {
        case .fluctuate:
            frequency = 50
        case .sine:
            frequency = 1
            amplitudePercent = 1
            fadeSeconds = 0.1
        case .white, .brown, .pink:
            amplitudePercent = 1
            fadeSeconds = 0.1
        case .openOnly, .zero:
            break
        }
    }

    /// The settings as command line arguments. `SettingsParser` turns them back into the same settings.
    public var arguments: [String] {
        var result: [String] = []

        switch devices {
        case .named(let patterns):
            for pattern in patterns { result += ["--device", pattern] }
        default:
            result.append(devices.keyword)
        }
        if allowRemote { result.append("remote") }

        result.append(stream.keyword)
        if stream.usesFrequency { result += ["-f", Self.format(frequency)] }
        if stream.usesAmplitude { result += ["-a", Self.format(amplitudePercent)] }
        if stream.hasParameters {
            if playSeconds > 0 { result += ["-l", Self.format(playSeconds)] }
            if waitSeconds > 0 { result += ["-w", Self.format(waitSeconds)] }
            if stream.usesAmplitude || fadeSeconds > 0 { result += ["-t", Self.format(fadeSeconds)] }
        }

        if preventSystemSleep {
            result.append("nosleep")
        } else if sleepWithDisplay || sleepWithLock {
            result.append("sleep" + (sleepWithLock ? "l" : "") + (sleepWithDisplay ? "d" : ""))
        }

        return result
    }

    /// A short description for humans.
    public var summary: String {
        var parts: [String] = []

        switch devices {
        case .primary: parts.append("Devices: primary output")
        case .all: parts.append("Devices: all outputs")
        case .digital: parts.append("Devices: digital outputs (HDMI, DisplayPort, S/PDIF)")
        case .analog: parts.append("Devices: analog outputs")
        case .marked: parts.append("Devices: outputs marked with \"!\"")
        case .named(let patterns): parts.append("Devices: " + patterns.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if allowRemote { parts[0] += " (AirPlay is allowed)" }

        var stream: String
        switch self.stream {
        case .openOnly: stream = "open only"
        case .zero: stream = "zero"
        case .fluctuate: stream = "fluctuate (\(Self.format(frequency)) Hz)"
        case .sine: stream = "sine (\(Self.format(frequency)) Hz, amplitude \(Self.format(amplitudePercent))%, fading \(Self.format(fadeSeconds)) s)"
        case .white, .brown, .pink: stream = "\(self.stream.keyword) noise (amplitude \(Self.format(amplitudePercent))%, fading \(Self.format(fadeSeconds)) s)"
        }
        if self.stream.hasParameters && (playSeconds > 0 || waitSeconds > 0) {
            stream += ", periodic (length \(Self.format(playSeconds)) s, waiting \(Self.format(waitSeconds)) s)"
        }
        parts.append("Stream: " + stream)

        var sleep: [String] = [preventSystemSleep ? "keeps the Mac awake" : "lets the Mac sleep"]
        if sleepWithDisplay { sleep.append("stops when displays are off") }
        if sleepWithLock { sleep.append("stops when the screen is locked") }
        parts.append("Sleep: " + sleep.joined(separator: ", "))

        return parts.joined(separator: ". ") + "."
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
