import AppKit
import AVFoundation
import ServiceManagement

/// Self-diagnosis: `Kalamos --doctor`.
///
/// Answers the only question that matters when dictation "doesn't work": WHICH
/// of the six things it depends on is missing. Every check prints a verdict and,
/// when it fails, the exact command or click that fixes it.
///
/// Deliberately standalone — reads UserDefaults and the filesystem directly and
/// never touches `AppState`, so it runs before any app state exists and cannot
/// itself be broken by the misconfiguration it is trying to report.
///
/// Exit code: 0 when every REQUIRED check passes, 1 otherwise. Optional checks
/// (models not yet downloaded, launch-at-login) report but never fail the run —
/// they are states, not faults.
enum Doctor {

    private enum Verdict {
        case ok(String)
        case warn(String)
        case fail(String, fix: String)

        var mark: String {
            switch self {
            case .ok: return "✅"
            case .warn: return "⚠️ "
            case .fail: return "❌"
            }
        }
        var detail: String {
            switch self {
            case .ok(let d), .warn(let d), .fail(let d, _): return d
            }
        }
    }

    /// True when a terminal started this process instead of LaunchServices.
    ///
    /// This matters more than it looks. macOS attributes privacy grants to the
    /// *responsible* process, which for a binary you exec from a shell is the
    /// terminal — not Kalamos. So Microphone and Accessibility read the terminal's
    /// grants, and a perfectly working install reports a red microphone. An app
    /// opened normally is re-parented to launchd (pid 1); a shell child is not.
    private static var launchedFromTerminal: Bool { getppid() != 1 }

    /// The full report as text, plus how many REQUIRED checks failed.
    /// Shared by `--doctor` and the in-app Diagnostics menu item so both can
    /// never drift apart.
    static func report() -> (text: String, failures: Int) {
        var lines: [String] = ["Kalamos — doctor", ""]
        var failures = 0
        var fixes: [String] = []

        if launchedFromTerminal {
            lines.append("""
                ⚠️  Started from a terminal, so macOS reports the TERMINAL's privacy
                   grants, not Kalamos's. Microphone and Accessibility are shown as
                   unknown below — read them from the menu bar instead:
                   Kalamos ▸ Diagnostics…
                """)
            lines.append("")
        }

        for (label, verdict) in checks() {
            lines.append("\(verdict.mark) \(label.padded(to: 24)) \(verdict.detail)")
            if case .fail(_, let fix) = verdict {
                failures += 1
                fixes.append("\(label): \(fix)")
            }
        }

        if fixes.isEmpty {
            lines.append("")
            lines.append("All required checks passed.")
        } else {
            lines.append("")
            lines.append("\(failures) problem\(failures == 1 ? "" : "s") to fix:")
            lines.append("")
            for f in fixes { lines.append("  • \(f)") }
        }
        return (lines.joined(separator: "\n"), failures)
    }

    /// Run every check, print the report, return the process exit code.
    static func run() -> Int32 {
        let (text, failures) = report()
        print(text)
        return failures == 0 ? 0 : 1
    }

    // MARK: Checks

    private static func checks() -> [(String, Verdict)] {
        [
            ("macOS", macOSVersion()),
            ("Apple Silicon", appleSilicon()),
            ("Microphone", microphone()),
            ("Accessibility", accessibility()),
            ("Speech model", speechModel()),
            ("Cleanup model", cleanupModel()),
            ("MLX Metal shaders", metallib()),
            ("Trigger key", triggerKey()),
            ("Launch at login", launchAtLogin()),
            ("Model storage", modelStorage()),
            ("Debug logging", debugLogging()),
        ]
    }

    private static func macOSVersion() -> Verdict {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let s = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return v.majorVersion >= 14
            ? .ok(s)
            : .fail("\(s) — Kalamos needs macOS 14 or newer",
                    fix: "update macOS in System Settings → General → Software Update")
    }

    /// Reads the CPU capability rather than the compiled architecture: a build
    /// running under Rosetta would report arm64 at compile time and still have no
    /// Neural Engine, which is the thing that actually matters here.
    private static func appleSilicon() -> Verdict {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        return ok
            ? .ok("yes — transcription runs on the Neural Engine")
            : .fail("Intel Mac (or running under Rosetta)",
                    fix: "Kalamos requires an M1 or newer Mac; on Apple Silicon, uncheck \"Open using Rosetta\" in the app's Get Info panel")
    }

