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

    /// Only ever set by `--scatta --altezza=<punti>`.
    ///
    /// The window is 560 points tall and several sections are longer than that,
    /// so the probe could photograph their first screen and nothing else — which
    /// is how the Edit Mode row went unseen while being redesigned. A taller
    /// window puts the whole section in one picture.
    nonisolated(unsafe) static var probeHeight: CGFloat?

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
                    // Applying a new interface language has to change the words
                    // on THIS page, not only on the next one you open.
                    //
                    // Every string here comes from `L.t(…)`, read once while a
                    // section's body is built. Three of the four sections take
                    // only the draft, so when `uiLanguage` changes nothing about
                    // their inputs changed and SwiftUI correctly declines to
                    // rebuild them: the page keeps the old language until you
                    // leave it and come back. Real use hit exactly that on
                    // Advanced, which is where the language control lives.
                    //
                    // Keying the section on the language rebuilds it. The cost is
                    // that a half-typed word in the vocabulary field is lost when
                    // you switch language, which happens roughly never.
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A fresh scroll view per section, and that is the whole point.
                //
                // One scroll view kept ONE offset: scroll to the bottom of
                // Dictation, click Cleanup, and Cleanup opened at the bottom —
                // of a page you had never scrolled. The content had changed
                // underneath while the scroll position had not, so where you
                // landed depended on how far down you happened to be in the
                // section before. Reported 2026-08-02.
                //
                // The identity carries the language too, which is what the inner
                // `.id` used to do alone: every string on this page comes from
                // `L.t(…)` read while the body is built, and three of the four
                // sections take only the draft — so on a language change nothing
                // about their inputs changed, SwiftUI correctly declined to
                // rebuild them, and the page kept the old language until you left
                // it and came back. Real use hit exactly that on Advanced, which
                // is where the language control lives.
                .id("\(section.rawValue)/\(state.uiLanguage.rawValue)")
                footer
            }
            .background(Theme.paper)
        }
        .frame(width: 780, height: Self.probeHeight ?? 560)
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
        // Nine, not fourteen. The bar carries one short line and two buttons and
        // was taking the height of a section — it is a footer, and a footer that
        // competes with the content for vertical space is stealing it from the
        // pane that has something to say. (2026-08-01.)
        .padding(.vertical, 9)
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
    /// A switch that turns the WHOLE row on, sitting beside the description.
    ///
    /// Edit Mode used to carry a separate line reading "On" with its own switch
    /// underneath its own explanation — a label that says nothing next to a
    /// paragraph that already said it. When the row itself is the thing being
    /// switched, the switch belongs on the row (reported 2026-08-01).
    var toggle: Binding<Bool>? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
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
                }
                if let toggle {
                    Spacer(minLength: 12)
                    Toggle("", isOn: toggle)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.pen)
                }
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
    /// Roughly what fits on a chip a quarter of the pane wide. "Right Command"
    /// (13) fits; "Premuto o doppio tocco" (22) did not, and said so by
    /// truncating itself in the middle of a word.
    static var charactersInAQuarterPane: Int { 14 }

    let options: [(value: Value, label: String, note: String)]
    let isOn: (Value) -> Bool
    let pick: (Value) -> Void

    /// How many columns this row gets. A plain function so the rule can be
    /// checked without a renderer — the failure it prevents (a label truncated
    /// mid-word) is invisible to every other kind of test.
    static func columnCount(labels: [String], hasNotes: Bool) -> Int {
        guard !hasNotes else { return 2 }
        let longest = labels.map(\.count).max() ?? 0
        return longest > charactersInAQuarterPane ? 2 : min(labels.count, 4)
    }

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
        // Rows whose chips carry a second line get TWO columns, not a flow.
        //
        // Flowing, each card takes the width of its own text: two engines with
        // notes of different lengths came out at two different sizes and on two
        // different lines, which is what the row is least able to afford —
        // a picker whose options are not the same shape reads as a list of
        // unrelated things rather than as a choice between comparable ones.
        // (Reported with a screenshot, 2026-08-01.) Half the pane is wide enough
        // for "~4,3 GB · default", which a quarter was not.
        // Four columns was a ceiling, not a quota, and read as one: three
        // languages sat in three quarters of the pane with a hole where the
        // fourth would have been, which looks abandoned rather than aligned
        // (reported with a screenshot, 2026-08-01). A row narrower than the
        // ceiling now fills the width it has; rows of four still agree with
        // each other, which is what the ceiling was for.
        //
        // And four columns only while the words FIT in a quarter of the pane. A
        // quarter holds about fourteen characters; "Premuto o doppio tocco" is
        // twenty-two, and it came out as "Premuto o doppio…" — a choice you
        // cannot read is not a choice (reported with a screenshot, 2026-08-02).
        // A long row drops to two columns, which is the shape the same question
        // already has in setup, so the two do not disagree either.
        //
        // Counting characters is a crude stand-in for measuring text, and it is
        // the right crudeness here: it is deterministic, it is testable without a
        // renderer, and being wrong costs one row a wider column.
        let columns = Self.columnCount(labels: options.map(\.label),
                                       hasNotes: options.contains { !$0.note.isEmpty })
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
            alignment: .leading, spacing: 8
        ) {
            chips
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
                .padding(.vertical, 5.5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(filled ? Theme.pen : Theme.penWash))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// The one text-field shape in the window.
///
/// It was a private helper on the vocabulary section, which was fine until a
/// second place needed a field. Two copies of a control drift — a corner radius
/// here, a border weight there — and the drift is invisible until the two are on
/// screen at the same time.
struct PrefField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.font(12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1.5))
            .frame(maxWidth: 190)
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
