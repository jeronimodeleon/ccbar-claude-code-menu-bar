import Foundation

// Runs the pure-logic self-checks that ship behind #if DEBUG. Deliberately
// narrow: the bug that motivated all this was a data race, which unit tests
// don't catch — `make tsan` is the tool for that. What IS worth asserting is
// the logic that's easy to get quietly wrong and impossible to eyeball:
// the kernel's 1/2/4 pressure bitmask (a naive rawValue init maps warning to
// critical) and the hysteresis streak counter that keeps the menu bar from
// flickering every 5s.
//
// Exits non-zero on failure so CI or a pre-commit hook can gate on it.

var failed = false

func check(_ name: String, _ failures: [String]) {
    if failures.isEmpty {
        print("ok   \(name)")
    } else {
        failed = true
        print("FAIL \(name) — \(failures.count) failure(s)")
        failures.forEach { print("       \($0)") }
    }
}

check("MemoryScanner pure logic", MemoryScanner.selfTest())

// Sanity-check a live sample against the machine we're running on. Not an
// assertion about exact values — just that the reading is self-consistent and
// in range, which catches page-size and field-selection mistakes (using a
// hardcoded 4096 on a 16K-page Mac, or the uncompressed compressor total,
// both produce numbers that fail these bounds).
if let s = MemoryScanner().scan() {
    var problems: [String] = []
    if s.totalBytes != ProcessInfo.processInfo.physicalMemory {
        problems.append("totalBytes \(s.totalBytes) != physicalMemory \(ProcessInfo.processInfo.physicalMemory)")
    }
    if s.usedBytes > s.totalBytes {
        problems.append("usedBytes \(s.usedBytes) exceeds totalBytes \(s.totalBytes)")
    }
    if s.compressedBytes > s.totalBytes {
        problems.append("compressedBytes \(s.compressedBytes) exceeds totalBytes — wrong compressor field?")
    }
    if !(0...100).contains(s.usedPercent) {
        problems.append("usedPercent out of range: \(s.usedPercent)")
    }
    check("MemoryScanner live sample", problems)
    print("     \(s.usedPercent)% used, \(s.compressedBytes / 1_048_576) MB compressed, pressure \(s.pressure)")
} else {
    print("skip MemoryScanner live sample — host_statistics64 unavailable")
}

// Per-process footprint. This replaced `ps rss`, which excludes compressed
// pages and therefore ranked sessions wrongly on a machine under pressure —
// the whole reason the per-session figure exists. The pointer rebinding here
// is easy to get subtly wrong (a bad rebind segfaults rather than returning
// an error), so assert it actually works rather than trusting it compiles.
do {
    var problems: [String] = []
    let me = ProcessInfo.processInfo.processIdentifier

    guard let mine = MemoryScanner.footprint(me) else {
        problems.append("footprint(self) returned nil — rebinding or RUSAGE_INFO_V4 wrong")
        check("MemoryScanner.footprint", problems)
        exit(failed ? 1 : 0)
    }
    if mine == 0 { problems.append("footprint(self) == 0") }
    // Loose on purpose: this asserts "we read a real field", not a size. This
    // test binary sits right around 1 MB, so a tighter floor would be flaky.
    if mine < 256 << 10 { problems.append("footprint(self) implausibly small: \(mine)") }
    if mine > ProcessInfo.processInfo.physicalMemory {
        problems.append("footprint(self) exceeds physical memory: \(mine)")
    }
    // A pid that cannot exist must return nil, not a garbage value — the scan
    // path calls this for pids that may have exited between passes.
    if let bogus = MemoryScanner.footprint(Int32.max) {
        problems.append("footprint(Int32.max) should be nil, got \(bogus)")
    }
    check("MemoryScanner.footprint", problems)
    print("     self = \(mine / 1_048_576) MB")
}

exit(failed ? 1 : 0)