    private static func microphone() -> Verdict {
        if launchedFromTerminal { return .warn("unknown from a terminal — see Diagnostics… in the menu") }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .ok("granted")
        case .notDetermined:
            return .fail("not requested yet",
                         fix: "launch Kalamos and dictate once — macOS will ask")
        default:
            return .fail("denied",
                         fix: "System Settings → Privacy & Security → Microphone → enable Kalamos")
        }
    }

    private static func accessibility() -> Verdict {
        if launchedFromTerminal { return .warn("unknown from a terminal — see Diagnostics… in the menu") }
        // prompt: false — a diagnostic must never pop a system dialog as a side
        // effect of being run.
        return Permissions.accessibilityTrusted(prompt: false)
            ? .ok("granted")
            : .fail("not granted — the hot key and text injection cannot work",
                    fix: "System Settings → Privacy & Security → Accessibility → enable Kalamos")
    }

    private static func speechModel() -> Verdict {
        let id = UserDefaults.standard.string(forKey: "whisperModel")
            ?? "openai_whisper-large-v3-v20240930_turbo"
        let dir = ModelStorage.base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
        // AudioEncoder.mlmodelc is what WhisperKit itself probes for; a bare
        // directory can exist from an interrupted download.
        let marker = dir.appendingPathComponent("AudioEncoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return .warn("\(ModelCatalog.speechTitle(for: id)) not downloaded — downloads on first dictation")
        }
        return .ok("\(ModelCatalog.speechTitle(for: id)) — \(size(of: dir))")
    }

    private static func cleanupModel() -> Verdict {
        let id = UserDefaults.standard.string(forKey: "cleanupModelID")
            ?? "mlx-community/Qwen2.5-7B-Instruct-4bit"
        let dir = ModelStorage.base.appendingPathComponent("models/\(id)", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path) else {
            return .warn("\(ModelCatalog.cleanupTitle(for: id)) not downloaded — downloads on first AI cleanup")
        }
        return .ok("\(ModelCatalog.cleanupTitle(for: id)) — \(size(of: dir))")
    }

    /// MLX compiles its Metal kernels into a resource bundle at build time. When
    /// it is missing the app still launches and silently loses AI cleanup — the
    /// exact failure this check exists to make loud.
    private static func metallib() -> Verdict {
        #if canImport(MLXLLM)
        guard let resources = Bundle.main.resourceURL else {
            return .warn("cannot inspect bundle resources (running outside an .app?)")
        }
        let lib = resources
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        return FileManager.default.fileExists(atPath: lib.path)
            ? .ok("compiled in")
            : .fail("default.metallib missing — AI cleanup and translation will fail",
                    fix: "rebuild with ./Scripts/build-app.sh (xcodebuild compiles the shaders; `swift build` does not)")
        #else
        return .warn("not compiled in — rule-based cleanup only")
        #endif
    }

    private static func triggerKey() -> Verdict {
        let code = UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? 0x36
        let ptt = (UserDefaults.standard.object(forKey: "pushToTalkEnabled") as? Bool) ?? true
        let mode = ptt ? "hold to talk · double-tap for hands-free" : "double-tap only"
        return .ok("\(keyName(code)) — \(mode)")
    }

    /// A copy that was never registered reports `.notRegistered`, which is a
    /// normal state rather than a fault — so this check never fails the run.
    private static func launchAtLogin() -> Verdict {
        switch SMAppService.mainApp.status {
        case .enabled:        return .ok("enabled")
        case .requiresApproval:
            return .warn("blocked — approve Kalamos in System Settings → General → Login Items")
        case .notFound:       return .warn("not applicable (running the bare binary, not the .app)")
        default:              return .ok("disabled")
        }
    }

    private static func modelStorage() -> Verdict {
        let base = ModelStorage.base
        guard FileManager.default.isWritableFile(atPath: base.path) else {
            return .fail("\(tilde(base.path)) is not writable",
                         fix: "check the permissions on ~/Library/Application Support/Kalamos")
        }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let freeGB = Double(free) / 1_000_000_000
        let detail = "\(tilde(base.path)) — \(String(format: "%.1f", freeGB)) GB free"
        // The default speech + cleanup pair is ~6 GB; below that a first run
        // fails mid-download with an opaque error.
        return freeGB < 8
            ? .warn("\(detail) (models need ~6 GB)")
            : .ok(detail)
    }

    /// Not a fault either way — but knowing whether transcripts are being written
    /// to disk is the first thing you need when diagnosing a recognition problem,
    /// and the first thing you want to turn back OFF afterwards.
    private static func debugLogging() -> Verdict {
        let on = UserDefaults.standard.bool(forKey: "debugLogging")
        return on
            ? .warn("ON — transcripts are being written to \(tilde(Log.url.path))")
            : .ok("off (enable: defaults write com.kalamos.app debugLogging -bool true)")
    }

    // MARK: Helpers

    /// `/Users/you/Library/…` → `~/Library/…`. Two reasons, both mattering: the
    /// report stays inside one line so the columns keep their alignment, and the
    /// Copy button no longer puts a username into text headed for a bug report.
    private static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func keyName(_ code: Int) -> String {
        switch code {
        case 0x36: return "Right Command"
        case 0x37: return "Left Command"
        case 0x3A: return "Left Option"
        case 0x3D: return "Right Option"
        case 0x3B: return "Left Control"
        case 0x3E: return "Right Control"
        case 0x3F: return "Fn / Globe"
        default:   return "key code \(code)"
        }
    }

    /// Directory size on disk, best-effort. Reported so "downloaded" can be told
    /// apart from "half-downloaded".
    private static func size(of dir: URL) -> String {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return "size unknown" }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
        }
        return String(format: "%.1f GB", Double(total) / 1_000_000_000)
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
