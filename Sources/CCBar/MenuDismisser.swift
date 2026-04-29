import AppKit

// Closes the SwiftUI MenuBarExtra popover. SwiftUI doesn't expose a public
// dismiss API for MenuBarExtra(.window), so we close the panel directly —
// CCBar is an accessory app whose only visible window is the popover.
enum MenuDismisser {
    static func dismiss() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.orderOut(nil)
            }
        }
    }
}
