import SwiftUI
import AppKit
import ServiceManagement

@main
struct CCBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel(state: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}

// Reactive menu bar icon. Shows a filled terminal + count when any tab is
// "Waiting for input", so attention is visible without opening the popover.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        let waiting = state.tabs.filter { $0.state == .waiting }.count
        HStack(spacing: 2) {
            Image(systemName: waiting > 0 ? "terminal.fill" : "terminal")
            if waiting > 0 {
                Text("\(waiting)")
            }
        }
    }
}

// AppState owns long-lived services and publishes UI state.
final class AppState: ObservableObject {
    let power = PowerAssertion()
    private let tabScanner = TabScanner()
    private let serviceScanner = LocalServicesScanner()
    private let sessionScanner = ClaudeSessionScanner()
    private let worktreeScanner = WorktreeScanner()
    private let githubScanner = GitHubScanner()
    private let githubMonitor = GitHubMonitor()
    private let idleNotifier = IdleNotifier()
    private var refreshTimer: Timer?
    private var lastWorktreeScan: Date = .distantPast
    private var lastGitHubScan: Date = .distantPast

    @Published var tabs: [TerminalTab] = []
    @Published var services: [LocalService] = []
    @Published var repos: [GitRepo] = []
    @Published var myPRs: [GitHubPR] = []
    @Published var reviewQueue: [ReviewRequest] = []
    @Published var failedRuns: [FailedRun] = []
    @Published var dependabotAlerts: [DependabotAlert] = []
    @Published var githubAuthed: Bool = true

    func start() {
        power.acquire()
        idleNotifier.requestAuthorization()
        refresh()
        // 5s cadence: ps + lsof + session scan together stay well under a
        // second; cached session parsing skips unchanged files.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        power.release()
    }

