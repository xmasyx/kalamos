import Foundation
import Testing
@testable import Kalamos

/// Guards that read the source, because what they check is a property of the
/// code rather than of a value it computes.
///
/// The pattern is Otium's: a rule you can only verify by looking at every file
/// is a rule that decays the first time someone adds a file. These are the three
/// that this build turned into claims — an honest status, no setting stranded by
/// the menu that lost it, and buttons you can click anywhere.
@Suite struct SourceGuardTests {

    /// `Sources/Kalamos`, found from this file rather than from a hardcoded path.
    private static var sources: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/KalamosTests/SourceGuardTests.swift
            .deletingLastPathComponent()          // …/Tests/KalamosTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources/Kalamos")
    }

    private static func swiftFiles() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw Failure.noSources
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(out.count > 10, "the source tree should not be nearly empty")
        return out
    }

    enum Failure: Error { case noSources }

    // MARK: ISC-90 — the status says what is actually happening

    /// Only the two places that genuinely move bytes may report a download.
    ///
    /// This is the bug that started the run: one case, `loadingModel`, stood for
    /// downloading, opening a cached model, and thinking — and the icon drew a
    /// download arrow for all three. The split is only worth anything if nothing
    /// new quietly rejoins them.
    @Test func onlyRealDownloadsReportDownloading() throws {
        // Three files move bytes now: the cleanup model, and one per speech
        // engine. Parakeet earned its place here by fetching 461 MB on first
        // use — the guard fired the moment the file was added, which is what it
        // is for. Anything else that joins this list has to justify itself the
        // same way.
        let allowed: Set<String> = [
            "MLXEngine.swift", "WhisperKitTranscriber.swift", "ParakeetTranscriber.swift",
        ]
        var producers: Set<String> = []
        for file in try Self.swiftFiles() where file.text.contains("report(.downloading") {
            producers.insert(file.name)
        }
        #expect(producers == allowed,
                "a download is reported from \(producers.sorted()), expected \(allowed.sorted())")
    }

    /// The retired case, gone everywhere — including from a comment that would
    /// send the next reader looking for it.
    @Test func theConflatedStatusIsGone() throws {
        for file in try Self.swiftFiles() {
            // Code only. The comment that explains why the case was split is
            // supposed to name it, and a guard that forbids its own explanation
            // is a guard that gets deleted.
            let code = file.text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains(".loadingModel"),
                    "\(file.name) still uses .loadingModel")
        }
    }

    // MARK: ISC-96 — nothing was stranded when the submenus went away

    /// Every setting Kalamos writes to disk has a control in Preferences.
    ///
    /// The way to break this build is to delete a submenu and forget to rebuild
    /// its setting in the window: the setting keeps working, keeps being saved,
    /// and becomes unreachable. Nothing about that looks wrong from the outside,
    /// which is exactly why it needs a test rather than a look.
    @Test func everySavedSettingHasAControl() throws {
        let files = try Self.swiftFiles()
        guard let appState = files.first(where: { $0.name == "AppState.swift" })?.text else {
            throw Failure.noSources
        }

        // Properties that are deliberately not settings: live state, the flag
        // that remembers setup ran, and a language set the app never exposed.
        let notSettings: Set<String> = ["status", "didCompleteOnboarding", "enabledLanguages"]

        var properties: Set<String> = []
        for line in appState.split(separator: "\n") where line.contains("@Published var") {
            guard let after = line.range(of: "@Published var ") else { continue }
            let name = line[after.upperBound...]
                .prefix { $0.isLetter || $0.isNumber }
            properties.insert(String(name))
        }
        #expect(properties.count > 8, "expected to find the settings, found \(properties)")

        // Code only. A property named in a comment — including the comment that
        // explains why it was removed — would otherwise satisfy this guard while
        // the control is gone. (Gemini audit, 2026-07-31.)
        let preferences = files
            .filter { $0.name.hasPrefix("Preferences") }
            .map { file in
                file.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
            }
            .joined()
        #expect(!preferences.isEmpty)

        guard let draftSource = files.first(where: { $0.name == "SettingsDraft.swift" })?.text
        else { throw Failure.noSources }

        // Two names for one setting, both deliberate: the draft holds the prompt
        // as "" rather than nil (nil and "" would be two spellings of one state),
        // and the idle timeout lives in Tuning, not AppState.
        let aliases = ["cleanupPromptOverride": "cleanupPrompt"]

        for property in properties.subtracting(notSettings) {
            let inDraft = aliases[property] ?? property
            // Either spelling counts: the window edits `draft.x`, and a couple of
            // read-only bits still come straight from `state.x`.
            #expect(preferences.contains("draft.\(inDraft)")
                    || preferences.contains("state.\(property)"),
                    "\(property) is saved to disk but has no control in Preferences")
            // And it must be part of what Apply hands over, or the control edits
            // something nobody ever writes back.
            #expect(draftSource.contains("var \(inDraft)"),
                    "\(property) has a control but is not in SettingsDraft")
        }

        // The idle timeout: in the draft, and written on apply.
        #expect(draftSource.contains("var idleSeconds"))
        #expect(preferences.contains("draft.idleSeconds"))
    }

    // MARK: ISC-100 — a button is clickable across the whole thing you can see

    /// In SwiftUI, padding and a filled background applied OUTSIDE the `Button`
    /// are decoration behind a button the size of its text. It looks pressable
    /// and is not, and neither the compiler nor a test of behaviour notices.
    /// It has now happened in Otium and in Kalamos, so it is checked instead of
    /// remembered.
    @Test func everyButtonHasAHitShape() throws {
        for file in try Self.swiftFiles() where file.name.hasPrefix("Preferences")
                                              || file.name.hasPrefix("Download") {
            // Per button, not per file. Two counts compared file-wide let one
            // button carrying two `.contentShape` modifiers cover for another
            // carrying none — the guard then passes on a file that contains the
            // exact defect it exists to catch. (Gemini audit, 2026-07-31.)
            //
            // `.buttonStyle(.plain)` closes every hand-drawn button in this app,
            // so the text before each one is that button's own declaration.
            let chunks = file.text.components(separatedBy: ".buttonStyle(.plain)")
            for (index, chunk) in chunks.dropLast().enumerated() {
                // Only the declaration of THIS button: everything after the last
                // `Button` in the chunk. Reading the whole chunk let the first
                // button pass on a `.contentShape` belonging to some other view
                // earlier in the file. (Gemini audit round 3, 2026-07-31.)
                guard let start = chunk.range(of: "Button", options: .backwards) else { continue }
                let declaration = chunk[start.lowerBound...]
                #expect(declaration.contains(".contentShape("),
                        "\(file.name): button #\(index + 1) has no hit shape of its own")
            }
        }
    }

    // MARK: ISC-115 — a shortcut printed in the menu is a shortcut that works

    /// Every key printed next to a status-menu item must have something that
    /// actually listens for it.
    ///
    /// The bug this replaces: *Copy Last Transcription* advertised ⌘C, and ⌘C did
    /// nothing. A `keyEquivalent` on a status-bar menu is only offered the
    /// keystroke while that menu is open — by which point you are already holding
    /// the mouse over the item — and Kalamos is `.accessory`, so its main menu
    /// never owns the menu bar to catch it either. Nothing was broken, no test
    /// failed, no build complained: the glyph was simply a promise with nothing
    /// behind it, and it survived every commit since the first one.
    ///
    /// Two ways to keep the promise, and this accepts both. Either the key is one
    /// of the global Control+Option shortcuts the event tap catches in any app, or
    /// it is mirrored in the main menu, which does get the keystroke for as long as
    /// a window of ours is key (⌘, and ⌘Q while Preferences is open).
    @Test func everyMenuShortcutIsReal() throws {
        guard let delegate = try Self.swiftFiles().first(where: { $0.name == "AppDelegate.swift" })
        else { throw Failure.noSources }

        func body(of function: String, upTo next: String) throws -> Substring {
            guard let start = delegate.text.range(of: function),
                  let end = delegate.text.range(of: next, range: start.upperBound..<delegate.text.endIndex)
            else { throw Failure.noSources }
            return delegate.text[start.upperBound..<end.lowerBound]
        }

        let statusMenu = try body(of: "private func setupMenuBar()", upTo: "private func triggerHint()")
        let mainMenu = try body(of: "private func setupMainMenu()", upTo: "// MARK: Menu bar")

        /// Every `keyEquivalent: "x"` in a chunk of source, empty ones dropped.
        func keys(in source: Substring) -> [String] {
            source.components(separatedBy: "keyEquivalent: \"")
                .dropFirst()
                .compactMap { $0.first.map(String.init) }
                .filter { $0 != "\"" }
        }

        let global = Set(HotkeyManager.controlOptionShortcuts.values)
        let mirrored = Set(keys(in: mainMenu))
        #expect(!mirrored.isEmpty, "expected to find the main menu's key equivalents")

        let advertised = keys(in: statusMenu)
        #expect(advertised.count >= 4, "expected to find the status menu's key equivalents")

        for key in advertised {
            #expect(global.contains(key) || mirrored.contains(key),
                    "the status menu prints a shortcut for \"\(key)\" that nothing listens for")
        }

        // And a global one must say ⌃⌥ rather than the ⌘ macOS assumes: an item
        // that registers ⌃⌥C globally while printing ⌘C is the same lie, told
        // one layer down.
        for key in Set(advertised).intersection(global).subtracting(mirrored) {
            guard let item = statusMenu.range(of: "keyEquivalent: \"\(key)\"") else { continue }
            let after = statusMenu[item.upperBound...].prefix(240)
            #expect(after.contains("keyEquivalentModifierMask = [.control, .option]"),
                    "the status menu prints ⌘\(key.uppercased()) for a ⌃⌥ shortcut")
        }
    }

    // MARK: ISC-107 — the buffer cache keeps its ceiling

    /// The cap on MLX's Metal buffer cache must not disappear in a refactor.
    ///
    /// Its absence is invisible for hours and then costs 8 GB: the cache defaults
    /// to the memory limit (35 GB on this Mac) and grows all day, because
    /// dictations of different lengths keep asking for buffers of different
    /// sizes. Nothing in a test run, a build, or a fresh-start memory reading
    /// would show it missing.
    @Test func theBufferCacheStaysCapped() throws {
        guard let engine = try Self.swiftFiles().first(where: { $0.name == "MLXEngine.swift" })
        else { throw Failure.noSources }
        #expect(engine.text.contains("set(cacheLimit:"),
                "MLXEngine no longer caps the Metal buffer cache")
        // Zero would not cap the cache — it would switch it off, and every
        // generation would re-pay for every allocation.
        #expect(!engine.text.contains("set(cacheLimit: 0)"))
    }

    // MARK: ISC-94 — the interface is written in the language he chose

    /// No user-visible menu title may be an English string literal: they all go
    /// through `L.t`, or the menu stays English whatever the setting says.
    @Test func noHardcodedMenuTitles() throws {
        guard let delegate = try Self.swiftFiles().first(where: { $0.name == "AppDelegate.swift" })
        else { throw Failure.noSources }
        for (number, line) in delegate.text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            // Only a literal typed at the call site can be untranslated. A title
            // that arrives as a variable was written somewhere else — the helper
            // that builds the Edit menu, the trigger hint, a transcript — and
            // flagging those would be flagging the wrong line.
            guard line.contains("title: \"") || line.contains("withTitle: \"") else { continue }
            let localized = line.contains("L.t(") || line.contains("\"OK\"")
            #expect(localized, "AppDelegate.swift:\(number + 1) has an untranslated title")
        }
    }
}
