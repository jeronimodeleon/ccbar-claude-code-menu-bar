import Foundation

struct Worktree: Identifiable, Hashable {
    let id: String                   // absolute path (unique)
    let path: String
    let branch: String?              // "main", "feature/x", or nil if detached
    let isMain: Bool                 // primary worktree of the repo
    let dirtyCount: Int              // # of files reported by `status --porcelain`
    let ahead: Int                   // commits in HEAD not in @{u}
    let behind: Int                  // commits in @{u} not in HEAD
    let hasUpstream: Bool            // false → "—" for ahead/behind
    let originRepo: String?          // "owner/repo" parsed from origin remote

    var folderName: String { (path as NSString).lastPathComponent }
}

struct GitRepo: Identifiable, Hashable {
    let id: String                   // common-dir path (one per repo)
    let name: String                 // basename of main worktree
    let worktrees: [Worktree]
}

final class WorktreeScanner {
    // origin URL per worktree path. Unsynchronized on purpose: scan() is only
    // ever called from slowQueue, so this class is single-threaded by
    // confinement. If that ever stops holding this needs a lock — an
    // unsynchronized dictionary under concurrent access is what crashed the app.
    private var originCache: [String: String?] = [:]

    // Discovers repos from the union of cwds passed in (typically open
    // terminal tabs), then enumerates each repo's worktrees and their state.
    func scan(cwds: [String]) -> [GitRepo] {
        let uniqueCwds = Set(cwds)
        var repoCommonDirs: Set<String> = []

        // Step 1: map each cwd to its repo's common-dir, dedupe.
        for cwd in uniqueCwds {
            guard let raw = git("rev-parse", "--git-common-dir", cwd: cwd) else { continue }
            let commonDir = raw.hasPrefix("/")
                ? raw
                : ((cwd as NSString).appendingPathComponent(raw) as NSString).standardizingPath
            repoCommonDirs.insert(commonDir)
        }

        // Step 2: per repo, list and enrich worktrees.
        var repos: [GitRepo] = []
        for commonDir in repoCommonDirs {
            guard let listing = git("--git-dir", commonDir, "worktree", "list", "--porcelain")
            else { continue }
            let parsed = parseWorktreeList(listing)
            guard !parsed.isEmpty else { continue }

            let worktrees = parsed.map(enrich(_:))
            let mainWt = worktrees.first(where: { $0.isMain }) ?? worktrees[0]
            let repoName = (mainWt.path as NSString).lastPathComponent

            repos.append(GitRepo(id: commonDir, name: repoName, worktrees: worktrees))
        }
        // Drop cached origins for worktrees that have gone away, so the cache
        // tracks the live set instead of growing for the life of the process.
        let live = Set(repos.flatMap { $0.worktrees.map(\.path) })
        originCache = originCache.filter { live.contains($0.key) }

        return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // The first worktree in `git worktree list --porcelain` is the main one.
    private struct RawWorktree {
        let path: String
        let branch: String?
        let isMain: Bool
    }

    private func parseWorktreeList(_ output: String) -> [RawWorktree] {
        var result: [RawWorktree] = []
        let blocks = output.components(separatedBy: "\n\n")
        for (idx, block) in blocks.enumerated() where !block.isEmpty {
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
                }
                // "detached" line implies no branch — branch stays nil.
            }
            if let p = path {
                result.append(RawWorktree(path: p, branch: branch, isMain: idx == 0))
            }
        }
        return result
    }

    private func enrich(_ raw: RawWorktree) -> Worktree {
        // Dirty count: number of porcelain status lines.
        let dirtyCount = git("status", "--porcelain", cwd: raw.path)?
            .split(separator: "\n").count ?? 0

        // Ahead/behind vs upstream — fails (returns nil) if no upstream set.
        var ahead = 0, behind = 0, hasUpstream = false
        if let counts = git("rev-list", "--left-right", "--count", "@{u}...HEAD", cwd: raw.path) {
            let parts = counts.split(whereSeparator: \.isWhitespace)
            if parts.count == 2,
               let b = Int(parts[0]),
               let a = Int(parts[1]) {
                behind = b
                ahead = a
                hasUpstream = true
            }
        }

        // Parse `origin` remote URL → "owner/repo". Cached: this is ~18 extra
        // subprocess spawns a minute for a value that effectively never changes.
        let originRepo: String?
        if let cached = originCache[raw.path] {
            originRepo = cached
        } else {
            originRepo = git("remote", "get-url", "origin", cwd: raw.path)
                .flatMap(Self.parseOriginRepo)
            originCache[raw.path] = originRepo
        }

        return Worktree(
            id: raw.path,
            path: raw.path,
            branch: raw.branch,
            isMain: raw.isMain,
            dirtyCount: dirtyCount,
            ahead: ahead,
            behind: behind,
            hasUpstream: hasUpstream,
            originRepo: originRepo
        )
    }

    // Handles all common origin shapes:
    //   https://github.com/owner/repo[.git]
    //   git@github.com:owner/repo[.git]
    //   ssh://git@github.com/owner/repo[.git]
    static func parseOriginRepo(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard let range = s.range(of: "github\\.com[:/]", options: .regularExpression)
        else { return nil }
        let after = s[range.upperBound...]
        let parts = after.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts.last!)"
    }

    // A non-zero exit is how we detect "no upstream", "not a repo", etc., so
    // these all require a clean exit before the output is trusted.
    private func git(_ args: String..., cwd: String? = nil) -> String? {
        // --no-optional-locks keeps `status` from refreshing and rewriting
        // .git/index, which would take index.lock and can collide with the
        // user's own git while we poll every worktree every 20s.
        Subprocess.run("/usr/bin/git",
                       (cwd.map { ["-C", $0] } ?? []) + ["--no-optional-locks"] + args,
                       environment: Self.gitEnvironment,
                       requireZeroExit: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A repo with an http remote and no cached credentials makes git prompt.
    // Subprocess already points stdin at /dev/null, so a prompt could only
    // stall until the watchdog fired; this makes git fail immediately instead.
    private static let gitEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }()
}
