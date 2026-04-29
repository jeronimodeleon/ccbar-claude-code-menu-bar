import Foundation
import AppKit

// Brings a terminal tab/window to the front. For scriptable terminals
// (Terminal.app, iTerm2) we focus the *specific* tab by matching its TTY.
// For others we just activate the app — best we can do without a tab-level API.
enum TabFocuser {
    static func focus(_ tab: TerminalTab) {
        activateApp(named: tab.terminalApp)
        MenuDismisser.dismiss()

        guard let script = appleScript(for: tab) else { return }
        // AppleScript runs off the main thread; first invocation triggers
        // macOS's Automation permission prompt for the target app.
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
    }

    private static func activateApp(named name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name
        }) else { return }
        app.activate(options: [])
    }

    private static func appleScript(for tab: TerminalTab) -> String? {
        let ttyPath = "/dev/\(tab.tty)"
        switch tab.terminalApp {
        case "Terminal":
            return """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            set selected of t to true
                            set frontmost of w to true
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "iTerm2", "iTerm":
            return """
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(ttyPath)" then
                                select s
                                select t
                                select w
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
