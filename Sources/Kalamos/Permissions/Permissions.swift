import AppKit
import AVFoundation

/// Microphone + Accessibility permission checks. Both are required: the mic to
/// record, Accessibility to read the hot key globally and post the paste event.
enum Permissions {

    // MARK: Microphone
    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone(_ completion: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Task { @MainActor in completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default:
            Task { @MainActor in completion(false) }
        }
    }

    // MARK: Accessibility
    /// Pass `prompt: true` to show the system "grant Accessibility" dialog.
    static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt — avoids touching the
        // non-concurrency-safe C global under Swift 6.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
