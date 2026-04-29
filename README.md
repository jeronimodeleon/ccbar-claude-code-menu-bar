# CCBar - Claude Code Menu Bar App

A macOS menu bar app for monitoring everything you have running across terminal
tabs, Claude Code sessions, local dev servers, git worktrees, and your GitHub
PRs — grouped by the project folder you're working in.

Designed for the kind of day where you have a dozen Claude Code sessions in
flight across several repos and want one place to see which ones need your
input, what services are running, and whether your PRs are green.

## Features

- **Terminal tabs** — every open tab across Terminal.app / iTerm2 / Ghostty /
  Warp / Alacritty / kitty / WezTerm, with the foreground process and a state
  dot (🟠 waiting · 🟢 running · ⚪ idle).
- **Claude Code sessions** — the row title shows the session's `aiTitle` /
  most recent prompt, sourced from `~/.claude/projects/<dir>/<session>.jsonl`.
  Each running `claude` process is paired to its own session via process start
  time + `.jsonl` birth time.
- **Idle-session notifications** — fires a macOS notification when a Claude
  session has been waiting on input for >10 minutes.
- **Local services** — every TCP port your user is listening on, with
  click-to-open in the browser for HTTP-ish ports and copy-to-clipboard for
  databases and other non-HTTP services.
- **Git worktrees** — auto-discovered from open tabs. Shows dirty file count,
  commits ahead / behind upstream, no-upstream warnings.
