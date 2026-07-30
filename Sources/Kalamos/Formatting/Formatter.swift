import Foundation

/// Context passed to the formatter so it can adapt output to where the text
/// is going and what was spoken.
struct FormattingContext: Sendable {
    let language: Language
    let frontmostBundleID: String?   // e.g. "com.apple.dt.Xcode" → code context
    let promptOverride: String?      // user-edited cleanup system prompt (nil = built-in)

    init(language: Language, frontmostBundleID: String?, promptOverride: String? = nil) {
        self.language = language
        self.frontmostBundleID = frontmostBundleID
        self.promptOverride = promptOverride
    }

    /// Real code editors only — dictation into them stays verbatim. Terminals are
    /// deliberately NOT here: prose gets dictated into them (talking to a CLI
    /// agent), so they get normal cleanup like any other app.
    ///
    /// Matched by bundle-id PREFIX, never by substring. Substring matching looks
    /// equivalent and is not: iTerm2's identifier is `com.googlecode.iterm2`,
    /// whose vendor segment contains "code", so every dictation into the terminal
    /// was classified as code and skipped the LLM cleanup entirely — silently,
    /// because the rule-based fallback still returns plausible text. Found on
    /// 2026-07-29 by noticing that cleanup output was byte-identical to the raw
    /// transcript in under a second, which a 7B model cannot do.
    private static let codeEditorPrefixes = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.vscodium",
        "com.sublimetext",
        "com.jetbrains",
        "com.panic.nova",
        "dev.zed.zed",
        "com.todesktop.230313mzl4w4u92",   // Cursor
    ]

    var isCodeEditor: Bool {
        guard let id = frontmostBundleID?.lowercased() else { return false }
        return Self.codeEditorPrefixes.contains { id.hasPrefix($0) }
    }

    /// Terminals. Prose gets dictated into them — you are usually talking to a CLI
    /// agent — so unlike a code editor they DO get cleaned up. But they get it
    /// verbatim: punctuation and capitals and filler, and not one word more.
    ///
    /// The reason is not taste. Text dictated into a terminal is an instruction to
    /// something that will act on it, so a model that helpfully drops a clause or
    /// swaps a word for a better one is not tidying a sentence, it is editing a
    /// command. In a chat window a rephrase is a nuisance; here it changes what
    /// gets done.
    private static let terminalPrefixes = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    var isTerminal: Bool {
        guard let id = frontmostBundleID?.lowercased() else { return false }
        return Self.terminalPrefixes.contains { id.hasPrefix($0) }
    }

    /// Writing-context category used to shape tone (feature #7).
    enum Tone { case casual, email, formal, neutral }

    var tone: Tone {
        guard let id = frontmostBundleID?.lowercased() else { return .neutral }
        let has: (String) -> Bool = { id.contains($0) }
        if has("messages") || has("whatsapp") || has("telegram") || has("slack")
            || has("discord") || has("messenger") { return .casual }
        if has("mail") || has("outlook") || has("spark") || has("airmail") { return .email }
        if has("pages") || has("word") || has("notes") || has("textedit")
            || has("obsidian") || has("ulysses") || has("docs") { return .formal }
        return .neutral
    }
}

/// Cleans up / structures a raw transcript before injection.
protocol TextFormatter: Sendable {
    func format(_ raw: String, context: FormattingContext) async -> String
}

/// Pass-through formatter (FormatterMode.off).
struct IdentityFormatter: TextFormatter {
    func format(_ raw: String, context: FormattingContext) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