    // Pair claude tabs with their specific session files using birth times.
    // Within each cwd, sort tabs by process start time (ascending) and sessions
    // by .jsonl creation date (ascending), then for each tab pick the smallest
    // unclaimed session whose creation date is >= the tab's start time (with
    // a small tolerance for clock jitter / claude's first-write delay).
    private func matchClaudeTabsToSessions(
        tabs: [TerminalTab], sessions: [ClaudeSession]
    ) -> [Int32: ClaudeSession] {
        let claudeTabs = tabs.filter { $0.foregroundName == "claude" && $0.cwd != nil }
        let tabsByCwd = Dictionary(grouping: claudeTabs, by: { $0.cwd! })
        let sessionsByPath = Dictionary(grouping: sessions, by: { $0.projectPath })

        // Allow a 5-minute slack: a session file's birth time can be a couple
        // of minutes after the process start (claude waits for first user input
        // before writing).
        let slack: TimeInterval = -300

        var result: [Int32: ClaudeSession] = [:]
        for (cwd, cwdTabs) in tabsByCwd {
            let sortedTabs = cwdTabs.sorted { $0.processStartedAt < $1.processStartedAt }
            let cwdSessions = (sessionsByPath[cwd] ?? [])
                .sorted { $0.creationDate < $1.creationDate }
            var claimed = Set<String>()
            for tab in sortedTabs {
                let pick = cwdSessions.first { s in
                    !claimed.contains(s.sessionId)
                        && s.creationDate.timeIntervalSince(tab.processStartedAt) >= slack
                }
                if let s = pick {
                    result[tab.foregroundPid] = s
                    claimed.insert(s.sessionId)
                }
            }
        }
        return result
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let rawTabs = self.tabScanner.scan()
            let services = self.serviceScanner.scan()
            let sessions = self.sessionScanner.scan()

            // Pair each claude tab to its specific session file. claude
            // doesn't expose its session ID and doesn't keep the .jsonl
            // open continuously, so we can't go via lsof. But the .jsonl
            // is created right after the process starts, so within each
            // cwd we can greedily pair tabs (sorted by start time) to
            // sessions (sorted by birth time), each session matched to
            // at most one tab.
            let pidToSession = self.matchClaudeTabsToSessions(
                tabs: rawTabs, sessions: sessions
            )

            let enrichedTabs = rawTabs.map { tab -> TerminalTab in
                guard let session = pidToSession[tab.foregroundPid] else { return tab }
                return TerminalTab(
                    id: tab.id,
                    terminalApp: tab.terminalApp,
                    tty: tab.tty,
                    shellPid: tab.shellPid,
                    shellName: tab.shellName,
                    foregroundPid: tab.foregroundPid,
                    foregroundName: tab.foregroundName,
                    foregroundArgs: tab.foregroundArgs,
                    foregroundCpu: tab.foregroundCpu,
                    cwd: tab.cwd,
                    processStartedAt: tab.processStartedAt,
                    claudeSession: session
                )
            }

            // Notifier fires across all sessions, even ones whose tab is closed.
            self.idleNotifier.evaluate(sessions: sessions)

            // Worktree scan is the most expensive part (multiple git calls
            // per worktree); rate-limit to ~20s.
            let now = Date()
            let dueWorktrees = now.timeIntervalSince(self.lastWorktreeScan) >= 20
            let repos: [GitRepo]?
            if dueWorktrees {
                let cwds = enrichedTabs.compactMap { $0.cwd }
                repos = self.worktreeScanner.scan(cwds: cwds)
                self.lastWorktreeScan = now
            } else {
                repos = nil
            }

            // GitHub scan: one GraphQL + per-repo REST. Rate-limit to 60s.
            // We scope per-repo calls (Actions runs, Dependabot) to repos
            // currently checked out — discovered via worktree origins.
            let dueGitHub = now.timeIntervalSince(self.lastGitHubScan) >= 60
            let github: GitHubSnapshot?
            if dueGitHub {
                let workingRepos = repos ?? self.repos
                let originRepos = Array(Set(workingRepos.flatMap(\.worktrees).compactMap(\.originRepo))).sorted()
                github = self.githubScanner.scan(repos: originRepos)
                self.lastGitHubScan = now
            } else {
                github = nil
            }

            DispatchQueue.main.async {
                self.tabs = enrichedTabs
                self.services = services
                if let repos { self.repos = repos }
                if let g = github {
                    self.myPRs = g.myPRs
                    self.reviewQueue = g.reviewQueue
                    self.failedRuns = g.failedRuns
                    self.dependabotAlerts = g.dependabotAlerts
                    self.githubAuthed = g.isAuthenticated
                    self.githubMonitor.evaluate(prs: g.myPRs, failedRuns: g.failedRuns)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stop()
    }
}

struct FolderGroup: Identifiable {
    let folder: String
    let tabs: [TerminalTab]
    let services: [LocalService]
    let worktrees: [Worktree]
    let reviewRequests: [ReviewRequest]
    let myPRs: [GitHubPR]
    let failedRuns: [FailedRun]
    let alerts: [DependabotAlert]

    var id: String { folder }
    var hasWaiting: Bool { tabs.contains { $0.state == .waiting } }
    var hasRunning: Bool { tabs.contains { $0.state == .running } }
}

struct MenuView: View {
    @EnvironmentObject private var state: AppState
    @State private var otherExpanded = false

    var body: some View {
        let groups = buildFolderGroups()
        let primary = groups.filter { !$0.tabs.isEmpty }
        let other   = groups.filter {  $0.tabs.isEmpty }
        let otherCount = other.reduce(0) { $0 + $1.services.count + $1.worktrees.count }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CCBar").font(.headline)
                Spacer()
                Text("\(state.tabs.count) tab\(state.tabs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if primary.isEmpty && other.isEmpty {
                Text("No activity detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(primary) { folderSection($0) }
            }

            if !state.githubAuthed {
                Divider()
                Text("GitHub: not authenticated — run `gh auth login`")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !other.isEmpty {
                Divider()
                Button { otherExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: otherExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Other")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("(\(otherCount))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if otherExpanded {
                    ForEach(other) { folderSection($0) }
                }
            }

            Divider()

            HStack {
                LaunchAtLoginToggle()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .onAppear { state.refresh() }
    }

    // Build one group per folder containing all tabs/services/worktrees that
    // resolve to that folder. Sort so attention-needing folders surface first.
    private func buildFolderGroups() -> [FolderGroup] {
        var folders: Set<String> = []
        for t in state.tabs       { folders.insert(t.folderName) }
        for s in state.services   { folders.insert(s.folderName) }
        for w in state.repos.flatMap(\.worktrees) { folders.insert(w.folderName) }

        let allWorktrees = state.repos.flatMap(\.worktrees)

        let groups = folders.map { folder -> FolderGroup in
            let tabs = state.tabs.filter { $0.folderName == folder }
                .sorted(by: tabSortOrder)
            let services = state.services.filter { $0.folderName == folder }
            let worktrees = allWorktrees.filter { $0.folderName == folder }
            // Match GitHub items by the worktrees' origin remotes in this folder.
            let originRepos = Set(worktrees.compactMap(\.originRepo))
            let reviews = state.reviewQueue.filter { originRepos.contains($0.repo) }
            let prs = state.myPRs.filter { originRepos.contains($0.repo) }
            let runs = state.failedRuns.filter { originRepos.contains($0.repo) }
            let alerts = state.dependabotAlerts.filter { originRepos.contains($0.repo) }
            return FolderGroup(folder: folder, tabs: tabs,
                               services: services, worktrees: worktrees,
                               reviewRequests: reviews, myPRs: prs,
                               failedRuns: runs, alerts: alerts)
        }

        return groups.sorted { folderSortOrder($0, $1) }
    }

    private func tabSortOrder(_ a: TerminalTab, _ b: TerminalTab) -> Bool {
        if a.state != b.state { return a.state < b.state }
        return a.compactLabel.localizedCaseInsensitiveCompare(b.compactLabel) == .orderedAscending
    }

    private func folderSortOrder(_ a: FolderGroup, _ b: FolderGroup) -> Bool {
        if a.hasWaiting != b.hasWaiting { return a.hasWaiting }
        if a.hasRunning != b.hasRunning { return a.hasRunning }
        return a.folder.localizedCaseInsensitiveCompare(b.folder) == .orderedAscending
    }

    @ViewBuilder
    private func folderSection(_ group: FolderGroup) -> some View {
        let total = group.tabs.count + group.services.count + group.worktrees.count
            + group.reviewRequests.count + group.myPRs.count
            + group.failedRuns.count + group.alerts.count
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(group.folder)
                    .font(.subheadline.weight(.semibold))
                Text("(\(total))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)

            ForEach(group.tabs) { TabRow(tab: $0) }
            ForEach(group.services) { ServiceRow(service: $0) }
            ForEach(group.worktrees) { WorktreeRow(worktree: $0) }
            ForEach(group.reviewRequests) { ReviewRow(item: $0) }
            ForEach(group.myPRs) { PRRow(pr: $0) }
            ForEach(group.failedRuns) { FailedRunRow(run: $0) }
            ForEach(group.alerts) { AlertRow(alert: $0) }
        }
    }
}

struct ReviewRow: View {
    let item: ReviewRequest
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .frame(width: 14, alignment: .center)
                Text("#\(item.number)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(daysAgo(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func open() {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        MenuDismisser.dismiss()
    }
}

struct PRRow: View {
    let pr: GitHubPR
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.caption2)
                    .foregroundStyle(pr.isDraft ? Color.secondary : Color.green)
                    .frame(width: 14, alignment: .center)

                Image(systemName: checkSymbol)
                    .foregroundStyle(checkColor)
                    .font(.caption2)
                if pr.review == .approved {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                } else if pr.review == .changesRequested {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                }
                if pr.mergeable == .conflicting {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                }
                if pr.isReadyToMerge {
                    Image(systemName: "arrow.merge")
                        .foregroundStyle(.green)
                        .font(.caption2)
                }
                Text("#\(pr.number)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(pr.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pr.isDraft ? .secondary : .primary)
                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var checkSymbol: String {
        switch pr.check {
        case .success:           return "checkmark.circle.fill"
        case .failure, .error:   return "xmark.circle.fill"
        case .pending, .expected:return "clock.fill"
        case .none:              return "minus.circle"
        }
    }

    private var checkColor: Color {
        switch pr.check {
        case .success:           return .green
        case .failure, .error:   return .red
        case .pending, .expected:return .orange
        case .none:              return .secondary
        }
    }

    private func open() {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        MenuDismisser.dismiss()
    }
}

struct FailedRunRow: View {
    let run: FailedRun
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(width: 14, alignment: .center)
                Text(run.workflow)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(run.branch)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(daysAgo(run.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func open() {
        if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
        MenuDismisser.dismiss()
    }
}

struct AlertRow: View {
    let alert: DependabotAlert
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(severityColor)
                    .frame(width: 14, alignment: .center)
                Text(alert.severity.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(severityColor)
                    .frame(width: 56, alignment: .leading)
                Text(alert.packageName)
                    .font(.caption.monospaced())
                Text(alert.summary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var severityColor: Color {
        switch alert.severity.lowercased() {
        case "critical": return .red
        case "high":     return .orange
        case "medium":   return .yellow
        case "low":      return .blue
        default:         return .secondary
        }
    }

    private func open() {
        if let url = URL(string: alert.url) { NSWorkspace.shared.open(url) }
        MenuDismisser.dismiss()
    }
}

private func daysAgo(_ date: Date) -> String {
    let interval = -date.timeIntervalSinceNow
    let days = Int(interval / 86400)
    if days >= 1 { return "\(days)d" }
    let hours = Int(interval / 3600)
    if hours >= 1 { return "\(hours)h" }
    let mins = Int(interval / 60)
    return "\(max(mins, 0))m"
}

struct WorktreeRow: View {
    let worktree: Worktree
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    var body: some View {
        Button(action: handleClick) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .frame(width: 14, alignment: .center)

                Text(worktree.branch ?? "(detached)")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(worktree.branch == nil ? .secondary : .primary)

                Spacer()

                if worktree.dirtyCount > 0 {
                    Label("\(worktree.dirtyCount)", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if worktree.hasUpstream {
                    if worktree.ahead > 0 {
                        Label("\(worktree.ahead)", systemImage: "arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    }
                    if worktree.behind > 0 {
                        Label("\(worktree.behind)", systemImage: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .labelStyle(.titleAndIcon)
                    }
                } else {
                    Text("no upstream")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func handleClick() {
        // If a terminal tab is currently sitting in this worktree, focus it;
        // otherwise reveal the worktree in Finder.
        if let tab = state.tabs.first(where: { $0.cwd == worktree.path }) {
            TabFocuser.focus(tab)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
            MenuDismisser.dismiss()
        }
    }
}

// macOS 13+ SMAppService — registers the .app bundle to launch at login.
// We defer the SMAppService.mainApp.status read until .onAppear so that any
// framework-level abort there can't take down the whole app at launch.
struct LaunchAtLoginToggle: View {
    @State private var enabled = false

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else        { try SMAppService.mainApp.unregister() }
                    enabled = newValue
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .onAppear {
            enabled = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ServiceRow: View {
    let service: LocalService
    @State private var hovering = false

    var body: some View {
        Button(action: handleClick) {
            HStack(spacing: 8) {
                Image(systemName: service.url == nil ? "cylinder" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .frame(width: 14, alignment: .center)

                Text(":\(String(service.port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                Text(service.processName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Image(systemName: service.url == nil ? "doc.on.doc" : "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func handleClick() {
        if let url = service.url {
            NSWorkspace.shared.open(url)
        } else {
            // Non-HTTP port (e.g., postgres): copy "localhost:<port>" instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("localhost:\(service.port)", forType: .string)
        }
        MenuDismisser.dismiss()
    }
}

struct TabRow: View {
    let tab: TerminalTab
    @State private var hovering = false

    var body: some View {
        Button { TabFocuser.focus(tab) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                    .frame(width: 14, alignment: .center)

                Text(tab.compactLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tab.state == .idle ? .secondary : .primary)

                Spacer()

                Text(tab.tty)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var stateColor: Color {
        switch tab.state {
        case .waiting: return .orange
        case .running: return .green
        case .idle:    return .secondary
        }
    }
}
