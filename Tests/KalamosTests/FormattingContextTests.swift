import Testing
@testable import Kalamos

/// `isCodeEditor` decides whether a dictation gets the on-device LLM cleanup or
/// is passed through verbatim. Getting it wrong in the "yes it is code" direction
/// is invisible: the rule-based fallback returns plausible text, so the feature
/// just quietly stops working for that app.
@Suite struct FormattingContextTests {

    private func ctx(_ bundleID: String?) -> FormattingContext {
        FormattingContext(language: .italian, frontmostBundleID: bundleID)
    }

    @Test func realCodeEditorsAreDetected() {
        for id in ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.sublimetext.4",
                   "com.jetbrains.intellij", "com.panic.Nova", "dev.zed.Zed"] {
            #expect(ctx(id).isCodeEditor, "\(id) should count as a code editor")
        }
    }

    /// The regression this suite exists for. `com.googlecode.iterm2` contains the
    /// substring "code" in its VENDOR segment, so substring matching classified
    /// the terminal as an editor and silently skipped AI cleanup there.
    @Test func terminalsAreNotCodeEditors() {
        for id in ["com.googlecode.iterm2",          // ← the bug
                   "com.apple.Terminal",
                   "dev.warp.Warp-Stable",
                   "co.zeit.hyper",
                   "net.kovidgoyal.kitty",
                   "com.github.wez.wezterm"] {
            #expect(!ctx(id).isCodeEditor, "\(id) is a terminal, not a code editor")
        }
    }

    @Test func ordinaryAppsAndMissingIDsAreNotCodeEditors() {
        for id in ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.Safari"] {
            #expect(!ctx(id).isCodeEditor)
        }
        #expect(!ctx(nil).isCodeEditor)
    }

    /// Terminals are not code editors — they still get cleaned up — but they are
    /// their own category, because text dictated into one is an instruction that
    /// something will act on.
    @Test func terminalsAreRecognisedAsTerminals() {
        for id in ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable",
                   "co.zeit.hyper", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
                   "io.alacritty", "com.mitchellh.ghostty"] {
            #expect(ctx(id).isTerminal, "\(id) is a terminal")
            #expect(!ctx(id).isCodeEditor, "\(id) is not a code editor")
        }
    }

    @Test func ordinaryAppsAreNotTerminals() {
        for id in ["com.apple.mail", "net.whatsapp.WhatsApp", "com.apple.dt.Xcode"] {
            #expect(!ctx(id).isTerminal)
        }
        #expect(!ctx(nil).isTerminal)
    }

    /// Tone drives register, not whether the LLM runs — but the same
    /// substring-vs-prefix sloppiness would misfire here too.
    @Test func toneFollowsTheFrontmostApp() {
        #expect(ctx("net.whatsapp.WhatsApp").tone == .casual)
        #expect(ctx("com.apple.mail").tone == .email)
        #expect(ctx("md.obsidian").tone == .formal)
        #expect(ctx("com.googlecode.iterm2").tone == .neutral)
        #expect(ctx(nil).tone == .neutral)
    }
}
