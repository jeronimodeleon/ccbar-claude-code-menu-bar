import Foundation

// Single entry point for every child process the scanners spawn.
//
// Four hazards this exists to remove, each of which wedges a scan queue:
//
//   1. stderr. Every call site used to set `standardError = Pipe()` and never
//      read it. A child that writes more than the ~64KB pipe buffer to stderr
//      blocks in write(2) with nobody draining, and the parent then blocks in
//      waitUntilExit() with nobody exiting. stderr goes to /dev/null instead —
//      nothing to fill, nothing to drain.
//   2. No deadline. `git`, `gh` and `lsof` can all stall indefinitely (network,
//      a hung mount, a lock held by another git). A wall-clock watchdog
//      terminates the child so the caller gets nil and moves on.
//   3. Unbounded waits. Neither the exit wait nor the stdout drain may park the
//      caller past the deadline. A child in uninterruptible (D) state on a hung
//      NFS/SMB/FUSE mount ignores *both* SIGTERM and SIGKILL — `lsof` is the
//      classic offender since it walks every mount point — so waiting on its
//      exit is waiting forever.
//   4. Inherited stdin. A `git`/`gh` that decides to prompt for credentials
//      would read from whatever stdin the app inherited and block until the
//      watchdog fired, which is indistinguishable from "not authenticated".
//
// All of this matters more now that scans are serialized: one wedged child
// would otherwise freeze all scanning permanently.
enum Subprocess {
    /// Shared watchdog queue — one serial queue for all calls, so a timer per
    /// invocation costs no thread.
    private static let watchdogQueue = DispatchQueue(label: "com.ccbar.subprocess.watchdog")

    /// How long a child gets to honor SIGTERM before we SIGKILL it.
    private static let killGrace: TimeInterval = 2

    /// Slack after SIGKILL for the kernel to tear the process down before we
    /// stop waiting and treat it as unkillable.
    private static let reapGrace: TimeInterval = 1

    /// Drain handlers run here. A dispatch source never runs its own handler
    /// re-entrantly, so a concurrent queue lets independent calls drain in
    /// parallel without one wedged pipe stalling another.
    private static let drainQueue = DispatchQueue(label: "com.ccbar.subprocess.drain",
                                                  attributes: .concurrent)

    /// Runs `path` with `args`, returns stdout as UTF-8, or nil on failure/timeout.
    /// stderr is discarded (never piped — an undrained pipe deadlocks the parent).
    /// Kills the child and returns nil if it exceeds `timeout` seconds.
    ///
    /// - Parameters:
    ///   - environment: replaces the inherited environment when non-nil. Needed
    ///     for `gh`, which lives outside the minimal PATH a Dock-launched app gets.
    ///   - requireZeroExit: when true, a non-zero exit status yields nil. Off by
    ///     default because `lsof` routinely exits non-zero while still producing
    ///     the rows we want; `git` and `gh` opt in.
    static func run(_ path: String,
                    _ args: [String],
                    timeout: TimeInterval = 10,
                    environment: [String: String]? = nil,
                    requireZeroExit: Bool = false) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if let environment { task.environment = environment }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // Never inherit the app's stdin: a child that prompts must fail, not hang.
        task.standardInput = FileHandle.nullDevice

        // State shared with the watchdog and the drain handler.
        let lock = NSLock()
        var buffer = Data()
        var timedOut = false
        var reaped = false

        // Foundation invokes terminationHandler only after it has waitpid()'d,
        // so this is the earliest instant the pid may be recycled — and hence
        // the exact point past which the watchdog must never signal. Setting the
        // flag here (rather than after the wait returns) leaves no window at all.
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in
            lock.lock()
            reaped = true
            lock.unlock()
            exited.signal()
        }

        do {
            try task.run()
        } catch {
            return nil   // binary missing or not executable
        }

        // Drain stdout as the child writes, so it can never stall on a full pipe
        // buffer. A dispatch source (rather than readDataToEndOfFile) is what
        // lets us stop reading on demand: a descendant that inherited the write
        // end holds the pipe open long after the child is gone, and waiting for
        // an EOF that never comes would cost us output we already have.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        // O_NONBLOCK is what makes every read below incapable of parking a thread.
        let nonBlocking = flags != -1 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1

        // Reads until the pipe is dry. Returns false at EOF. Never blocks.
        func drainAvailable() -> Bool {
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    lock.lock()
                    buffer.append(contentsOf: scratch[0..<n])
                    lock.unlock()
                } else if n == 0 {
                    return false                       // EOF
                } else {
                    if errno == EINTR { continue }
                    return true                        // EAGAIN — wait for the next event
                }
            }
        }

        let drainStopped = DispatchSemaphore(value: 0)
        let drain = DispatchSource.makeReadSource(fileDescriptor: fd, queue: drainQueue)
        drain.setEventHandler {
            // Cancel on EOF, or the source spins firing on a closed pipe.
            if !drainAvailable() { drain.cancel() }
        }
        drain.setCancelHandler { drainStopped.signal() }
        if nonBlocking { drain.resume() }

        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            lock.lock()
            // terminate() must stay *inside* the lock: releasing it first opens
            // a window where the child is reaped and its pid reused before the
            // signal lands. Process.terminate() does not guard on exit state.
            if !reaped {
                timedOut = true
                task.terminate()   // SIGTERM
            }
            lock.unlock()

            // Escalate for children that ignore SIGTERM.
            watchdogQueue.asyncAfter(deadline: .now() + killGrace) {
                lock.lock()
                defer { lock.unlock() }
                guard !reaped, task.isRunning else { return }
                kill(task.processIdentifier, SIGKILL)
            }
        }
        watchdog.resume()

        // Bound the exit wait: SIGTERM lands at `timeout`, SIGKILL at
        // `timeout + killGrace`, plus slack for the kill to take effect. Past
        // that the child is unkillable — a process in uninterruptible (D) state
        // on a hung mount ignores SIGKILL — and waiting on it would park this
        // queue forever, the exact silent freeze we are here to prevent.
        let didExit = exited.wait(timeout: .now() + timeout + killGrace + reapGrace) == .success

        // Stop draining. Dispatch runs a cancel handler only after any in-flight
        // event handler has returned, so once this wait completes the buffer is
        // settled and the fd is ours to read without racing the source.
        if nonBlocking {
            drain.cancel()
            drainStopped.wait()
            drain.setEventHandler(handler: nil)     // break the source↔handler cycle
            drain.setCancelHandler(handler: nil)
            // Everything the child wrote is already in the pipe buffer — write(2)
            // returned before it exited — so one final sweep collects any bytes
            // that never raised a readable event. No waiting for EOF required.
            _ = drainAvailable()
        }

        watchdog.cancel()

        lock.lock()
        let didTimeOut = timedOut
        let data = buffer
        lock.unlock()

        // A killed child's output is truncated at an arbitrary byte, so report
        // "no data" rather than handing callers a partial parse. A child we
        // never saw exit is likewise unusable — and terminationStatus raises
        // if the process never terminated, so it must not be read here.
        guard !didTimeOut, didExit else { return nil }
        guard !requireZeroExit || task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
