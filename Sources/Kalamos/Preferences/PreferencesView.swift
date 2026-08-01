import SwiftUI

/// The side effects a setting needs beyond being written down.
///
/// Same contract as `OnboardingActions`, and for the same reason: changing the
/// trigger key means tearing down and re-registering a global event tap, and
/// changing a model means telling the engine that holds it. Preferences asks the
/// AppDelegate to do those things rather than reaching for its objects, so the
/// two screens cannot drift apart from each other or from the menu.
struct PreferencesActions {
    /// Hand over a whole draft. One call, one writer: the delegate compares it
    /// with what is live and does only what actually changed — re-registering the
    /// event tap costs a teardown, and swapping a model costs a load.
    var apply: (SettingsDraft) -> Void
    var isLaunchAtLogin: () -> Bool
    var showDiagnostics: () -> Void
    var rerunOnboarding: () -> Void
}

/// Everything that used to be a submenu.
///
/// The menu bar had grown three levels deep — Cleanup ▸ AI Model ▸ a list, Speech
/// & Language ▸ Vocabulary ▸ a list — and a setting you can only reach by holding
/// a mouse still through two hover-open animations is a setting you stop
/// changing. The menu keeps what you do often; what you *decide* lives here.
struct PreferencesView: View {
    @ObservedObject var state: AppState
    let actions: PreferencesActions

    @State private var section: Section = .dictation
    /// What the window is editing, and what is actually live. The difference
    /// between the two IS the "unapplied changes" state — nothing else tracks it.
    @State private var draft: SettingsDraft
    @State private var applied: SettingsDraft
    @State private var justApplied = false

    /// `openAt` exists for the `--scatta` probe: the picture has to be OF the
    /// screen in question, and every section but the first was unphotographable
    /// while the starting one was hardcoded. It is not reachable from the UI —
    /// opening Preferences by hand still lands on Dictation.
    init(state: AppState, actions: PreferencesActions, openAt: Section = .dictation) {
        self.state = state
        self.actions = actions
        _section = State(initialValue: openAt)
        let start = SettingsDraft(state: state, launchAtLogin: actions.isLaunchAtLogin())
        _draft = State(initialValue: start)
        _applied = State(initialValue: start)
    }

    enum Section: String, CaseIterable, Identifiable {
        case dictation, cleanup, words, advanced
        var id: String { rawValue }

        @MainActor var title: String {
            switch self {
            case .dictation: return L.t("Dettatura", "Dictation", "Dictée")
            case .cleanup:   return L.t("Pulizia", "Cleanup", "Nettoyage")
            case .words:     return L.t("Vocabolario e correzioni", "Words & corrections",
                                        "Vocabulaire et corrections")
            case .advanced:  return L.t("Avanzate", "Advanced", "Avancé")
            }
        }

        var symbol: String {
            switch self {
            case .dictation: return "mic"
            case .cleanup:   return "wand.and.sparkles"
            case .words:     return "character.book.closed"
            case .advanced:  return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch section {
                        case .dictation: DictationSection(draft: $draft)
                        case .cleanup:   CleanupSection(draft: $draft, state: state)
                        case .words:     WordsSection()
                        case .advanced:  AdvancedSection(draft: $draft, actions: actions)
                        }
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .background(Theme.paper)
        }
        .frame(width: 780, height: 560)
        .background(Theme.paper)
    }

    /// The bar that says whether what you see is what the app is doing.
    ///
    /// Otium learned this the hard way and it is copied deliberately: "Applica"
    /// that saves in silence leaves you with no way to know it worked, and a
    /// window with pending edits and no sign of them is a window that lies. So
    /// there are two states and both are visible — how many settings are waiting,
    /// and a confirmation once they are not.
    private var footer: some View {
        let pending = draft.changeCount(from: applied)
        return HStack(spacing: 10) {
            if pending > 0 {
                Text(pending == 1
                     ? L.t("1 modifica non applicata", "1 unapplied change", "1 modification non appliquée")
                     : L.t("\(pending) modifiche non applicate", "\(pending) unapplied changes",
                           "\(pending) modifications non appliquées"))
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.pen)
            } else if justApplied {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    Text(L.t("Applicate", "Applied", "Appliquées")).font(Theme.font(12, .medium))
                }
                .foregroundStyle(Theme.pen)
            } else {
                Text(L.t("Tutto applicato", "Everything applied", "Tout est appliqué"))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.inkFaded)
            }

            Spacer(minLength: 8)

            if pending > 0 {
                PrefButton(title: L.t("Annulla", "Discard", "Annuler")) {
                    draft = applied
                }
            }
            PrefButton(title: L.t("Applica le modifiche", "Apply changes",
                                  "Appliquer les modifications"),
                       filled: pending > 0) {
                guard pending > 0 else { return }
                actions.apply(draft)
                applied = draft
                justApplied = true
            }
            .opacity(pending > 0 ? 1 : 0.45)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.paperEdge)
        .overlay(Divider(), alignment: .top)
        .onChange(of: draft) { justApplied = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases) { item in
                Button { section = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.title)
                            .font(Theme.font(13, section == item ? .semibold : .regular))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? Theme.pen : Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    // The filled shape is inside the label, and the hit shape is
                    // the whole rectangle — a row that highlights where you cannot
                    // click reads as a broken app.
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(section == item ? Theme.penWash : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 210, alignment: .topLeading)
        .background(Theme.paperEdge)
    }
}