- **GitHub** (via the `gh` CLI):
  - PRs requesting your review
  - Your open PRs with CI / approval / mergeable / draft state
  - Failed Action runs (latest run per workflow/branch only — historical
    failures that have since been re-run successfully don't show)
  - Open Dependabot alerts (severity-sorted)
  - Notifications on new CI failures, ready-to-merge transitions, and new
    failed Action runs.
- **Folder-first grouping** — everything (tabs, services, worktrees, PRs,
  failed runs, alerts) lives under the project folder it relates to.
  Folders with attention-needing tabs sort to the top. Orphan
  services/worktrees collapse into a single "Other" group at the bottom.
- **Click-to-focus** — clicking a tab row brings that terminal tab to the
  front (Terminal.app / iTerm2 by exact tab; others by app activation).
  Clicking a service opens it; clicking a worktree opens Finder; clicking a
  PR opens GitHub.

## Requirements

- macOS Sonoma 14.6 or later
- Apple Command Line Tools (provides `swiftc`)
- `gh` CLI authenticated (`gh auth login`) — only required for the GitHub
  features; everything else works without it.

## Build & install

```sh
cd ~/Documents/team/CCBar
make install          # builds + copies CCBar.app to ~/Applications
open ~/Applications/CCBar.app
```

Then click the menu bar icon → check **Launch at login** at the bottom of the
popover. CCBar will now start on every boot.

Available `make` targets:

| Target          | What it does                                        |
| --------------- | --------------------------------------------------- |
| `make build`    | Compile binary into `build/CCBar`                   |
| `make app`      | Bundle into `build/CCBar.app`                       |
| `make run`      | Build app + run it from `build/` (Ctrl-C to quit)   |
| `make install`  | Copy bundle to `~/Applications/CCBar.app`           |
| `make clean`    | Delete `build/`                                     |

### Important note about launch-at-login

`SMAppService` registers the exact path of the app at the moment you toggle
the checkbox. Always toggle launch-at-login from the **installed**
`~/Applications/CCBar.app`, never from the dev `build/CCBar.app` (which gets
overwritten by `make app`). If you rebuild and reinstall, toggle the checkbox
off and back on once to refresh the registration.

## First-launch permissions

You'll see two macOS prompts the first time:

1. **Notifications** — needed for idle-session and CI-failure alerts. Allow.
2. **Automation: Terminal / iTerm** — first time you click a tab row, macOS
   asks if CCBar can control Terminal.app (or iTerm2) to focus a specific
   tab. Allow. Without this, CCBar can still bring the app to the front but
   won't switch to the right tab.

If you skipped the prompts, fix them in System Settings → Privacy & Security
→ Notifications / Automation.

## What you'll see

A typical popover when you have several Claude sessions running:

```
CCBar                                                    13 tabs

sampleapps (5)
  🟠 Build OCR document chat app — claude              ttys007
  🟠 Build sample app with GenBlaze SDK — claude       ttys008
  🟢 /loop continue gmi rerun — claude                  ttys012
  🌐 :3000  vite                                        ↗
  ⎇ main          ●3 ↑1
  👁 #4   chore(deps): bump the actions group...       4d
  ⤴ ✓ ✅ #200    Fix sync regression
  ❌ CI on main                                          2h
  🛡 HIGH    lodash    Prototype pollution

genblaze (2)
  🟠 Plan fixes for genblaze DX feedback — claude      ttys001
  ⎇ main          ●12  ↑3 ↓1

CCBar (1)
  🟠 make                                                ttys010

▶ Other (3)            ← collapsed, click to expand

☐ Launch at login                                       Quit
```

Menu bar icon: outline `terminal` when nothing needs attention; filled
`terminal.fill` plus a count when ≥1 tab is waiting for input.

## How it works

CCBar is a SwiftUI `MenuBarExtra` accessory app (no Dock icon, no menu bar
top menu). All polling happens off the main thread; the UI re-renders when
published state updates.

Refresh cadences:

- **5s**: terminal tabs (`ps`), local services (`lsof`), Claude sessions
  (file watcher on `~/.claude/projects/`)
- **20s**: git worktrees (`git worktree list`, `status --porcelain`,
  `rev-list`)
- **60s**: GitHub data (single GraphQL query for PRs/reviews + per-repo REST
  for Actions runs and Dependabot alerts)
- **on popover open**: an immediate refresh fires so closed tabs disappear
  promptly when you click the icon

The codebase is small and grouped by responsibility:

| File                          | What it does                                          |
| ----------------------------- | ----------------------------------------------------- |
| `CCBarApp.swift`              | App entry, `AppState`, `MenuView`, all row components |
| `PowerAssertion.swift`        | Wraps `IOPMAssertionCreateWithName` for keep-awake    |
| `TabScanner.swift`            | `ps` + `lsof` → terminal tabs with cwd + foreground   |
| `LocalServicesScanner.swift`  | `lsof` listening sockets + cwds                       |
| `ClaudeSessionScanner.swift`  | Parses `.jsonl` head/tail for cwd + title + state     |
| `WorktreeScanner.swift`       | `git worktree list` + dirty / ahead / behind          |
| `GitHubScanner.swift`         | `gh api graphql` + REST for Actions and Dependabot    |
| `GitHubMonitor.swift`         | Notifications on CI fail / ready-to-merge transitions |
| `IdleNotifier.swift`          | Notifications for Claude sessions idle >10m           |
| `TabFocuser.swift`            | AppleScript to focus a specific Terminal/iTerm tab    |
| `MenuDismisser.swift`         | Close the popover after a row click                   |

### Tab → session pairing

Multiple `claude` processes can run in the same project folder. Each writes
to its own `<sessionId>.jsonl` but doesn't keep the file open continuously
(so `lsof` can't catch it) and doesn't expose the session id in args/env.
We pair each tab to a session by:

1. For each `claude` process in cwd `X`, get its start time from `ps etime=`
2. For each `.jsonl` in `~/.claude/projects/<encoded-X>/`, get its birth time
3. Sort tabs ascending by start time, sessions ascending by birth time
4. Greedy 1:1: each tab pairs to the earliest unclaimed session whose birth
   time is ≥ the tab's start time (5-minute slack accommodates Claude's
   first-write delay)

This holds up well in practice — Claude creates the session file a few
seconds after the process starts, so the orderings line up.

## Tradeoffs and known limits

- **Lid-close sleep** still happens regardless of CCBar — that's enforced
  below user-space and we can't override it without entitlements. The
  keep-awake assertion only blocks idle-sleep (display + system).
- **Process start time vs. session birth time pairing** is a heuristic. It
  holds for >99% of normal use; if you `--resume` a stale session, the
  pairing may be off (the new process gets paired to a fresh-but-empty
  session file instead of the resumed one).
- **No auto-fetch** for git ahead/behind. The counts reflect what's in your
  local refs; run `git fetch` yourself for fresh remote info.
- **`mergeStateStatus`** is not in `gh search prs`, so we use `mergeable`
  (CONFLICTING / MERGEABLE / UNKNOWN). "Behind required base" type blocks
  aren't detected.
- **iTerm2 / Terminal AppleScript permission** is opt-in. If you decline,
  click-to-focus falls back to bringing the app forward without selecting
  the specific tab.

## Troubleshooting

**"GitHub: not authenticated" banner.** Run `gh auth login` in any terminal.
GitHub data updates within 60s of authenticating.

**Menu bar icon never updates.** The reactive icon needs the AppState to be
publishing; if you see a static `terminal` icon and the popover shows tabs
but no count, file an issue. (Workaround: quit and relaunch.)

**Tab title shows "ttysNNN — claude" instead of the session title.** Either
no `.jsonl` was found in the matching project dir (e.g., the cwd's first
write hasn't happened yet) or all session files in that dir have birth
times older than the process's start time. Usually self-resolves once the
session writes once.

**App crashes on launch on Sonoma 14.6+.** Almost always a missing ad-hoc
code signature or LaunchServices registration — symptoms include the app
showing in Activity Monitor for ~1 second then disappearing, with a crash
log mentioning `+[UNUserNotificationCenter currentNotificationCenter]_block_invoke`
and `bundleProxyForCurrentProcess`. Fix by rebuilding cleanly with the
current Makefile, which adds `codesign --sign -` (ad-hoc signature) and
`lsregister -f` (LaunchServices registration):

```sh
make clean
rm -rf ~/Applications/CCBar.app
make install
open ~/Applications/CCBar.app
```

If you previously installed an unsigned version, also clear quarantine on
the new copy: `xattr -cr ~/Applications/CCBar.app`.

**Keep-awake doesn't work.** Verify the assertion is held:

```sh
pmset -g assertions | grep CCBar
```

You should see a `PreventUserIdleDisplaySleep` line. Closing the laptop lid
still sleeps the Mac regardless — that's enforced at a layer below
user-space and no app can override it without special entitlements.
