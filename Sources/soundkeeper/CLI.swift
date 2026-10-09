import Foundation
import SoundKeeperCore

enum CLI {
    static let usageError: Int32 = 64

    static func main(arguments: [String]) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try SettingsParser.parse(
                arguments: Array(arguments.dropFirst()),
                executableName: arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            )
        } catch {
            printError("\(error)")
            printError("Try 'soundkeeper help'.")
            return usageError
        }

        let settings = invocation.settings
        Log.configure(verbose: settings.verbose)

        switch invocation.command {
        case .help:
            print(usage)
            return 0
        case .version:
            print(AppInfo.banner)
            return 0
        case .list:
            return list(settings)
        case .status:
            return status()
        case .kill:
            return kill()
        case .install:
            return install(settings)
        case .uninstall:
            return uninstall()
        case .run:
            run(settings)
        }
    }

    // -----------------------------------------------------------------------------------------------------------------

    /// Keeps audio outputs awake until the process is stopped.
    static func run(_ settings: Settings) -> Never {
        let service = KeeperService(frontend: "command line tool")

        // When a user starts a new Sound Keeper instance, the previous one is stopped automatically.
        do {
            try service.acquireLock()
        } catch {
            printError("\(error)")
            exit(1)
        }

        Log.info(AppInfo.banner)
        Log.info(settings.summary)

        signal(SIGPIPE, SIG_IGN)

        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Log.info("Shutdown.")
                service.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        service.start(settings: settings)

        // Power and session notifications need the run loop of the main thread. It also serves the main queue.
        withExtendedLifetime(signalSources) {
            CFRunLoopRun()
        }
        exit(0)
    }

    // -----------------------------------------------------------------------------------------------------------------

    static func list(_ settings: Settings) -> Int32 {
        let decisions = decideDevices(settings: settings, snapshot: CoreAudioSystem().snapshot())

        guard !decisions.isEmpty else {
            print("No audio outputs found.")
            return 0
        }

        var rows = [["", "OUTPUT", "TRANSPORT", "FORMAT", "AWAKE", "KEEP", ""]]
        for decision in decisions {
            let device = decision.device
            rows.append([
                decision.isDefault ? "*" : "",
                device.name,
                device.transport.name + (device.isDigital ? ", digital" : ""),
                "\(formatNumber(device.sampleRate)) Hz, \(device.channels) ch",
                device.isRunningSomewhere ? "yes" : "no",
                decision.keep ? "yes" : "no",
                decision.reason,
            ])
        }
        print(table(rows))

        print("")
        print("* is the default output. AWAKE: the hardware is running right now, since something is playing (maybe silence).")
        print("KEEP: what Sound Keeper would keep awake with these settings.")
        print(settings.summary)
        return 0
    }

    static func status() -> Int32 {
        let paths = Paths.standard()
        let agent = LaunchAgent(paths: paths)

        print(AppInfo.banner)

        let pid = InstanceLock(url: paths.lockFile).holder()
        if let pid {
            let status = StatusFile(url: paths.statusFile).read().flatMap { $0.pid == pid ? $0 : nil }
            print("Running:    yes (PID \(pid)" + (status.map { ", \($0.frontend)" } ?? "") + ")")

            if let status {
                print("Settings:   \(status.arguments.joined(separator: " "))")
                print("            \(status.settings)")
                if status.paused {
                    print("Outputs:    none (Sound Keeper is turned off)")
                } else if !status.sleeping.isEmpty {
                    print("Outputs:    none (silent: \(status.sleeping.joined(separator: ", ")))")
                } else if status.sessions.isEmpty {
                    print("Outputs:    none (no suitable devices found)")
                } else {
                    let awake = Dictionary(CoreAudioSystem().snapshot().devices.map { ($0.uid, $0.isRunningSomewhere) }, uniquingKeysWith: { first, _ in first })
                    for (index, session) in status.sessions.enumerated() {
                        let hardware = awake[session.uid].map { $0 ? "hardware is awake" : "hardware is NOT running" } ?? "device is not present"
                        print("\(index == 0 ? "Outputs:   " : "           ") \(session.name) [\(session.transport)]: \(session.state); \(hardware)")
                    }
                }
            }
        } else {
            print("Running:    no")
        }

        if agent.isInstalled {
            print("Login item: installed (\(paths.agentPlist.path))")
            print("            runs: \(agent.installedCommand?.joined(separator: " ") ?? "?")")
        } else {
            print("Login item: not installed (turn on \"Start at Login\" in the menu of the app, or use 'soundkeeper install')")
        }

        return pid != nil ? 0 : 1
    }

    static func kill() -> Int32 {
        let paths = Paths.standard()

        do {
            if let pid = try InstanceLock(url: paths.lockFile).stopRunningInstance() {
                print("Sound Keeper (PID \(pid)) is stopped.")
                if LaunchAgent(paths: paths).isInstalled {
                    print("It will be started again at the next login. Use 'soundkeeper uninstall' to remove it from login items.")
                }
            } else {
                print("Sound Keeper is not running.")
            }
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
    }

    static func install(_ settings: Settings) -> Int32 {
        let paths = Paths.standard()
        let agent = LaunchAgent(paths: paths)

        guard let executable = Bundle.main.executableURL else {
            printError("unable to find the path of the executable")
            return 1
        }

        do {
            try agent.install(executable: executable, settings: settings)
        } catch {
            printError("\(error)")
            return 1
        }

        print("Installed:  \(paths.agentPlist.path)")
        print("Executable: \(paths.installedExecutable.path)")
        print("Settings:   \(settings.arguments.joined(separator: " "))")
        print("            \(settings.summary)")

        // The agent stops the instance that was running before (if any) and takes its place.
        let lock = InstanceLock(url: paths.lockFile)
        let deadline = Date().addingTimeInterval(5)
        var statusPID: Int32?
        while Date() < deadline {
            if let pid = lock.holder(), StatusFile(url: paths.statusFile).read()?.pid == pid {
                statusPID = pid
                break
            }
            usleep(100_000)
        }

        if let statusPID {
            print("Sound Keeper is running (PID \(statusPID)) and will be started at every login.")
            print("Use 'soundkeeper status' to check it, and 'soundkeeper uninstall' to remove it.")
            return 0
        } else {
            printError("the login item is installed, but Sound Keeper doesn't seem to be running. Check 'soundkeeper status'.")
            return 1
        }
    }

    static func uninstall() -> Int32 {
        let paths = Paths.standard()

        if LaunchAgent(paths: paths).uninstall() {
            print("The login item is removed.")
        } else {
            print("The login item is not installed.")
        }

        if let pid = InstanceLock(url: paths.lockFile).holder() {
            print("Note: Sound Keeper that was started manually is still running (PID \(pid)). Use 'soundkeeper kill' to stop it.")
        }
        return 0
    }

    // -----------------------------------------------------------------------------------------------------------------

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("soundkeeper: \(message)\n".utf8))
    }

    static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(value)
    }

    /// Width of a string in a terminal: CJK characters and emoji take two columns.
    static func displayWidth(_ string: String) -> Int {
        string.unicodeScalars.reduce(0) { width, scalar in
            switch scalar.value {
            case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F:
                return width
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
                 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                return width + 2
            default:
                return width + 1
            }
        }
    }

    static func table(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            rows.map { column < $0.count ? displayWidth($0[column]) : 0 }.max() ?? 0
        }

        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - displayWidth(cell))
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
    }

    static let usage = """
    \(AppInfo.banner)

    Prevents audio outputs (Bluetooth speakers, HDMI / DisplayPort / optical receivers, USB DACs, active monitors)
    from falling asleep, by always playing an inaudible stream to them.

    USAGE
      soundkeeper [settings]             Run until it is stopped. A previously started instance is stopped first.
      soundkeeper install [settings]     Start now and at every login (as a per-user launchd agent).
      soundkeeper uninstall              Stop and remove the login item.
      soundkeeper kill                   Stop the running instance.
      soundkeeper status                 Show what is running.
      soundkeeper list [settings]        List audio outputs and show which of them the settings keep awake.

    DEVICES - which outputs are kept awake
      primary             The default output. It is followed when you switch outputs. Used by default.
      all                 All hardware outputs.
      digital             HDMI, DisplayPort and S/PDIF outputs.
      analog              All hardware outputs except the digital ones.
      marked              Outputs with an exclamation mark "!" in their name.
      -d, --device NAME   Outputs whose name contains NAME, or whose UID is NAME. Can be repeated.
      remote              Don't ignore AirPlay outputs.

    STREAM - what is played
      openonly            Opens the output, but doesn't play anything. Sometimes it helps.
      zero                Plays a stream of zeroes. It may be not enough for some hardware.
      fluctuate           Plays zeroes with the smallest non-zero samples 50 times a second. Used by default.
      sine                Plays a 1 Hz sine wave at 1% volume. Useful for analog outputs and Bluetooth speakers.
      white, brown, pink  Plays the named noise at 1% volume.

      -f HZ               Frequency. Fluctuate (50 by default) and sine (1 by default).
      -a PERCENT          Amplitude. Sine and noise (1 by default). Use 0.1 for an inaudible noise.
      -l SECONDS          Length of the sound. Infinite by default.
      -w SECONDS          Waiting time between sounds if the length is set. Enables a periodic sound.
      -t SECONDS          Transition (fading) time. Sine and noise (0.1 by default).

    SLEEP
      The Mac is free to go to sleep while Sound Keeper is playing. In addition:
      sleepd              Be silent while displays are sleeping.
      sleepl              Be silent while the screen is locked.
      sleepld, sleepy     Both.
      nosleep             Keep the Mac awake, like a usual audio player does.

    OTHER
      -v, --verbose       Print what is going on.
      -h, --help          Show this help.
      --version           Show the version.

    Setting names are case insensitive and can be glued together like in Sound Keeper for Windows:
    "soundkeeper SineF10A5" is the same as "soundkeeper sine -f 10 -a 5".

    EXAMPLES
      soundkeeper                        Inaudible stream on the default output.
      soundkeeper all zero               Stream of zeroes on all outputs.
      soundkeeper sine -f 10 -a 5        10 Hz sine wave at 5% volume on the default output. It is inaudible.
      soundkeeper sine -f 1000 -a 15     1000 Hz sine wave at 15% volume. It is audible! Use it for testing.
      soundkeeper brown -a 0.1           Brown noise at 0.1% volume.
      soundkeeper install -d JBL sine    Keep outputs named like "JBL" awake with a sine wave, starting at login.
    """
}
