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

// Reactive menu bar icon: terminal state plus the always-visible memory
// percentage the user asked for.
//
// Hard constraint, found by building and looking at the bar: MenuBarExtra
// renders only the FIRST TWO children of its label and silently clips the
// rest — a third view makes everything after the second one vanish, with no
// warning and no partial glyph. So the label is exactly one Image plus one
// Text, and the percentage shares that Text instead of getting its own
// memorychip glyph.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        let waiting = state.tabs.filter { $0.state == .waiting }.count
        HStack(spacing: 3) {
            // The single icon slot stays the terminal state, except at
            // critical — the one memory transition worth pre-empting it for,
            // and a silhouette change rather than a fill change so it still
            // reads if the bar flattens the label to monochrome.
            Image(systemName: state.memoryPressure == .critical
                  ? "exclamationmark.octagon.fill"
                  : (waiting > 0 ? "terminal.fill" : "terminal"))

            Text(text(waiting: waiting))
                // Proportional digits resize the status item every time the
                // percentage flips 83/84/85, nudging every item to its left.
                .monospacedDigit()
                .foregroundStyle(state.memoryPressure >= .warning
                                 ? state.memoryPressure.tint : Color.primary)
        }
    }

    private func text(waiting: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting)") }
        if let memory = state.memory { parts.append("\(memory.usedPercent)%") }
        return parts.joined(separator: "  ")
    }
}

// AppState owns long-lived services and publishes UI state.
//
// Scanning runs on two independent *serial* queues, split by cost:
//   fastQueue — ps, lsof (per-tab cwd) and Claude session transcripts, 5s.
//   slowQueue — lsof (listening ports), git worktrees, gh; 20s/60s cadences.
// Serial is the crash fix: every scanner keeps an unsynchronized cache, and
// overlapping passes on a concurrent queue corrupted them (SIGSEGV inside
// ClaudeSessionScanner's dictionary). Two queues rather than one so a 30s
// `gh` call can't hold the tab refresh behind it. Each scanner is owned by
// exactly one queue, so its cache has exactly one accessor at a time.
final class AppState: ObservableObject {
    let power = PowerAssertion()
    private let tabScanner = TabScanner()            // fastQueue only
    private let sessionScanner = ClaudeSessionScanner()  // fastQueue only
    private let idleNotifier = IdleNotifier()        // fastQueue only
    private let serviceScanner = LocalServicesScanner()  // slowQueue only
    private let worktreeScanner = WorktreeScanner()  // slowQueue only
    private let githubScanner = GitHubScanner()      // slowQueue only
    private let githubMonitor = GitHubMonitor()      // main only
    private let memoryScanner = MemoryScanner()      // main only
    private let fastQueue = DispatchQueue(label: "com.ccbar.scan.fast", qos: .utility)
    private let slowQueue = DispatchQueue(label: "com.ccbar.scan.slow", qos: .utility)

    // Main-thread-only state. A tick arriving while its queue is still busy is
    // dropped, never enqueued, so no backlog can form.
    private var refreshTimer: Timer?
    private var fastScanInFlight = false
    private var slowScanInFlight = false
    private var isRunning = false
    private var lastCwds: [String]?     // tab cwds for the slow path; nil until the first fast scan lands
    private var hysteresis = PressureHysteresis()

    // slowQueue-only state. The queue is serial, so these need no further
    // synchronization — but nothing outside the slow scan block may touch them.
    private var lastServicesScan: Date = .distantPast
    private var lastWorktreeScan: Date = .distantPast
    private var lastGitHubScan: Date = .distantPast
    private var lastRepos: [GitRepo] = []   // private mirror of `repos`, so the slow path never reads an @Published property off-main

    @Published var tabs: [TerminalTab] = []
    @Published var services: [LocalService] = []
    @Published var repos: [GitRepo] = []
    @Published var myPRs: [GitHubPR] = []
    @Published var reviewQueue: [ReviewRequest] = []
    @Published var failedRuns: [FailedRun] = []
    @Published var dependabotAlerts: [DependabotAlert] = []
    @Published var githubAuthed: Bool = true
    @Published var memory: MemorySnapshot?
    // Hysteresis-stabilized level. The raw per-sample level flaps between
    // adjacent levels on a loaded machine, so never drive UI color off
    // `memory.pressure` directly — it would recolor every 5s.
    @Published var memoryPressure: MemoryPressureLevel = .normal