// MARK: - Shared pieces

/// A titled block with an explanation under it. Every setting in this window is
/// one of these, so the page has one rhythm instead of four.
struct PrefRow<Content: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.font(13.5, .semibold))
                .foregroundStyle(Theme.ink)
            if !note.isEmpty {
                Text(note)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }
}

/// One choice among a few, laid out as chips that wrap.
///
/// A `Picker` would have been fewer lines and the wrong material: the menu style
/// hides every option but the chosen one behind a click, which is exactly the
/// "you have to go looking" problem this window exists to remove.
struct ChipRow<Value: Hashable>: View {
    let options: [(value: Value, label: String, note: String)]
    let isOn: (Value) -> Bool
    let pick: (Value) -> Void

    var body: some View {
        // A note on some chips and not others makes those chips taller than
        // their neighbours and stretches the whole row — found in Preferences on
        // 2026-07-31, on the one row out of ten that mixed them. Either every
        // chip in a row carries a second line or none does; anything that needs
        // saying about one option goes in a line under the row, where it can
        // describe all of them without moving the geometry.
        assert(options.allSatisfy { $0.note.isEmpty } || options.allSatisfy { !$0.note.isEmpty },
               "a chip row must not mix chips with and without a note")
        // Four columns, always, when the chips are plain words.
        //
        // Sized to their own text they line up with nothing: four rows of four
        // choices put sixteen chips at sixteen different places, and the eye
        // reads the raggedness before it reads the words. On a grid the columns
        // agree across rows, a row of three simply leaves the fourth cell empty,
        // and a row of five wraps onto the same column it started from.
        //
        // Rows whose chips carry a second line — the model pickers — keep the
        // flowing layout: those are cards, not words, and squeezing them into a
        // quarter of the pane wraps "~4.3 GB · default" onto three lines.
        let plainWords = options.allSatisfy { $0.note.isEmpty }
        return Group {
            if plainWords {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                          alignment: .leading, spacing: 8) {
                    chips
                }
            } else {
                FlowLayout(spacing: 8) { chips }
            }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(options, id: \.value) { option in
                // Everything centred, including the two-line cards: tried both
                // ways in front of him and centred won for those too.
                //
                // The heights went the other way round from what I guessed. The
                // plain rows — the ones you use every day — wanted MORE room, and
                // the model cards read better tight, because their second line
                // already gives them height.
                let card = !option.note.isEmpty
                Button { pick(option.value) } label: {
                    VStack(alignment: .center, spacing: card ? 3 : 2) {
                        // The chosen chip is written in ink that is still wet.
                        // A 13%-blue wash and a border alone read as grey at a
                        // glance — seen on the first build, where the selection
                        // was there and did not announce itself.
                        Text(option.label)
                            .font(Theme.font(12.5, isOn(option.value) ? .semibold : .medium))
                            .foregroundStyle(isOn(option.value) ? Theme.pen : Theme.ink)
                            // One line, always. "Right Command" is the longest
                            // label in the window and wrapping it made its chip
                            // taller than the three beside it — the raggedness
                            // moves from the widths to the heights. A few percent
                            // of shrink is invisible; a two-line chip is not.
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        if !option.note.isEmpty {
                            Text(option.note)
                                .font(Theme.font(10.5))
                                .foregroundStyle(Theme.inkFaded)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, card ? 8 : 13)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(isOn(option.value) ? Theme.penWash : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isOn(option.value) ? Theme.pen : Theme.rule, lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn(option.value) ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// A setting with a switch, label left, switch on the right margin.
///
/// Every one of these was a bare `Toggle` whose switch sat flush against the end
/// of its own label, so four rows put four switches at four different places —
/// reported on 2026-07-31 with a screenshot that makes it obvious. The first
/// attempt at a fix, `.frame(maxWidth: .infinity)` on the Toggle, made it worse:
/// it stretched the LABEL and dragged it right. The switch only reaches the
/// margin if the row is built as label + spacer + switch, which is what this is
/// — written once so the next setting cannot be added crooked.
struct PrefToggle: View {
    let title: String
    var note: String = ""
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // Each switch says what it does. Four labels and one paragraph
                // underneath explaining all four meant reading the paragraph and
                // then matching sentences back to switches — "metti uno spazio
                // prima di cosa?" is the question that proved it.
                if !note.isEmpty {
                    Text(note)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.pen)
        }
        // Flush to the right edge of the pane. A capped column looked tidier to
        // me and wrong to him: the switches ended up floating in the middle with
        // empty pane to their right.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A plain text button in the app's own ink.
struct PrefButton: View {
    let title: String
    var filled = false
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(Theme.font(12.5, .medium))
                .foregroundStyle(filled ? Theme.paper : Theme.pen)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(filled ? Theme.pen : Theme.penWash))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// Chips that wrap to the next line instead of running off the window.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
