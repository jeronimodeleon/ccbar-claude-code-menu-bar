import Foundation
import UserNotifications

// Tracks Claude sessions that have been awaiting input for a while and fires
// a single macOS notification per "idle period" (resets when the session
// becomes active again).
final class IdleNotifier {
    private static let idleThreshold: TimeInterval = 600   // 10 minutes
    private var notifiedSessionIds = Set<String>()         // dedup per idle period
    private var authorizationGranted = false

    func requestAuthorization() {
        // UNUserNotificationCenter requires a proper .app bundle context
        // (Info.plist + bundle ID). Running the bare binary from `build/`
        // would crash here — guard so the app stays usable even unbundled.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorizationGranted = granted
        }
    }

    // Call on each scan. Looks for sessions over threshold that haven't been
    // notified yet, and clears dedup for sessions that came back to life.
    func evaluate(sessions: [ClaudeSession]) {
        guard authorizationGranted else { return }

        var stillIdle = Set<String>()
        for session in sessions where session.isAwaitingInput {
            if session.idleSeconds >= Self.idleThreshold {
                stillIdle.insert(session.sessionId)
                if !notifiedSessionIds.contains(session.sessionId) {
                    notify(session: session)
                    notifiedSessionIds.insert(session.sessionId)
                }
            }
        }
        // A session that transitioned out of "awaiting input" (because user
        // typed something) gets its dedup flag cleared so the next idle period
        // can notify again.
        notifiedSessionIds = notifiedSessionIds.intersection(stillIdle)
    }

    private func notify(session: ClaudeSession) {
        let content = UNMutableNotificationContent()
        content.title = "Claude session idle"
        let label = session.displayTitle ?? session.projectName
        content.body = "\(label) — waiting \(formatMinutes(session.idleSeconds))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ccbar.idle.\(session.sessionId)",
            content: content,
            trigger: nil   // immediate
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}
