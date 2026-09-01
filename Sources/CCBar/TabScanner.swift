import Foundation
import AppKit

enum TabState: Int, Comparable {
    case waiting = 0   // foreground process exists but is quiet → likely awaiting input
    case running = 1   // foreground process exists with active CPU
    case idle    = 2   // shell is the foreground (no command running)

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// One row in the menu = one terminal tab/window.
struct TerminalTab: Identifiable, Hashable {
    let id: String
    let terminalApp: String        // "Ghostty", "iTerm2", etc. or "Terminal" if unknown
    let tty: String                // e.g. "ttys003"
    let shellPid: Int32
    let shellName: String          // "zsh", "bash", "fish"
    let foregroundPid: Int32
    let foregroundName: String     // executable basename ("claude", "vim", "node")
    let foregroundArgs: String     // full command line
    let foregroundCpu: Double      // %cpu of foreground process (0–100)
    let cwd: String?               // foreground (or shell, if idle) cwd
    let processStartedAt: Date     // start time of the foreground process
    let residentBytes: UInt64?     // RSS of the foreground process, nil if unknown
    let claudeSession: ClaudeSession?  // matched session for `claude` tabs
    var isIdle: Bool { foregroundPid == shellPid }

    var state: TabState {
        if isIdle { return .idle }
        // For claude tabs we have ground truth from the JSONL transcript.
        if let s = claudeSession {
            if s.isAwaitingInput { return .waiting }
            if s.isWorking { return .running }
        }
        // Fallback: instantaneous CPU heuristic for non-claude (or unmatched) tabs.
        return foregroundCpu >= 0.5 ? .running : .waiting
    }

    // Build a rich title in the same shape Terminal.app shows in its Window
    // menu: "<cwd> — <session title or activity> — <process>". We reconstruct
    // it from data we already collect because querying Terminal's per-tab
    // `name` property via AppleScript fails with a coercion error on current
    // macOS, and that approach didn't work for Ghostty/Warp/etc. anyway.
    var primaryLabel: String {
        let dir = cwdDisplay ?? tty
        var parts: [String] = [dir]
        if let title = claudeSession?.displayTitle {
            parts.append(title)
        }
        parts.append(isIdle ? "-\(shellName)" : foregroundName)
        return parts.joined(separator: " — ")
    }

    // Same content as primaryLabel but without the leading cwd basename — used
    // when the row sits inside a folder section that already shows the dir.
    var compactLabel: String {
        var parts: [String] = []
        if let title = claudeSession?.displayTitle {
            parts.append(title)
        }
        parts.append(isIdle ? "-\(shellName)" : foregroundName)
        return parts.joined(separator: " — ")
    }

    // Folder this tab is currently in — basename of cwd, "~" for home,
    // "(unknown)" if cwd is unavailable.
    var folderName: String {
        guard let c = cwd else { return "(unknown)" }
        if c == NSHomeDirectory() { return "~" }
        return (c as NSString).lastPathComponent
    }

    // Compact cwd for display: home → "~", subpath of home → basename, else basename.
    private var cwdDisplay: String? {
        guard let c = cwd else { return nil }
        let home = NSHomeDirectory()
        if c == home { return "~" }
        return (c as NSString).lastPathComponent
    }
}

private struct PSRow {
    let pid: Int32
    let ppid: Int32
    let pgid: Int32
    let tpgid: Int32
    let tty: String
    let stat: String
    let cpu: Double
    let etimeSeconds: Double       // elapsed time since process start
    let residentBytes: UInt64?     // resident set size, nil if ps didn't report one
    let args: String

    var executable: String {
        let first = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var base = (first as NSString).lastPathComponent
        if base.hasPrefix("-") { base.removeFirst() }
        return base
    }

    // Parses ps's `etime` formatted as `[[DD-]HH:]MM:SS` into seconds.
    static func parseEtime(_ s: Substring) -> Double {
        var rest = Substring(s)
        var days = 0.0
        if let dashIdx = rest.firstIndex(of: "-") {
            days = Double(rest[..<dashIdx]) ?? 0
            rest = rest[rest.index(after: dashIdx)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        let secs: Double
        switch parts.count {
        case 3: secs = parts[0]*3600 + parts[1]*60 + parts[2]
        case 2: secs = parts[0]*60 + parts[1]
        case 1: secs = parts[0]
        default: return 0
        }
        return days*86400 + secs
    }
}

final class TabScanner {
    // Bundle IDs we recognize as terminal apps. Walking up from a shell, the
    // first ancestor matching one of these gives the tab's "terminalApp" label.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby"
    ]

    func scan() -> [TerminalTab] {
        let rows = runPS()
        let terminals = currentTerminalApps()
        let bare = tabsFromRows(rows, terminals: terminals)

        // Enrich each tab with the cwd of its foreground (or shell, if idle) PID.
        let pidsForCwd = bare.map { $0.isIdle ? $0.shellPid : $0.foregroundPid }
        let cwds = fetchCwds(for: pidsForCwd)

        return bare.map { tab in
            let pid = tab.isIdle ? tab.shellPid : tab.foregroundPid
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
                cwd: cwds[pid],
                processStartedAt: tab.processStartedAt,
                residentBytes: tab.residentBytes,
                claudeSession: nil
            )
        }
    }

