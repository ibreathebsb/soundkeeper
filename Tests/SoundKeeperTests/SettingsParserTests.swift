import Foundation
import SoundKeeperCore
import Testing

private func parse(_ line: String, name: String? = nil) throws -> Invocation {
    try SettingsParser.parse(arguments: line.split(separator: " ").map(String.init), executableName: name)
}

private func settings(_ line: String, name: String? = nil) throws -> Settings {
    try parse(line, name: name).settings
}

@Suite struct SettingsParserTests {

    @Test func defaults() throws {
        let invocation = try parse("")
        #expect(invocation.command == .run)

        let settings = invocation.settings
        #expect(settings.devices == .primary)
        #expect(settings.stream == .fluctuate)
        #expect(settings.frequency == 50)
        #expect(settings.amplitudePercent == 0)
        #expect(!settings.allowRemote && !settings.sleepWithDisplay && !settings.sleepWithLock && !settings.preventSystemSleep && !settings.verbose)
        #expect(settings == Settings())
    }

    @Test func deviceTypes() throws {
        #expect(try settings("all").devices == .all)
        #expect(try settings("ALL").devices == .all)
        #expect(try settings("Digital").devices == .digital)
        #expect(try settings("analog").devices == .analog)
        #expect(try settings("marked").devices == .marked)
        #expect(try settings("primary").devices == .primary)
        #expect(try settings("--all").devices == .all)
        #expect(try settings("remote").allowRemote)
        #expect(try settings("all remote").devices == .all)
    }

    @Test func devicesByName() throws {
        let named = try SettingsParser.parse(arguments: ["-d", "JBL GO 2", "--device", "Wall Speaker", "--device=Kitchen all", "sine"]).settings
        // Names are taken as they are: "all" inside of a name is not the "all" setting.
        #expect(named.devices == .named(["JBL GO 2", "Wall Speaker", "Kitchen all"]))
        #expect(named.stream == .sine)

        #expect(throws: ParseError.self) { try parse("-d") }
        #expect(throws: ParseError.self) { try parse("--device=") }
        #expect(throws: ParseError.self) { try parse("all -d JBL") }
    }

    @Test func streamTypesAndTheirDefaults() throws {
        #expect(try settings("openonly").stream == .openOnly)
        #expect(try settings("zero").stream == .zero)
        #expect(try settings("null").stream == .zero)

        let sine = try settings("sine")
        #expect(sine.stream == .sine)
        #expect(sine.frequency == 1)
        #expect(sine.amplitudePercent == 1)
        #expect(sine.amplitude == 0.01)
        #expect(sine.fadeSeconds == 0.1)

        for (keyword, stream) in [("white", StreamType.white), ("brown", .brown), ("pink", .pink)] {
            let noise = try settings(keyword)
            #expect(noise.stream == stream)
            #expect(noise.frequency == 0)
            #expect(noise.amplitudePercent == 1)
            #expect(noise.fadeSeconds == 0.1)
        }

        let zero = try settings("zero")
        #expect(zero.frequency == 0 && zero.amplitudePercent == 0 && zero.fadeSeconds == 0)
    }

    @Test func parametersInAllTheirForms() throws {
        // The examples of the original.
        let expected = try settings("sine -f 1000 -a 15")
        #expect(expected.frequency == 1000)
        #expect(expected.amplitudePercent == 15)
        #expect(expected.fadeSeconds == 0.1)

        for line in ["SineF1000A15", "sine f1000 a15", "sine -f1000 -a15", "sine -f=1000 -a=15", "sine f=1000,a=15", "SINE -F 1000 -A 15", "--sine -f 1000 -a 15", "-a 15 -f 1000 sine"] {
            #expect(try settings(line) == expected, "\(line)")
        }

        let brown = try settings("brown -a 0.1")
        #expect(brown.stream == .brown)
        #expect(brown.amplitudePercent == 0.1)
        #expect(abs(brown.amplitude - 0.001) < 1e-12)

        let periodic = try settings("sine -f 440 -l 2.5 -w 10 -t 0.25")
        #expect(periodic.playSeconds == 2.5)
        #expect(periodic.waitSeconds == 10)
        #expect(periodic.fadeSeconds == 0.25)

        // Parameters without a stream type are parameters of the default one.
        let fluctuate = try settings("-f 10")
        #expect(fluctuate.stream == .fluctuate)
        #expect(fluctuate.frequency == 10)
    }

    @Test func parametersAreLimited() throws {
        #expect(try settings("sine -f 500000").frequency == 96000)
        #expect(try settings("sine -a 250").amplitudePercent == 100)
    }

    @Test func sleepSettings() throws {
        var sleep = try settings("sleepd")
        #expect(sleep.sleepWithDisplay && !sleep.sleepWithLock && !sleep.preventSystemSleep)

        sleep = try settings("SleepL")
        #expect(!sleep.sleepWithDisplay && sleep.sleepWithLock)

        for line in ["sleepld", "sleepdl", "sleepy", "sleep-l-d", "sleepd sleepl"] {
            sleep = try settings(line)
            #expect(sleep.sleepWithDisplay && sleep.sleepWithLock, "\(line)")
        }

        sleep = try settings("nosleep")
        #expect(sleep.preventSystemSleep && !sleep.sleepWithDisplay && !sleep.sleepWithLock)

        #expect(throws: ParseError.self) { try parse("nosleep sleepd") }
    }