    func start() {
        power.acquire()
        idleNotifier.requestAuthorization()
        isRunning = true
        sampleMemory()
        refresh()
        // 5s tick drives the fast scan; the slow one self-rate-limits. A fast
        // pass measures ~530ms today (ps 430ms, parse 27ms, cwd lsof 65ms,
        // sessions 6ms), but `ps` alone has hit ~2.4s on a busy machine, so a
        // tick can outlast its interval — hence the drop-if-busy guards below.
        // The port scan, git and gh sit on slowQueue because listening ports
        // and branch state don't move every 5s.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sampleMemory()
            self?.refresh()
        }
    }

    // Sampled inline on the main thread (the timer already runs there), not on
    // a scan queue: the whole scan measures ~26µs, and routing it through
    // fastQueue would make the always-visible menu bar percentage inherit a
    // ~530ms `ps` pass and its drop-if-busy behaviour.
    private func sampleMemory() {
        let snapshot = memoryScanner.scan()
        // AppState is one ObservableObject, so any @Published write invalidates
        // every observing view — the whole popover, not just the memory row.
        // The percentage genuinely flips every few ticks, so only publish a
        // sample that actually differs.
        if snapshot != memory { memory = snapshot }
        // A failed read — or a snapshot whose pressure sysctl failed while the
        // vm stats succeeded — means we don't know. Feeding .unknown to the
        // hysteresis would let "couldn't read" become the stable level.
        if let snapshot, snapshot.pressure != .unknown {
            memoryPressure = hysteresis.update(snapshot.pressure)
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // In-flight scans still run to completion; this makes them discard
        // their results instead of resurrecting UI state after shutdown.
        isRunning = false
        power.release()
    }

    // The in-flight flags and lastCwds are main-thread-only, so every entry
    // point hops to main before touching them — one owner thread, no lock.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
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

    // Both cadences. Timer-driven; each path decides for itself whether it's
    // due and whether it's already busy.
    func refresh() {
        refreshFast()
        refreshSlow()
    }

    // Fast path: ps + Claude session transcripts → `tabs`. Safe to call on
    // demand (popover open). Not subprocess-free: TabScanner shells out to
    // `ps` and, for per-tab cwds, to `lsof` (~65ms today, 12x/min). That lsof
    // is the one call on this path with unbounded tail latency — a hung
    // network mount stalls it — but moving it belongs with TabScanner.
    func refreshFast() {
        onMain { [weak self] in
            guard let self, !self.fastScanInFlight else { return }   // drop, never queue
            self.fastScanInFlight = true
            self.fastQueue.async { [weak self] in
                guard let self else { return }
                let rawTabs = self.tabScanner.scan()
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
                    let session = pidToSession[tab.foregroundPid]
                    // Re-measure with phys_footprint. TabScanner's value comes
                    // from `ps rss`, which omits compressed pages and so ranks
                    // heavy sessions backwards on a machine under pressure.
                    // Idle tabs are just the shell, so don't pay the syscall.
                    let footprint = tab.isIdle ? nil : MemoryScanner.footprint(tab.foregroundPid)
                    guard session != nil || footprint != nil else { return tab }
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
                        // Fall back to ps's figure if the pid died mid-scan.
                        residentBytes: footprint ?? tab.residentBytes,
                        claudeSession: session
                    )
                }

                // Notifier fires across all sessions, even ones whose tab is closed.
                self.idleNotifier.evaluate(sessions: sessions)

                DispatchQueue.main.async {
                    self.fastScanInFlight = false
                    guard self.isRunning else { return }
                    self.tabs = enrichedTabs
                    // Snapshot for the slow path, which must not read `tabs`.
                    self.lastCwds = enrichedTabs.compactMap { $0.cwd }
                }
            }
        }
    }

    // Slow path: lsof + git + gh, each on its own cadence. The block no-ops
    // cheaply when nothing is due, so the 5s tick can drive it unconditionally.
    private func refreshSlow() {
        onMain { [weak self] in
            guard let self, !self.slowScanInFlight else { return }   // drop, never queue
            self.slowScanInFlight = true
            // Read the cwd snapshot here, on main, and pass it in by value:
            // `tabs` is @Published and must never be touched off-main.
            let cwds = self.lastCwds
            self.slowQueue.async { [weak self] in
                guard let self else { return }
                let now = Date()
                // One budget for the whole pass. Every Subprocess.run is
                // individually bounded, but the timeouts compound along a
                // serial chain — at current fan-out an all-timeout pass runs
                // for minutes, and for that whole window slowScanInFlight
                // stays true and every 5s tick is silently dropped. Checking
                // between phases caps the overrun at roughly one phase and
                // publishes what we did gather; a skipped phase doesn't stamp
                // its timestamp, so it simply retries on the next tick.
                let deadline = now.addingTimeInterval(15)

                // Listening ports change on the order of minutes, and lsof is
                // the most expensive scan we run — ~20s cadence, not 5s.
                let services: [LocalService]?
                if now.timeIntervalSince(self.lastServicesScan) >= 20, Date() < deadline {
                    services = self.serviceScanner.scan()
                    self.lastServicesScan = now
                } else {
                    services = nil
                }

                // Worktrees (multiple git calls each) ~20s, GitHub 60s. Both
                // are skipped until the first fast scan has published a cwd
                // snapshot — with no cwds there is nothing to discover, and
                // stamping the timestamps on an empty pass would blank the
                // worktree list for a full cycle.
                var repos: [GitRepo]?
                var github: GitHubSnapshot?
                if let cwds {
                    if now.timeIntervalSince(self.lastWorktreeScan) >= 20, Date() < deadline {
                        let scanned = self.worktreeScanner.scan(cwds: cwds)
                        repos = scanned
                        self.lastRepos = scanned
                        self.lastWorktreeScan = now
                    }

                    // GitHub scan: one GraphQL + per-repo REST. We scope
                    // per-repo calls (Actions runs, Dependabot) to repos
                    // currently checked out — discovered via worktree origins,
                    // read from our private mirror rather than @Published repos.
                    if now.timeIntervalSince(self.lastGitHubScan) >= 60, Date() < deadline {
                        let originRepos = Array(Set(self.lastRepos.flatMap(\.worktrees).compactMap(\.originRepo))).sorted()
                        github = self.githubScanner.scan(repos: originRepos)
                        self.lastGitHubScan = now
                    }
                }

                DispatchQueue.main.async {
                    self.slowScanInFlight = false
                    guard self.isRunning else { return }
                    if let services { self.services = services }
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `make test` builds with -D DEBUG and runs the binary with
        // CCBAR_SELFTEST=1: check the pure memory math and exit with a status,
        // rather than bringing up a menu bar nothing can assert against.
        if ProcessInfo.processInfo.environment["CCBAR_SELFTEST"] != nil {
            let failures = MemoryScanner.selfTest()
            for failure in failures { print("selfTest: \(failure)") }
            print(failures.isEmpty
                  ? "MemoryScanner.selfTest: PASS"
                  : "MemoryScanner.selfTest: \(failures.count) failure(s)")
            exit(failures.isEmpty ? 0 : 1)
        }
        #endif

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

            // System-status footer, below the per-folder content it doesn't
            // belong to. Omitted entirely when the scan failed — a "0%"
            // placeholder would read as real data.
            if let memory = state.memory {
                Divider()
                MemoryRow(memory: memory,
                          pressure: state.memoryPressure,
                          claudeTabs: state.tabs.filter { $0.foregroundName == "claude" })
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
        .onAppear { state.refreshFast() }
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

// Base-2 units, matching Activity Monitor, and deliberately coarse — 0.1 GB
// or 10 MB. These are resampled every 5s and a working claude moves tens of MB
// per tick, so a precise figure twitches on every refresh and reads worse than
// a stable one. Hand-rolled rather than ByteCountFormatter, which is fixed at
// three significant figures ("1.12 GB") and can't be asked for this.
private func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 {
        let rounded = (gb * 10).rounded() / 10
        // Whole numbers read as "16 GB", not "16.0 GB".
        return rounded == rounded.rounded()
            ? String(format: "%.0f GB", rounded)
            : String(format: "%.1f GB", rounded)
    }
    let mb = Double(bytes) / 1_048_576
    return "\(max(10, Int((mb / 10).rounded()) * 10)) MB"
}

private extension MemoryPressureLevel {
    // Anything below warning is drawn as ordinary secondary text. Note this
    // deliberately keeps .unknown quiet: "we couldn't read the level" must not
    // render louder than "everything is fine".
    var tint: Color {
        switch self {
        case .warning:  return .orange
        case .critical: return .red
        default:        return .secondary
        }
    }

    // nil at normal (and unknown): a permanently-lit status word is ignored
    // exactly the way a permanently-lit warning glyph would be.
    var label: String? {
        switch self {
        case .warning:  return "warning"
        case .critical: return "critical"
        default:        return nil
        }
    }
}

// Memory footer. Severity comes from the kernel's pressure level, not the
// percentage: macOS deliberately keeps RAM ~85% full even when healthy, so a
// threshold on the percentage would be lit permanently and say nothing.
//
// Clickable, like every other row here — it is the moment the user most wants
// somewhere to go, so it opens Activity Monitor.
struct MemoryRow: View {
    let memory: MemorySnapshot
    let pressure: MemoryPressureLevel
    let claudeTabs: [TerminalTab]
    @State private var hovering = false

    // Every Mac keeps a swap file and macOS never shrinks it, so this figure
    // is a high-water mark rather than a live signal — surfaced only when it
    // is large, and left at .tertiary weight. Also covers a machine with swap
    // disabled, where used is 0.
    private static let swapFloor: UInt64 = 1 << 30   // 1 GB

    var body: some View {
        Button(action: openActivityMonitor) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(pressure.tint)
                        .frame(width: 14, alignment: .center)

                    Text("\(formatBytes(memory.usedBytes)) / \(formatBytes(memory.totalBytes)) · \(memory.usedPercent)%")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let word = pressure.label {
                        Text(word)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(pressure.tint)
                    }

                    Spacer()

                    if memory.swapUsedBytes >= Self.swapFloor {
                        Text("swap \(formatBytes(memory.swapUsedBytes))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 6) {
                    Spacer().frame(width: 14)
                    // Compressed is the figure that actually moves: a fraction
                    // of a GB on a healthy machine against several GB here,
                    // and it falls within seconds of quitting something. The
                    // percentage is pinned near its ceiling and cannot show
                    // that the machine got better.
                    Text("\(formatBytes(memory.compressedBytes)) compressed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Ten per-row figures scattered across folder groups can't
                    // answer "are my Claude sessions the problem?"; one sum
                    // can. Summing footprints counts shared pages more than
                    // once, so it's a slight over-estimate.
                    if claudeBytes > 0 {
                        Text("· claude ×\(claudeTabs.count) · \(formatBytes(claudeBytes))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
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

    private var claudeBytes: UInt64 {
        claudeTabs.compactMap(\.residentBytes).reduce(0, +)
    }

    private func openActivityMonitor() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        )
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
                    // The memory column costs the title some width, and the
                    // tail of a session title is the distinguishing part.
                    .truncationMode(.middle)
                    .foregroundStyle(tab.state == .idle ? .secondary : .primary)

                Spacer()

                // Which session is eating the RAM. Gated on having a real
                // foreground process rather than on a byte threshold: real
                // values cluster tightly, so any threshold makes rows pop in
                // and out and re-truncate the title on every refresh.
                // .secondary, not .tertiary — at .tertiary it is
                // indistinguishable from the tty beside it. Fixed width so the
                // figures line up and the tty never shifts.
                if !tab.isIdle, let bytes = tab.residentBytes {
                    Text(formatBytes(bytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }

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
