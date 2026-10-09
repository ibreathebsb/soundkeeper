import AppKit
import CoreGraphics
import Foundation

/// Watches for events that are reasons to be silent: system sleep, display sleep, screen lock, fast user switching.
///
/// Notifications are delivered by the run loop of the main thread, so it must be running.
public final class PowerMonitor {
    public typealias Handler = (SleepReason, Bool) -> Void

    public static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    public static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let handler: Handler
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init(observeDisplay: Bool, observeLock: Bool, handler: @escaping Handler) {
        self.handler = handler

        // Workspace notifications are posted on the main thread, and the system waits until the handler of the
        // "will sleep" notification returns. So the stream is stopped before the Mac actually goes to sleep.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .systemSleep, true)
        observe(workspace, NSWorkspace.didWakeNotification, .systemSleep, false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)

        if observeDisplay {
            observe(workspace, NSWorkspace.screensDidSleepNotification, .displayOff, true)
            observe(workspace, NSWorkspace.screensDidWakeNotification, .displayOff, false)
        }

        if observeLock {
            let distributed = DistributedNotificationCenter.default()
            observe(distributed, Self.screenLockedNotification, .screenLocked, true)
            observe(distributed, Self.screenUnlockedNotification, .screenLocked, false)
        }
    }

    deinit {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: SleepReason, _ active: Bool) {
        let handler = self.handler
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                handler(reason, active)
            } else {
                DispatchQueue.main.async { handler(reason, active) }
            }
        }
        observers.append((center, token))
    }

    /// Reasons that are already in effect when Sound Keeper is started.
    public static func currentReasons(observeDisplay: Bool, observeLock: Bool) -> Set<SleepReason> {
        var reasons: Set<SleepReason> = []

        if observeDisplay && CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            reasons.insert(.displayOff)
        }

        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if observeLock, let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked {
                reasons.insert(.screenLocked)
            }
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
                reasons.insert(.sessionInactive)
            }
        }

        return reasons
    }
}