    @Test func commands() throws {
        #expect(try parse("run all").command == .run)
        #expect(try parse("list all").command == .list)
        #expect(try parse("devices").command == .list)
        #expect(try parse("kill").command == .kill)
        #expect(try parse("stop").command == .kill)
        #expect(try parse("status").command == .status)
        #expect(try parse("uninstall").command == .uninstall)
        #expect(try parse("help").command == .help)
        #expect(try parse("--help").command == .help)
        #expect(try parse("sine -h").command == .help)
        #expect(try parse("--version").command == .version)

        // "install" contains "all", but it's a command, not the "all" setting.
        let install = try parse("install sine -f 10 -a 5 sleepd")
        #expect(install.command == .install)
        #expect(install.settings.devices == .primary)
        #expect(install.settings.stream == .sine)
        #expect(install.settings.frequency == 10)
        #expect(install.settings.sleepWithDisplay)

        // Like in the original, "kill" works as a setting too.
        #expect(try parse("all kill").command == .kill)
    }

    @Test func verbose() throws {
        #expect(try settings("-v").verbose)
        #expect(try settings("--verbose sine").verbose)
        #expect(try settings("sine debug").stream == .sine)
        #expect(!(try settings("sine").verbose))
    }

    @Test func mistakesAreReported() {
        for line in ["sin", "sine -x 5", "alll", "sine -f", "sine -f abc", "-a", "sine brown", "all digital", "sine -f -5", "f.5", "--device", "sleepx"] {
            #expect(throws: ParseError.self, "\(line)") { try parse(line) }
        }
    }

    @Test func executableName() throws {
        // The examples of the original.
        var fromName = try settings("", name: "SoundKeeperZeroAll")
        #expect(fromName.devices == .all)
        #expect(fromName.stream == .zero)

        fromName = try settings("", name: "SoundKeeperAll")
        #expect(fromName.devices == .all)
        #expect(fromName.stream == .fluctuate)

        fromName = try settings("", name: "SoundKeeperSineF10A5")
        #expect(fromName.stream == .sine)
        #expect(fromName.frequency == 10)
        #expect(fromName.amplitudePercent == 5)
        #expect(fromName.fadeSeconds == 0.1)

        fromName = try settings("", name: "SoundKeeperSineF1000A15SleepLD")
        #expect(fromName.frequency == 1000 && fromName.amplitudePercent == 15)
        #expect(fromName.sleepWithDisplay && fromName.sleepWithLock)

        // The plain names mean defaults, and garbage is ignored.
        for name in ["soundkeeper", "SoundKeeper", "soundkeeper-1.0.0-arm64", "sound keeper (copy 2)", "sk", "SoundKeeperApp"] {
            #expect(try parse("", name: name) == Invocation(command: .run, settings: Settings()), "\(name)")
        }

        // Parameters are expected right after the stream type only: "t1" of "test1" is not a fading time.
        #expect(try settings("", name: "soundkeeper-sine-test1").fadeSeconds == 0.1)

        // When several settings of the same kind are in the name, the original has a fixed priority.
        #expect(try settings("", name: "SoundKeeperAllDigital").devices == .digital)
        #expect(try settings("", name: "SoundKeeperSineZero").stream == .zero)

        #expect(try parse("", name: "SoundKeeperKill").command == .kill)
    }

    @Test func argumentsOverrideExecutableName() throws {
        var combined = try settings("digital", name: "SoundKeeperSineF10A5All")
        #expect(combined.devices == .digital)
        #expect(combined.stream == .sine)
        #expect(combined.frequency == 10)

        // A new stream type drops parameters of the old one.
        combined = try settings("brown", name: "SoundKeeperSineF10A5All")
        #expect(combined.devices == .all)
        #expect(combined.stream == .brown)
        #expect(combined.frequency == 0)
        #expect(combined.amplitudePercent == 1)

        // Parameters alone adjust the stream from the name.
        combined = try settings("-a 2", name: "SoundKeeperSineF10A5")
        #expect(combined.stream == .sine)
        #expect(combined.frequency == 10)
        #expect(combined.amplitudePercent == 2)

        combined = try settings("nosleep", name: "SoundKeeperSleepD")
        #expect(combined.preventSystemSleep && !combined.sleepWithDisplay)
    }

    @Test func argumentsRoundTrip() throws {
        let lines = [
            "", "all", "digital zero", "analog openonly remote", "marked", "sine", "sine -f 1000 -a 15", "brown -a 0.1",
            "pink -a 0.25 -l 3 -w 60 -t 0.5", "fluctuate -f 1", "fluctuate -f 0.5 -l 1 -w 2", "white sleepd", "sleepl", "sleepy all", "nosleep sine",
            "sine -f 12.5 -a 0.001 -t 0",
        ]
        for line in lines {
            let original = try settings(line)
            let restored = try SettingsParser.parse(arguments: original.arguments)
            #expect(restored.command == .run, "\(line)")
            #expect(restored.settings == original, "\(line) -> \(original.arguments)")
        }

        var named = Settings()
        named.devices = .named(["JBL GO 2", "00-11-22-33-44-55:output", "all"])
        #expect(try SettingsParser.parse(arguments: named.arguments).settings == named)

        #expect(Settings().arguments == ["primary", "fluctuate", "-f", "50"])
        #expect(try settings("sine sleepld").arguments == ["primary", "sine", "-f", "1", "-a", "1", "-t", "0.1", "sleepld"])
    }
}
