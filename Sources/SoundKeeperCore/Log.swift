import Foundation
import os

/// Logging. Important events always go to the unified log (see them using
/// `/usr/bin/log show --last 1h --predicate 'subsystem == "local.soundkeeper"'`), and to stderr when a human is watching.
public enum Log {
    public enum Level: Int, Comparable {
        case debug, info, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The lowest level printed to stderr. `nil` disables console output.
    public static var consoleLevel: Level? = .warning

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "keeper")
    private static let consoleLock = NSLock()

    /// Errors are always printed. Events are printed when stderr is a terminal. Details are printed in verbose mode.
    public static func configure(verbose: Bool) {
        if verbose {
            consoleLevel = .debug
        } else if isatty(STDERR_FILENO) != 0 {
            consoleLevel = .info
        } else {
            consoleLevel = .warning
        }
    }

    public static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private static func write(_ level: Level, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        guard let consoleLevel, level >= consoleLevel else { return }

        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var local = tm()
        localtime_r(&seconds, &local)

        let prefix: String
        switch level {
        case .warning: prefix = "[WARNING] "
        case .error: prefix = "[ERROR] "
        default: prefix = ""
        }

        let line = String(format: "%02d:%02d:%02d.%03d ", local.tm_hour, local.tm_min, local.tm_sec, Int(now.tv_usec / 1000)) + prefix + message + "\n"

        consoleLock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        consoleLock.unlock()
    }
}