    // Batch lsof of working dirs. One process call for all PIDs.
    private func fetchCwds(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        // -b -w           → avoid kernel calls that can block on a hung mount
        //                   (an lsof stuck in D state ignores SIGKILL), and
        //                   silence the warnings that avoidance produces
        // -a              → AND the filters (without it lsof OR's, so -d cwd
        //                   would let through every other FD of the listed
        //                   PIDs and the last "n" line wins — which is how we
        //                   ended up with garbage like "[ctl com.apple.netsrc…]"
        //                   instead of paths.
        // -p PID,PID,…    → restrict to these processes
        // -d cwd          → restrict to the cwd pseudo-FD
        // -Fpn            → field output: just PID and name
        guard let out = Subprocess.run("/usr/sbin/lsof",
                                       ["-b", "-w", "-a",
                                        "-p", pids.map(String.init).joined(separator: ","),
                                        "-d", "cwd",
                                        "-Fpn"])
        else { return [:] }

        var result: [Int32: String] = [:]
        var currentPid: Int32?
        for line in out.split(separator: "\n") {
            if line.first == "p" {
                currentPid = Int32(line.dropFirst())
            } else if line.first == "n", let pid = currentPid {
                let path = String(line.dropFirst())
                // Belt-and-suspenders: only accept absolute paths.
                if path.hasPrefix("/") { result[pid] = path }
            }
        }
        return result
    }

    private func currentTerminalApps() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  Self.terminalBundleIDs.contains(bid) else { continue }
            result[app.processIdentifier] = app.localizedName ?? bid
        }
        return result
    }

    private func runPS() -> [PSRow] {
        // `=` after each spec suppresses headers — we get pure data rows.
        // `rss` sits second-to-last: `args` must stay last because it is the
        // only field that can contain spaces, and the parser split-limits on it.
        guard let output = Subprocess.run(
            "/bin/ps",
            ["-axwwo", "pid=,ppid=,pgid=,tpgid=,tty=,stat=,pcpu=,etime=,rss=,args="]
        ) else { return [] }
        return parsePS(output)
    }

    private func parsePS(_ output: String) -> [PSRow] {
        var rows: [PSRow] = []
        for raw in output.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            // First 9 fields are space-delimited; the 10th (args) absorbs the rest.
            let parts = line.split(maxSplits: 9, omittingEmptySubsequences: true,
                                   whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 10,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let pgid = Int32(parts[2]),
                  let tpgid = Int32(parts[3])
            else { continue }
            rows.append(PSRow(
                pid: pid, ppid: ppid, pgid: pgid, tpgid: tpgid,
                tty: String(parts[4]),
                stat: String(parts[5]),
                cpu: Double(parts[6]) ?? 0,
                etimeSeconds: PSRow.parseEtime(parts[7]),
                residentBytes: UInt64(parts[8]).map { $0 * 1024 },   // ps reports KB
                args: String(parts[9])
            ))
        }
        return rows
    }

    private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "tcsh", "ksh", "dash"
    ]

    private func tabsFromRows(_ rows: [PSRow], terminals: [Int32: String]) -> [TerminalTab] {
        let byPid: [Int32: PSRow] = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Group by TTY, ignoring processes with no controlling terminal ("??").
        let ttyGroups: [String: [PSRow]] = Dictionary(grouping: rows.filter {
            $0.tty != "??" && !$0.tty.isEmpty
        }, by: \.tty)

        var tabs: [TerminalTab] = []
        for (tty, group) in ttyGroups {
            // Shell = row in this TTY whose executable is a known shell name.
            // Avoids mis-tagging `login` (also bound to the TTY) as the shell.
            guard let shell = group.first(where: { Self.shellNames.contains($0.executable) }) else { continue }

            // Foreground process = the shell's direct child that is in the
            // foreground process group (pgid == tpgid). This is the command
            // the user typed at the prompt. If none, the shell itself is fg
            // and the tab is idle.
            let fgChild = group.first { row in
                row.ppid == shell.pid && row.tpgid > 0 && row.pgid == row.tpgid
            }
            let foreground = fgChild ?? shell

            // Walk up from the shell looking for a recognized terminal app.
            var ancestor = shell.ppid
            var terminalAppName = "Terminal"
            for _ in 0..<12 {
                if let name = terminals[ancestor] { terminalAppName = name; break }
                guard let parent = byPid[ancestor], parent.ppid > 1 else { break }
                ancestor = parent.ppid
            }

            tabs.append(TerminalTab(
                id: "\(terminalAppName)-\(tty)-\(shell.pid)",
                terminalApp: terminalAppName,
                tty: tty,
                shellPid: shell.pid,
                shellName: shell.executable,
                foregroundPid: foreground.pid,
                foregroundName: foreground.executable,
                foregroundArgs: foreground.args,
                foregroundCpu: foreground.cpu,
                cwd: nil,
                processStartedAt: Date().addingTimeInterval(-foreground.etimeSeconds),
                residentBytes: foreground.residentBytes,
                claudeSession: nil
            ))
        }

        return tabs.sorted {
            $0.terminalApp == $1.terminalApp ? $0.tty < $1.tty
                                              : $0.terminalApp < $1.terminalApp
        }
    }
}
