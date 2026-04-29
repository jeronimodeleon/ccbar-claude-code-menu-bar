import Foundation
import IOKit.pwr_mgt

// Holds an IOKit power assertion that keeps the Mac awake while the app runs.
//
// We use PreventUserIdleDisplaySleep (same as `caffeinate -d`, Amphetamine,
// KeepingYouAwake) rather than PreventUserIdleSystemSleep. The system-sleep
// variant has a known macOS quirk where the system can still sleep once the
// display sleeps, defeating the whole purpose. Keeping the display awake
// transitively keeps the system awake, which is what people actually want.
//
// Caveat: closing the laptop lid still forces clamshell sleep regardless of
// any assertion (unless on AC power with an external display attached).
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var isActive: Bool = false

    func acquire(reason: String = "CCBar is monitoring sessions") {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isActive = (result == kIOReturnSuccess)
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    deinit { release() }
}
