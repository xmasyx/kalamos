import Darwin
import Foundation

/// What the kernel counts against this process, measured from inside it.
///
/// ISC-107 has been open since the buffer-cache ceiling went in, and it has
/// stayed open for a reason that has nothing to do with the code: the claim is
/// "under 7 GB after a day of real use", and the only way to check it was to
/// remember to run `/usr/bin/footprint -p $(pgrep -x Kalamos)` the following day,
/// on a process nobody had restarted in the meantime. Every rebuild resets the
/// clock. In practice the reading was never taken.
///
/// A number the app writes down every half hour needs nobody to remember
/// anything. Tomorrow the answer is in the log, with the process age beside it,
/// and if a rebuild reset the clock the log says that too.
///
/// `phys_footprint` from `task_vm_info` is the same quantity `/usr/bin/footprint`
/// prints under that name — checked against it rather than assumed.
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

    /// One line every half hour — the first one AFTER the models are up.
    ///
    /// Sampling at launch measures an app that has loaded nothing: the first
    /// line of the first run said 11 MB while the system tool said 4247 MB for
    /// the same app moments later, which looks like a broken measurement and is
    /// really just a measurement taken too early. Waiting one interval before
    /// the first sample makes every line in the log comparable to every other.
    @discardableResult
    static func startLogging(every seconds: TimeInterval = 1_800,
                             firstAfter warmup: TimeInterval = 60) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
            while !Task.isCancelled {
                if let mb = megabytes {
                    Log.write(String(format: "footprint: %d MB after %.1f h of uptime", mb, ageHours))
                }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
}
