import Foundation
import UserNotifications

// Watches GitHub PR state transitions and fires macOS notifications.
// Authorization is shared with IdleNotifier (single UN center per app).
final class GitHubMonitor {
    private var lastCheck: [String: CheckState] = [:]   // PR id → last seen
    private var notifiedReady: Set<String> = []         // dedup ready-to-merge
    private var notifiedFailedRuns: Set<String> = []    // dedup Action failures
    private var unGateFailed = false                    // skip UN if it ever fails

    func evaluate(prs: [GitHubPR], failedRuns: [FailedRun]) {
        guard !unGateFailed, Bundle.main.bundleIdentifier != nil else { return }

        // GitHubScanner returns an empty snapshot when `gh` is unauthenticated
        // or the API call fails, which is indistinguishable here from "nothing
        // open". Bail before the prunes below so an offline minute can't drop
        // every dedup flag and re-notify the whole backlog on reconnect.
        guard !prs.isEmpty || !failedRuns.isEmpty else { return }

        // Failed Action runs: notify once per run (id is unique per run).
        for run in failedRuns where !notifiedFailedRuns.contains(run.id) {
            notify(
                id: "ccbar.run.\(run.id)",
                title: "Action failed: \(run.workflow)",
                body: "\(run.repo) on \(run.branch)",
                url: run.url
            )
            notifiedFailedRuns.insert(run.id)
        }

        var stillReady: Set<String> = []
        var seenPRs: Set<String> = []
        for pr in prs {
            seenPRs.insert(pr.id)
            // Notify on every transition into a failing state. A check that
            // stays failing doesn't re-notify; a flake that fails → success →
            // fails again will notify each time it lands in the failing state.
            if let prev = lastCheck[pr.id] {
                let wasFailing = prev == .failure || prev == .error
                let nowFailing = pr.check == .failure || pr.check == .error
                if !wasFailing && nowFailing {
                    notify(
                        id: "ccbar.ci.\(pr.id).\(Date().timeIntervalSince1970)",
                        title: "CI failure",
                        body: "\(pr.repo) #\(pr.number) — \(pr.title)",
                        url: pr.url
                    )
                }
            }
            lastCheck[pr.id] = pr.check

            // Notify once when a PR becomes ready-to-merge; reset when it's
            // no longer ready (merged, conflict appears, approval rescinded).
            if pr.isReadyToMerge {
                stillReady.insert(pr.id)
                if !notifiedReady.contains(pr.id) {
                    notify(
                        id: "ccbar.ready.\(pr.id)",
                        title: "Ready to merge",
                        body: "\(pr.repo) #\(pr.number) — \(pr.title)",
                        url: pr.url
                    )
                    notifiedReady.insert(pr.id)
                }
            }
        }
        notifiedReady.formIntersection(stillReady)

        // Drop state for PRs and runs this pass no longer returns. The GraphQL
        // query filters `states: OPEN`, so a merged or closed PR would
        // otherwise keep its entry forever — and if it were reopened weeks
        // later, `wasFailing` would be read from that stale entry instead of
        // being re-established from what the check rollup actually reports.
        lastCheck = lastCheck.filter { seenPRs.contains($0.key) }
        notifiedFailedRuns.formIntersection(Set(failedRuns.map(\.id)))
    }

    private func notify(id: String, title: String, body: String, url: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
