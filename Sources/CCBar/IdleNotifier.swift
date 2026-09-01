import Foundation
import UserNotifications

// Tracks Claude sessions that have been awaiting input for a while and fires
// a single macOS notification per "idle period" (resets when the session
// becomes active again).
final class IdleNotifier {
    private static let idleThreshold: TimeInterval = 600   // 10 minutes

    // All mutable state below is confined to this serial queue. Callers reach
    // us from the scan queue while UNUserNotificationCenter's authorization
    // callback lands on a UN-internal queue, so without the hop the granted
    // flag had two writer threads and no ordering between them.
    private let queue = DispatchQueue(label: "com.ccbar.idle-notifier")
    private var notifiedSessionIds = Set<String>()         // dedup per idle period
    private var authorizationRequested = false
    private var authorizationGranted = false

    // No-op: kept for source-compatibility with AppState.start(). We *defer*
    // touching UNUserNotificationCenter until the first time we actually have
    // something to notify. Calling +currentNotificationCenter at app launch
    // can abort the whole process on macOS Sonoma+ if the bundle's identity
    // isn't fully resolved, so we never call it eagerly.
    func requestAuthorization() {}

    // Call on each scan, from any thread. Work is handed to our own queue so
    // the dedup set and auth flags stay single-threaded.
    func evaluate(sessions: [ClaudeSession]) {
        queue.async { [weak self] in self?.evaluateOnQueue(sessions: sessions) }
    }

    // Lazily requests authorization the first time we'd actually fire
    // something. Skips silently if anything goes wrong.
    private func evaluateOnQueue(sessions: [ClaudeSession]) {
        let idle = sessions.filter { $0.isAwaitingInput && $0.idleSeconds >= Self.idleThreshold }

        // Clear dedup flags for sessions that are no longer idle, BEFORE the
        // early return. The pass that observes a session going active is, on a
        // one-session-at-a-time machine, exactly the pass where nothing is idle
        // — so pruning behind the guard never ran and every session notified
        // once for the lifetime of the app.
        notifiedSessionIds.formIntersection(Set(idle.map(\.sessionId)))

        guard !idle.isEmpty else { return }
        ensureAuthorization()
        guard authorizationGranted else { return }

        for session in idle where !notifiedSessionIds.contains(session.sessionId) {
            notify(session: session)
            notifiedSessionIds.insert(session.sessionId)
        }
    }

    private func ensureAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self else { return }
            self.queue.async { self.authorizationGranted = granted }
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
