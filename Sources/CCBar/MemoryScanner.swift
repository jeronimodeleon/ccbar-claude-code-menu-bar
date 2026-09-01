import Foundation

// Mirrors the kernel's memorystatus pressure notion so the UI can color the
// menu bar item. Comparable so callers can write `pressure >= .warning`.
enum MemoryPressureLevel: Int, Comparable {
    case unknown = 0
    case normal  = 1
    case warning = 2
    case critical = 3

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MemorySnapshot: Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64          // app + wired + compressed ("Memory Used" in Activity Monitor)
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let pressure: MemoryPressureLevel

    // Clamped: a transient sample can in principle exceed physicalMemory, and a
    // >100% menu bar reading would look like a bug rather than pressure.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    var usedPercent: Int {
        min(100, max(0, Int((usedFraction * 100).rounded())))
    }
}

final class MemoryScanner {
    // All three reads are direct syscalls (microseconds) — this runs on the main
    // thread every poll, so no subprocesses and no file I/O here.
    func scan() -> MemorySnapshot? {
        guard let vm = hostVMStatistics() else { return nil }

        // Apple Silicon pages are 16K, not 4K. Ask the kernel rather than
        // assuming — hardcoding 4096 makes every figure 4x too small.
        let pageSize = UInt64(vm_kernel_page_size)

        // Activity Monitor's "App Memory" is internal minus purgeable. Purgeable
        // should never exceed internal, but an underflow on UInt64 traps and
        // kills the app, so saturate instead of trusting the invariant.
        let appPages = UInt64(vm.internal_page_count)
            .subtractingReportingOverflow(UInt64(vm.purgeable_count))
        let internalMinusPurgeable = appPages.overflow ? 0 : appPages.partialValue

        // compressor_page_count = pages the compressor *occupies*. Not
        // total_uncompressed_pages_in_compressor, which is the pre-compression
        // size and runs ~8x larger.
        let compressedPages = UInt64(vm.compressor_page_count)
        let usedPages = internalMinusPurgeable + UInt64(vm.wire_count) + compressedPages

        let swap = swapUsage()

        return MemorySnapshot(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            usedBytes: usedPages * pageSize,
            compressedBytes: compressedPages * pageSize,
            swapUsedBytes: swap?.used ?? 0,
            swapTotalBytes: swap?.total ?? 0,
            pressure: Self.pressureLevel(fromRaw: rawPressureLevel() ?? -1)
        )
    }

    // Per-process memory, as Activity Monitor's "Memory" column reports it.
    //
    // phys_footprint, not `ps rss`: RSS excludes a process's compressed pages,
    // and on a machine under pressure that is most of its real cost — measured
    // here, a claude session reads 52 MB by RSS and 275 MB by footprint, so
    // ranking sessions by RSS points at the wrong one.
    //
    // static because it is called from the scan queue, where the shared
    // MemoryScanner instance (main-thread-confined) must not be touched. One
    // syscall, unprivileged for same-uid pids; returns nil for a pid that has
    // exited or that we may not inspect.
    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        // libproc types the buffer as `rusage_info_t *` (i.e. void **) but
        // uses the pointer value itself as the destination, so the rebind is
        // just satisfying the imported signature.
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    // kern.memorystatus_vm_pressure_level is a BITMASK matching the
    // DISPATCH_MEMORYPRESSURE_* constants (1/2/4), not an ordinal — mapping it
    // through MemoryPressureLevel(rawValue:) silently mislabels CRITICAL.
    static func pressureLevel(fromRaw raw: Int32) -> MemoryPressureLevel {
        switch raw {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func hostVMStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    private func rawPressureLevel() -> Int32? {
        sysctlValue(Int32.self, named: "kern.memorystatus_vm_pressure_level")
    }

    // xsw_usage reports bytes already — no page-size scaling here.
    private func swapUsage() -> (used: UInt64, total: UInt64)? {
        guard let usage = sysctlValue(xsw_usage.self, named: "vm.swapusage") else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    // Shared sysctlbyname read: fetches into a zeroed T and rejects any size
    // mismatch, so a kernel struct change fails closed rather than garbling.
    private func sysctlValue<T>(_ type: T.Type, named name: String) -> T? {
        let value = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment
        )
        defer { value.deallocate() }
        _ = value.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)

        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, value, &size, nil, 0) == 0,
              size == MemoryLayout<T>.size else { return nil }
        return value.load(as: T.self)
    }
}

