import Foundation
import UserNotifications

// Tracks Claude sessions that have been awaiting input for a while and fires
// a single macOS notification per "idle period" (resets when the session
// becomes active again).
final class IdleNotifier {
    private static let idleThreshold: TimeInterval = 600   // 10 minutes
    private var notifiedSessionIds = Set<String>()         // dedup per idle period
    private var authorizationRequested = false
    private var authorizationGranted = false

    // No-op: kept for source-compatibility with AppState.start(). We *defer*
    // touching UNUserNotificationCenter until the first time we actually have
    // something to notify. Calling +currentNotificationCenter at app launch
    // can abort the whole process on macOS Sonoma+ if the bundle's identity
    // isn't fully resolved, so we never call it eagerly.
    func requestAuthorization() {}

    // Call on each scan. Lazily requests authorization the first time we'd
    // actually fire something. Skips silently if anything goes wrong.
    func evaluate(sessions: [ClaudeSession]) {
        let needAttention = sessions.contains { s in
            s.isAwaitingInput && s.idleSeconds >= Self.idleThreshold
        }
        guard needAttention else { return }
        ensureAuthorization()
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

    private func ensureAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorizationGranted = granted
        }
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
