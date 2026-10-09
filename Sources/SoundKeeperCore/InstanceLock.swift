import Foundation

/// Makes sure that there is just one running Sound Keeper per user, and lets a new instance stop the old one.
///
/// The running instance holds a POSIX write lock on a file. The lock disappears together with its process no matter
/// how it dies, and the system tells who holds the lock, so there are no stale or wrong PIDs.
public final class InstanceLock {

    public enum LockError: Error, CustomStringConvertible {
        case cannotOpen(path: String, code: Int32)
        case alreadyRunning(pid: pid_t)
        case timeout(pid: pid_t)

        public var description: String {
            switch self {
            case .cannotOpen(let path, let code):
                return "unable to open \(path): \(String(cString: strerror(code)))"
            case .alreadyRunning(let pid):
                return "another instance is running (PID \(pid))"
            case .timeout(let pid):
                return "the running instance (PID \(pid)) doesn't stop"
            }
        }
    }

    private let path: String
    private var descriptor: Int32 = -1

    public init(url: URL) {
        self.path = url.path
    }

    deinit {
        release()
    }

    public var isHeld: Bool { descriptor >= 0 }

    /// PID of the running instance.
    public func holder() -> pid_t? {
        // The lock is dropped when its owner closes any descriptor of the file, so the owner must not open it again.
        if isHeld { return getpid() }

        // Asking who holds the lock doesn't require write access to the file.
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        return Self.holder(of: fd)
    }

    /// Takes the lock. Stops the running instance first if it's requested.
    public func acquire(replacingExisting: Bool, timeout: TimeInterval = 5) throws {
        guard !isHeld else { return }

        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LockError.cannotOpen(path: path, code: errno) }

        let deadline = Date().addingTimeInterval(timeout)
        var signaled: Set<pid_t> = []
        var lastHolder: pid_t = 0

        while true {
            var lock = Self.wholeFileLock()
            if fcntl(fd, F_SETLK, &lock) == 0 { break }

            let code = errno
            guard code == EAGAIN || code == EACCES else {
                close(fd)
                throw LockError.cannotOpen(path: path, code: code)
            }

            if let pid = Self.holder(of: fd) {
                lastHolder = pid
                guard replacingExisting else {
                    close(fd)
                    throw LockError.alreadyRunning(pid: pid)
                }
                if signaled.insert(pid).inserted {
                    Log.info("Stopping another instance (PID \(pid))...")
                    kill(pid, SIGTERM)
                }
            }

            guard Date() < deadline else {
                close(fd)
                throw LockError.timeout(pid: lastHolder)
            }
            usleep(50_000)
        }

        descriptor = fd

        // The PID in the file is just for curious humans.
        ftruncate(fd, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
    }

    public func release() {
        guard isHeld else { return }
        close(descriptor)
        descriptor = -1
    }

    /// Asks the running instance to stop and waits until it's gone. Returns its PID, or nil if nothing is running.
    @discardableResult
    public func stopRunningInstance(timeout: TimeInterval = 5) throws -> pid_t? {
        guard !isHeld, let pid = holder() else { return nil }

        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(timeout)
        while holder() == pid {
            guard Date() < deadline else { throw LockError.timeout(pid: pid) }
            usleep(50_000)
        }

        return pid
    }

    private static func wholeFileLock() -> flock {
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return lock
    }

    private static func holder(of fd: Int32) -> pid_t? {
        var lock = wholeFileLock()
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }
}