// Pressure flaps between adjacent levels on a loaded machine. The menu bar
// colors off this, so require sustained agreement before changing the answer.
struct PressureHysteresis {
    /// Consecutive samples at a new level required before `stable` moves.
    static let threshold = 3

    private(set) var stable: MemoryPressureLevel
    private var candidate: MemoryPressureLevel
    private var streak = 0

    init(initial: MemoryPressureLevel = .normal) {
        stable = initial
        candidate = initial
    }

    /// Feed each poll. Only returns a changed level after `threshold`
    /// consecutive samples agree. Returns the current stable level.
    mutating func update(_ sample: MemoryPressureLevel) -> MemoryPressureLevel {
        // Any sample agreeing with the current level cancels a pending change.
        guard sample != stable else {
            candidate = stable
            streak = 0
            return stable
        }

        if sample == candidate {
            streak += 1
        } else {
            candidate = sample
            streak = 1
        }

        if streak >= Self.threshold {
            stable = sample
            streak = 0
        }
        return stable
    }
}

#if DEBUG
extension MemoryScanner {
    /// Self-check for the pure logic. Returns a list of failure descriptions (empty == pass).
    /// The repo has no test framework; this covers the two easiest bugs to ship
    /// here — the 1/2/4 bitmask mapping and the hysteresis counter.
    static func selfTest() -> [String] {
        var failures: [String] = []

        func expect(_ actual: MemoryPressureLevel, _ expected: MemoryPressureLevel, _ what: String) {
            if actual != expected {
                failures.append("\(what): expected \(expected), got \(actual)")
            }
        }

        // Bitmask mapping — 3 and -1 are not valid masks and must not sneak
        // through as .critical/.normal via rawValue.
        let mapping: [(Int32, MemoryPressureLevel)] = [
            (1, .normal), (2, .warning), (4, .critical),
            (0, .unknown), (3, .unknown), (-1, .unknown), (8, .unknown)
        ]
        for (raw, expected) in mapping {
            expect(pressureLevel(fromRaw: raw), expected, "pressureLevel(fromRaw: \(raw))")
        }

        // Escalation takes exactly `threshold` consecutive samples.
        var h = PressureHysteresis()
        expect(h.update(.critical), .normal, "escalate sample 1")
        expect(h.update(.critical), .normal, "escalate sample 2")
        expect(h.update(.critical), .critical, "escalate sample 3")

        // A non-matching sample mid-run resets the counter.
        var reset = PressureHysteresis()
        _ = reset.update(.critical)
        _ = reset.update(.critical)
        expect(reset.update(.warning), .normal, "reset: interrupting sample")
        expect(reset.update(.critical), .normal, "reset: restart sample 1")
        expect(reset.update(.critical), .normal, "reset: restart sample 2")
        expect(reset.update(.critical), .critical, "reset: restart sample 3")

        // A sample matching the stable level also cancels a pending change.
        var cancel = PressureHysteresis()
        _ = cancel.update(.warning)
        _ = cancel.update(.warning)
        expect(cancel.update(.normal), .normal, "cancel: matching sample")
        expect(cancel.update(.warning), .normal, "cancel: streak restarted")

        // De-escalation is equally sticky.
        var down = PressureHysteresis(initial: .critical)
        expect(down.update(.normal), .critical, "de-escalate sample 1")
        expect(down.update(.normal), .critical, "de-escalate sample 2")
        expect(down.update(.normal), .normal, "de-escalate sample 3")
        expect(down.stable, .normal, "de-escalate stable property")

        // Percentage arithmetic: divide-by-zero guard and clamping.
        func snapshot(used: UInt64, total: UInt64) -> MemorySnapshot {
            MemorySnapshot(totalBytes: total, usedBytes: used, compressedBytes: 0,
                           swapUsedBytes: 0, swapTotalBytes: 0, pressure: .unknown)
        }
        if snapshot(used: 100, total: 0).usedPercent != 0 {
            failures.append("usedPercent: zero total should be 0")
        }
        if snapshot(used: 200, total: 100).usedPercent != 100 {
            failures.append("usedPercent: over-total should clamp to 100")
        }
        if snapshot(used: 855, total: 1000).usedPercent != 86 {
            failures.append("usedPercent: 855/1000 should round to 86")
        }

        return failures
    }
}
#endif
