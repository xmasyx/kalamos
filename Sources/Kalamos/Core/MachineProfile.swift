import Foundation

/// What this Mac is, read from the machine itself.
///
/// It exists so setup can stop asking questions the computer can answer. The
/// memory page used to print the rule — "after 5 minutes, if you have 8 or 16 GB"
/// — and ask the reader to apply it by hand, while `physicalMemory` answers in a
/// microsecond.
///
/// Everything here comes from `sysctlbyname` and the filesystem: no
/// `system_profiler`, which is a subprocess and costs about a second on a page
/// that has to be up before anyone finishes reading the title (ISC-147).
///
/// Every field is stored rather than computed on demand, so a profile can be
/// invented in a test. The real `ProcessInfo` would only ever exercise the side
/// of each threshold that this particular Mac happens to be on.
struct MachineProfile: Sendable, Equatable {
    /// "Apple M4 Max". Shown, never used to decide — see `chipIsNotADecision`.
    let chipName: String
    let memoryBytes: UInt64
    /// What the disk will really give us, which is not the same as unused blocks:
    /// macOS counts purgeable space as available for important usage.
    let freeDiskBytes: UInt64
    let performanceCores: Int
    let efficiencyCores: Int

    /// This Mac.
    static var current: MachineProfile {
        MachineProfile(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: freeDisk(),
            performanceCores: sysctlInt("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
            efficiencyCores: sysctlInt("hw.perflevel1.logicalcpu") ?? 0)
    }

    // MARK: Reading

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl hands back a C string: everything from the first NUL on is
        // padding, and decoding it whole leaves the terminator inside the String.
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    /// Same key `--doctor` uses, and for the same reason: it is the only one that
    /// answers "will a 4 GB download fit", rather than "how many blocks are unused".
    private static func freeDisk() -> UInt64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let capacity = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return capacity > 0 ? UInt64(capacity) : 0
    }
}

// MARK: - Display

extension MachineProfile {
    var memoryGB: Int { Int((Double(memoryBytes) / 1_073_741_824).rounded()) }
    var freeDiskGB: Int { Int(Double(freeDiskBytes) / 1_073_741_824) }

    /// "10 + 4 core" — the two kinds are worth separating, since the number people
    /// half-remember from the shop is the total.
    var coreSummary: String {
        efficiencyCores > 0
            ? "\(performanceCores) + \(efficiencyCores)"
            : "\(performanceCores)"
    }
}
