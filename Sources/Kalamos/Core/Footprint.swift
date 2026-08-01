import Darwin
import Foundation

/// What the kernel counts against this process, measured from inside it.
///
/// ISC-107 stayed open for a reason that had nothing to do with the code: the
/// claim was "under 7 GB after a day of real use", and checking it meant
/// remembering to run `/usr/bin/footprint -p $(pgrep -x Kalamos)` the next day,
/// on a process nobody had restarted in the meantime. Every rebuild reset the
/// clock, and the reading was never taken. It closed in the end from the field —
/// A full day of real use ran at 4 GB with the memory set to never free.
///
/// What stays is the guard, not the diary. See `startWatching`.
///
/// `phys_footprint` from `task_vm_info` is the same quantity `/usr/bin/footprint`
/// prints under that name — checked against it rather than assumed: 4233 MB from
/// here against 4236 MB from the tool, same process, seconds apart.
enum Footprint {

    /// Bytes, or nil if the kernel refuses to say.
    static func bytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    static var megabytes: Int? { bytes().map { Int($0 / 1_048_576) } }

    /// How long this process has been up. The footprint claim is about a DAY of
    /// use, so a reading without an age is not evidence of anything — that is
    /// exactly how "4.9 GB" got mistaken for a healthy number when it was simply
    /// a fresh start.
    ///
    /// Read from the KERNEL, not from a `Date()` captured in Swift. A `static
    /// let` is initialized lazily, on first access — which is inside the first
    /// log line, a minute after launch, so the first reading came out as
    /// "-0.0 h of uptime" and every later one would have been a minute short.
    /// The kernel knows exactly when this process started and cannot be tricked
    /// by when we happen to ask.
    static var ageHours: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - start) / 3600
    }

    /// The number ISC-107 was about: 13 GB before the buffer-cache ceiling, and
    /// the claim was "under 7 after a day". A full day of real use ran at 4 GB
    /// with the memory set to never free, which is what closed it.
    static let ceilingMB = 7 * 1024

    /// Watch, do not narrate.
    ///
    /// This began as a line every half hour, which is a diary — and the user's
    /// objection was the right one: *"non credo sia qualcosa che debba rimanere
    /// lì sempre."* A diary in a shipping app is noise nobody reads and one more
    /// thing to explain to whoever clones the repo.
    ///
    /// So it keeps the sampling, which costs one `task_info` every half hour and
    /// nothing else, and writes only when the number crosses the ceiling the
    /// claim named. Same cost, silent forever, and it still catches the one
    /// thing worth catching: the ceiling disappearing in a refactor months from
    /// now. `SourceGuardTests` already guards the SOURCE of that cap — this
    /// guards the behaviour, which is the half a source check cannot see.
    ///
    /// It reports again only after another gigabyte, so a bad day writes a short
    /// series and not a thousand identical lines.
    ///
    /// The decision is pulled out because it is a branch that, if all goes well,
    /// NEVER runs — and a branch that never runs is indistinguishable from a
    /// branch that cannot run. `FootprintWatchTests` makes it run.

    /// Worth writing a line about?
    static func shouldReport(mb: Int, lastReported: Int) -> Bool {
        mb >= ceilingMB && mb >= lastReported + 1024
    }

    @discardableResult
    static func startWatching(every seconds: TimeInterval = 1_800,
                              firstAfter warmup: TimeInterval = 60) -> Task<Void, Never> {
        Task {
            // Sampling at launch would measure an app that has loaded nothing:
            // the first run reported 11 MB while the system tool said 4247 MB
            // for the same app moments later. Not a broken measurement — one
            // taken before the models were up.
            try? await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
            var reportedAt = 0
            while !Task.isCancelled {
                if let mb = megabytes, shouldReport(mb: mb, lastReported: reportedAt) {
                    Log.write(String(format:
                        "footprint %d MB after %.1f h — above the %d MB ceiling ISC-107 set",
                        mb, ageHours, ceilingMB))
                    reportedAt = mb
                }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
}
