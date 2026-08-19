import AppKit
import Combine
import SwiftUI

/// Where the wave sits while you dictate. **Two positions, and the second one is
/// not really a place — it is wherever you put it.**
///
/// `notch` hangs the shell off the physical top edge of the screen, so it merges
/// with the notch on a MacBook. `bubble` is a free island you drag where you
/// want it; dragging IS how the position gets chosen, which is why there is no
/// third option called "where I dragged it". An option that arms itself is not
/// an option you pick.
/// **Dove vive l'isoletta**: due ancore con un nome, più la libertà di non
/// averne una.
///
/// Un nome invece di due numeri, e il motivo non è l'ordine ma la
/// sopravvivenza: un'ancora si ricalcola dalla geometria dello schermo che c'è
/// adesso, delle coordinate crude descrivono lo schermo di ieri e al primo
/// monitor diverso mettono la pillola dove non si vede. `libera` resta perché
/// «non ha ancora proprio perché è libera» (sua parola, 19/08), ed è il solo
/// modo che porta ancora dei numeri con sé — per questo è anche il solo che ha
/// bisogno di essere riportato dentro l'area visibile.
enum WavePosition: String, CaseIterable, Codable {
    case notch
    case bassoCentro
    case libera

    /// Le due posizioni che disegnano la **pillola**. Il notch è l'unica banda,
    /// e scritto così invece che come `!= .notch` sparso in giro: il giorno che
    /// arriva una quarta posizione, questa riga è l'unico posto da guardare.
    var disegnaPillola: Bool { self != .notch }

    /// Il solo modo che si porta dietro delle coordinate.
    var salvaCoordinate: Bool { self == .libera }
}

/// The tint persisted as `"r g b a"` in UserDefaults — readable, checkable with
/// `defaults read app.kalamos.mac waveTint`, no binary archive in the middle.
///
/// A colour stored as an archived `NSColor` is a blob you cannot read, cannot
/// diff, and cannot fix by hand when it goes wrong. Four numbers can be all
/// three.
enum WaveTint {
    /// The pen of the family, #2F5C8A — the same accent as `Theme.pen`.
    static let defaultWave = "0.184 0.361 0.541 1.0"
    /// The ink of the family, #1E2B3A.
    static let defaultShell = "0.118 0.169 0.227 1.0"

    static func color(from string: String) -> Color {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { return color(from: defaultWave) }
        return Color(red: parts[0], green: parts[1], blue: parts[2], opacity: parts[3])
    }

    static func string(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.3f %.3f %.3f %.3f",
                      ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }
}

/// The two rows of pills. Not the system colour panel: a colour you have to open
/// a picker for is a colour you choose once and never adjust, and the picker
/// arrives wearing somebody else's livery (MacAppRules §2).
enum WavePalette {
    /// Tints for the wave itself — the family pen first, then live colours.
    static let wave: [(name: String, color: Color)] = [
        ("Penna", Color(hex: 0x2F5C8A)),
        ("Rosso", Color(hex: 0xD94033)),
        ("Arancio", Color(hex: 0xE27E42)),
        ("Ocra", Color(hex: 0xDAA520)),
        ("Salvia", Color(hex: 0x528D65)),
        ("Acquamarina", Color(hex: 0x2E969C)),
        ("Viola", Color(hex: 0x7A51A9)),
        ("Rosa", Color(hex: 0xCD5C8A)),
        ("Perla", Color(hex: 0xE5E4DF)),
    ]

    /// Grounds for the shell: dark, because the wave is additive light and a
    /// pale shell simply eats it.
    static let shell: [(name: String, color: Color)] = [
        ("Inchiostro", Color(hex: 0x1E2B3A)),
        ("Nero", Color(hex: 0x050508)),
        ("Petrolio", Color(hex: 0x13323A)),
        ("Bosco", Color(hex: 0x163223)),
        ("Melanzana", Color(hex: 0x2D1B3E)),
        ("Borgogna", Color(hex: 0x421619)),
        ("Grafite", Color(hex: 0x28282D)),
    ]
}

/// The free island, as numbers.
///
/// **A small PILL, and it stopped being a circle on 2026-08-16** — his words, from
/// the field: «non mi piace la sfera, fai una sorta di pillola piccolina, non un
/// rettangolo grande… non grande come quello del notch, decisamente più piccolo».
/// The sphere was wrong for a reason worth writing down rather than a taste: a
/// wave is a horizontal object, and a circle gives it its width only in the middle
/// — the shape was fighting the thing inside it. A pill is the same argument the
/// notch band makes (a wave wants a long, low room), at a size that belongs on a
/// desktop instead of on a piece of hardware.
///
/// The wave's box is measured as FRACTIONS of the pill rather than in points of
/// its own. A second independent number would be a second place to change, and
/// the first day somebody changed only one of the two the crests would start
/// dying against the rounded ends — the defect this arrangement exists to make
/// impossible. `theWaveNeverDiesAgainstTheRoundedEnd` is the test that holds the
/// ratios to it.
enum BubbleGeometry {
    /// Present without taking the desktop over, and unmistakably smaller than the
    /// notch island (400×128). Judged on the photograph and not on the number:
    /// at 150×40 it reads as a small badge that says "it is listening", and is
    /// shorter than a notification is tall.
    static let width: CGFloat = 150
    static let height: CGFloat = 40

    static var size: CGSize { CGSize(width: width, height: height) }

    /// A pill is a rectangle capped by two half-circles of this radius.
    static var radius: CGFloat { height / 2 }

    /// The wave's box, as fractions of the pill.
    ///
    /// **The width is the whole width**, and that is the point rather than an
    /// oversight: the thread has to run from one end to the other («da un estremo
    /// all'altro, non in mezzo e basta»), so the box cannot be inset to keep the
    /// crests clear of the ends. What keeps them clear is `profile`, which lowers
    /// the ceiling where the pill closes instead of moving the wave away from it.
    static let waveWidthRatio: CGFloat = 1.0
    static let waveHeightRatio: CGFloat = 0.78

    /// How much room the drawing has to leave under the edge, beyond the wave
    /// path itself: the ribbons are drawn twice, once blurred, and the halo is
    /// what would touch the edge first. **It must cover the blur radius in
    /// `WaveformView`** — a guard in `WaveIslandTests` fails if that number moves
    /// and this one does not follow.
    static let glowMargin: CGFloat = 4

    static func waveSize(in shell: CGSize) -> CGSize {
        CGSize(width: shell.width * waveWidthRatio, height: shell.height * waveHeightRatio)
    }

    /// Half the height of the pill at a horizontal distance `dx` from its centre
    /// — the ceiling the wave has to stay under.
    ///
    /// Flat across the middle and falling only on the two caps, which is exactly
    /// why a pill suits a wave better than a circle did: on a circle this
    /// number starts dropping immediately either side of the axis, so most of the
    /// island could not hold a crest.
    static func halfHeight(atDistance dx: CGFloat, in shell: CGSize) -> CGFloat {
        let r = shell.height / 2
        let straight = max(0, shell.width / 2 - r)
        let into = abs(dx) - straight
        guard into > 0 else { return r }
        let inside = r * r - into * into
        return inside <= 0 ? 0 : inside.squareRoot()
    }

    /// **The pill's own shape, handed to the drawing so the drawing cannot spill
    /// out of it.**
    ///
    /// Returns, for `u` from −1 to 1 across the wave's box, the fraction of its
    /// half-height the wave may use. One in the straight middle; tapering to
    /// nothing on the caps, with `glowMargin` already subtracted so the halo is
    /// inside the promise rather than beside it.
    ///
    /// This is the difference between a guarantee and a watch: before, the wave
    /// was laid in a smaller box and a test checked that the two never met. Now
    /// the container states its geometry and the drawing obeys it, so the crest
    /// that reaches the edge is a crest that has already been made short enough.
    static func profile(box: CGSize, in shell: CGSize) -> @Sendable (Double) -> Double {
        let drawnHalf = box.height / 2 * CGFloat(WaveCanvas.riempimento)
        let halfWidth = box.width / 2
        guard drawnHalf > 0 else { return { _ in 0 } }
        return { u in
            let ceiling = halfHeight(atDistance: CGFloat(abs(u)) * halfWidth, in: shell)
            let allowed = max(0, ceiling - glowMargin)
            return min(1, Double(allowed / drawnHalf))
        }
    }
}

/// The island's controller: it owns the panel, the clock that samples the
/// microphone, and the smoothed level the wave is drawn from.
///
/// **Nothing here opens an audio resource.** The level comes from the buffers
/// `AudioRecorder` already has in hand, sampled through a closure — that is the
/// rule paid for with the headphone crashes of 2026-08-14 (MacAppRules §0.3): a
/// second tap on the microphone, only to draw a picture, would be a second
/// CoreAudio client to be caught by the next device change.
///
/// The panel and the clock live for the duration of the dictation and not for
/// the duration of the app, for the same reason: between two dictations there is
/// nothing on screen and nothing ticking.
@MainActor
final class WaveIsland: ObservableObject {
    static let shared = WaveIsland()

    /// 0…1, already smoothed: the **speaking intensity**, slow on purpose. This
    /// is the only thing that sets the wave's height.
    @Published private(set) var level: Double = 0

    /// −1…1: how far the instantaneous loudness sits above or below that slow
    /// intensity, i.e. the syllables. **It never reaches the height** — the
    /// drawing turns it into a nudge of the crests' travelling speed, so what a
    /// syllable produces is horizontal movement rather than a heave.
    @Published private(set) var detail: Double = 0

    /// Whether the island has arrived. **The whole animation is this one flag**:
    /// the view derives its offset, its opacity and its scale from it through
    /// `IslandEntrance`, so entering and leaving cannot drift apart into two
    /// pieces of choreography that disagree.
    @Published private(set) var shown: Bool = false

    /// **Dove la sua mano l'ha lasciata, per questa dettatura e basta.**
    ///
    /// È la seconda riga del contratto del rilascio resa visibile: lasciata
    /// lontano da ogni ancora con un'ancora scelta nelle Preferenze, l'isola
    /// resta lì — e prende la forma della pillola, che è la cosa che gli piace
    /// («partendo dal notch e trascinando, l'isola diventa pillola») — ma non si
    /// scrive niente sul disco, e la dettatura dopo riparte da dove dice
    /// l'impostazione.
    ///
    /// Vive qui e non in `AppState` proprio per questo: `AppState` è ciò che
    /// sopravvive alla chiusura, e questo non deve sopravvivere nemmeno alla
    /// dettatura. `hide()` lo azzera.
    @Published var posizioneEffimera: WavePosition?

    /// **Dove sta la trasformazione, mentre la mano si muove**: 0 è la banda del
    /// notch, 1 è la pillola, e in mezzo c'è la forma interpolata.
    ///
    /// `nil` fuori dal gesto, e allora comanda la posizione discreta. Vive qui e
    /// non in `AppState` perché è un valore di scena: non deve sopravvivere né
    /// alla dettatura né alla chiusura dell'app.
    @Published var progressoForma: Double?

    private let state = AppState.shared
    private var panel: IslandPanel?

    /// La finestra viva, in sola lettura, **per `--sonda-spazi`**.
    ///
    /// Esposta e non ricostruita: `SondaPannello` esiste proprio perché una
    /// costante giusta e un `init` che non la applica sono indistinguibili dal
    /// sorgente, e una sonda che si fabbricasse un pannello suo per misurarlo
    /// misurerebbe il pannello che si è fabbricata.
    var pannelloVivo: IslandPanel? { panel }
    private var clock: Timer?
    /// The two envelopes: the slow one is the height, the fast one exists only to
    /// be subtracted from it.
    private var lento = Inviluppo()
    private var veloce = Inviluppo()
    /// Which sample of the written-down profile comes next. Only the profile
    /// probe uses it; the microphone has no index to keep.
    private var campioneSonda = 0
    private var watchers = Set<AnyCancellable>()
    /// The close scheduled for the end of the exit animation. Held so that a
    /// dictation starting again mid-exit cancels it instead of having the island
    /// vanish half a second after it came back.
    private var closing: DispatchWorkItem?
    /// Held as a property, not captured by the clock's closure: a `Timer` body is
    /// `@Sendable`, and a plain closure crossing into it is one more thing the
    /// compiler has to be told about for no gain. Reached through `self`, it is
    /// simply main-actor state like everything else here.
    private var sampling: (() -> Double)?

    /// Thirty samples a second. The wave itself is redrawn by `TimelineView` at
    /// display rate; this only has to keep up with a voice, and a voice does not
    /// change loudness faster than that.
    nonisolated static let samplesPerSecond: Double = 30

    // MARK: - The timing of the transition, as numbers
    //
    // Written as numbers rather than straight into an `Animation`, because an
    // `Animation` is opaque: nothing can read back how long it lasts or what
    // shape it draws. The two relations that have to hold — the panel is taken
    // off screen only AFTER the exit has finished drawing, and the entrance is
    // the exit backwards — are then facts a test can check instead of sentences
    // in a comment.

    /// **How long the island takes to arrive, and it is the same number as
    /// leaving.** One duration and not two, because on 2026-08-17 he asked for
    /// the arrival to be the departure run backwards — «si deve aprire in
    /// maniera opposta a come si chiude però con lo stesso tipo di animazione» —
    /// and two durations are the first way that promise breaks in silence.
    ///
    /// The value is the EXIT's, 0.24, kept exactly because the exit is the half
    /// he said was right. The arrival used to take 0.40 on a spring, and losing
    /// those 160 ms is the price of the symmetry he asked for, not an oversight:
    /// if the whole gesture ever wants to be slower, this is the one knob, and
    /// both ends move together by construction.
    nonisolated static let durataTransizione: TimeInterval = 0.24
    /// The old name, kept because `closeDelay` is a statement about the EXIT and
    /// reading `durataTransizione` there would hide which end is being talked
    /// about.
    nonisolated static var exitDuration: TimeInterval { durataTransizione }
    /// When the window may be taken off screen. Strictly after `exitDuration`, or
    /// the last frames of the exit would be cut off by the window disappearing —
    /// the same abrupt thing at the other end.
    nonisolated static let closeDelay: TimeInterval = 0.30
    /// How many run-loop turns to wait for the window to be really on screen
    /// before animating anyway. `orderFrontRegardless` is a request, not a fact,
    /// and an island that stayed invisible because the request was slow would be
    /// a worse failure than one that skips its animation.
    nonisolated static let entranceAttempts = 10

    nonisolated static var entranceAnimation: Animation { IslandEntrance.animation(entrando: true) }
    nonisolated static var exitAnimation: Animation { IslandEntrance.animation(entrando: false) }

    private init() {}

    /// Show the island and start following the microphone.
    ///
    /// `sampling` returns the raw RMS of the audio that has just arrived. Passing
    /// it in rather than reaching for the recorder keeps this class ignorant of
    /// where the sound comes from, which is what makes the smoothing testable
    /// without an audio device.
    func show(sampling: @escaping () -> Double) {
        guard state.waveEnabled else { return }
        azzeraInviluppi()
        self.sampling = sampling
        present()
        clock = Timer.scheduledTimer(withTimeInterval: 1 / Self.samplesPerSecond,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let source = self.sampling else { return }
                self.feed(rms: source())
            }
        }
    }

    /// The dictation ended: the island leaves the way it came, and everything it
    /// held goes with it once the animation is over.
    ///
    /// Called on **every** status that is not `.listening`, so it runs several
    /// times per dictation: the guard in `dismiss()` is what keeps the second call
    /// from restarting an exit that is already running.
    func hide() {
        clock?.invalidate()
        clock = nil
        sampling = nil
        // Dove la mano l'aveva lasciata muore con la dettatura, che è tutto il
        // significato di «vale per questa registrazione».
        posizioneEffimera = nil
        progressoForma = nil
        dismiss()
    }

    /// The shape to draw regardless of what is saved. **Only ever set by
    /// `--scatta --isola=<notch|bolla>`.**
    ///
    /// Same reason as `PreferencesView.probeHeight`: a probe that had to write a
    /// setting in order to photograph it would leave the app configured by
    /// whoever took the last screenshot.
    nonisolated(unsafe) static var probePosition: WavePosition?

    /// **La posizione che vale adesso**, e l'ordine è l'unica cosa da ricordare:
    /// la sonda scavalca tutto (deve poter fotografare senza riconfigurare la sua
    /// Kalamos), poi c'è dove l'ha lasciata la mano in questa dettatura, e in
    /// fondo l'impostazione, che è la sola a sopravvivere.
    ///
    /// Scritta una volta sola perché i quattro punti che la risolvevano a mano
    /// erano quattro occasioni di dimenticarne uno, e un pannello che si dimensiona
    /// su una posizione e si disegna su un'altra è invisibile nel sorgente.
    @MainActor
    static func posizioneCorrente(_ state: AppState) -> WavePosition {
        probePosition ?? shared.posizioneEffimera ?? state.wavePosition
    }

    /// **Il progresso che vale adesso**, e non c'è nessun ramo: fuori dal gesto la
    /// posizione discreta è semplicemente il progresso agli estremi. Un `if` qui
    /// sarebbe la stessa cosa scritta due volte, e prima o poi le due divergono.
    @MainActor
    static func progressoCorrente(_ state: AppState) -> Double {
        shared.progressoForma ?? (posizioneCorrente(state) == .notch ? 0 : 1)
    }

    /// Whether to draw the bubble behind the wave, regardless of what is saved.
    /// **Only ever set by `--isola --senza-bolla`.**
    ///
    /// Same reason as `probePosition`, and here it is not a nicety: the switch is
    /// the one state where nothing at all is painted behind the wave, so it is the
    /// state where "can it still be grabbed" stops being obvious — and a probe that
    /// had to switch his own bubble off in order to photograph it would leave the
    /// app configured by whoever took the last screenshot.
    nonisolated(unsafe) static var probeShell: Bool?

    /// The window level the panel is built with, regardless of
    /// `IslandPanel.livelloPersistente`. **Only ever set by
    /// `--sonda-spazi --livello-isola=<n>`.**
    ///
    /// It exists because «il notch non resta fermo quando cambio pagina» is a
    /// claim about a NUMBER — 25 for `.statusBar`, 1000 for `.screenSaver` — and
    /// the only way to find out which number is right is to sweep them and
    /// measure. Same reason as `probeTaratura`: a sweep that had to edit the
    /// source between runs is a sweep nobody can re-run.
    nonisolated(unsafe) static var probeLivello: NSWindow.Level?

    /// I flag di raggruppamento e il comportamento d'animazione della finestra,
    /// per la spazzata di `--sonda-spazi --variante=<n>`. Stessa ragione di
    /// `probeLivello`: le ipotesi si provano cambiando un parametro, non il file.
    nonisolated(unsafe) static var probeComportamento: NSWindow.CollectionBehavior?
    nonisolated(unsafe) static var probeAnimazione: NSWindow.AnimationBehavior?
    nonisolated(unsafe) static var probeFluttuante: Bool?

    /// Show the island with a level and a place chosen by hand, for
    /// `--scatta --isola` and `--isola-filmato`.
    ///
    /// No clock and no microphone: a probe that had to record audio to take a
    /// picture would be a probe nobody can run while the real app is listening.
    ///
    /// `animated: false` puts it straight into its settled state — that is the
    /// one the photograph is of. `animated: true` runs **the same entrance the
    /// app runs**, not a re-enactment of it: a probe that rewrote the movement in
    /// order to film it would end up filming itself (OperationalLessons,
    /// 2026-08-05).
    func showForProbe(level fixed: Double, position: WavePosition, origin: NSPoint,
                      animated: Bool = false) {
        Self.probePosition = position
        lento = Inviluppo(livello: fixed, tenutaRimasta: 0)
        veloce = Inviluppo(livello: fixed, tenutaRimasta: 0)
        level = fixed
        detail = 0
        let p = IslandPanel(island: self, state: state)
        panel = p
        p.place(at: origin)
        shown = !animated
        p.orderFrontRegardless()
        if animated { scheduleEntrance() }
    }

    /// **The tuning the probe wants instead of the live one.** Only ever set by
    /// `--isola-filmato --taratura=prima`, for the same reason as `probePosition`:
    /// a probe that had to change a setting in order to film a state would leave
    /// the app configured by whoever filmed last.
    ///
    /// It exists so the negative pole of the pumping bench can be produced
    /// without editing the code — see `Taratura.diPrima`.
    nonisolated(unsafe) static var probeTaratura: Taratura?

    /// Show the island and drive it with a **written-down loudness profile**
    /// instead of a microphone or a constant.
    ///
    /// This is the probe for the pumping: a fixed level cannot show it — the
    /// defect only exists while the loudness moves — and a real microphone would
    /// make the film different every time it is shot.
    ///
    /// **It goes through the real chain.** `profilo` returns raw RMS and lands in
    /// the same `feed(rms:)` the microphone lands in, so `normalize` and both
    /// envelopes are the app's, not a copy of them written for the bench
    /// (OperationalLessons, 2026-08-05). The clock ticks at the app's own
    /// `samplesPerSecond`, so a sample index is a real number of seconds.
    func showForProbe(profilo: @escaping @Sendable (Int) -> Double, position: WavePosition,
                      origin: NSPoint, animated: Bool = true) {
        Self.probePosition = position
        azzeraInviluppi()
        let p = IslandPanel(island: self, state: state)
        panel = p
        p.place(at: origin)
        shown = !animated
        p.orderFrontRegardless()
        if animated { scheduleEntrance() }
        campioneSonda = 0
        clock = Timer.scheduledTimer(withTimeInterval: 1 / Self.samplesPerSecond,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let n = self.campioneSonda
                self.campioneSonda += 1
                self.feed(rms: profilo(n))
            }
        }
    }

    /// Send it away again, by the same path as a dictation that ends.
    /// The clock is stopped here and not only in `tearDown`: the profile probe
    /// leaves one ticking, and a level still being fed during the exit would
    /// animate the wave while the island is being drawn away.
    func hideForProbe() {
        clock?.invalidate()
        clock = nil
        dismiss()
    }

    /// Build the panel and keep it in step with the settings while it is up.
    private func present() {
        closing?.cancel()
        closing = nil
        if panel == nil { panel = IslandPanel(island: self, state: state) }
        // A dictation that starts again mid-exit finds the watchers of the
        // previous one still in place, and two sinks on the same setting move the
        // island twice.
        watchers.removeAll()
        // Changing the position in Preferences has to move the island that is on
        // screen NOW, not the next one. Without this the setting looks broken for
        // exactly as long as the current dictation lasts.
        state.$wavePosition
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.place() }
            }
            .store(in: &watchers)
        // And switching the wave OFF has to take the island away now, not at the
        // end of the dictation that happens to be running. A switch whose effect
        // waits is indistinguishable from a switch that does nothing.
        state.$waveEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated { if !on { self?.hide() } }
            }
            .store(in: &watchers)
        // Hidden FIRST, on screen SECOND, animated THIRD, and the order is the
        // whole point. A window that starts its animation before the window
        // server has it composed shows its first frames to nobody and arrives
        // looking like it appeared all at once — which is the defect this is
        // repairing. Same lesson as the paper backdrop of the photo probe:
        // `orderFrontRegardless` is a request, not a fact.
        shown = false
        // `hide()` restituisce i monitor al sistema, e il pannello viene riusato:
        // senza questa riga la pillola si trascinerebbe solo alla PRIMA dettatura.
        panel?.riprendiIlGesto()
        panel?.place()
        panel?.orderFrontRegardless()
        scheduleEntrance()
    }

    /// Wait for the window to really be on screen, then let it in.
    ///
    /// The hop through the run loop is not politeness: it is what gives SwiftUI a
    /// turn to draw the hidden state. Setting `shown` in the same turn the window
    /// is created gives the animation nothing to animate FROM, and the island
    /// snaps into place with the animation formally applied — a bug that looks
    /// exactly like no animation at all.
    private func scheduleEntrance(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !self.shown else { return }
            guard panel.isVisible || attempt >= Self.entranceAttempts else {
                self.scheduleEntrance(attempt: attempt + 1)
                return
            }
            withAnimation(Self.entranceAnimation) { self.shown = true }
        }
    }

    /// Run the exit, and close the window only once it has finished drawing.
    ///
    /// Idempotent on purpose: `hide()` arrives once per status change, and an
    /// exit restarted from its own middle would stutter. The guard on `closing`
    /// is also what guarantees the second half — no window survives between two
    /// dictations, because the close is already scheduled and cannot be pushed
    /// further away by another call.
    private func dismiss() {
        guard panel != nil, closing == nil else { return }
        withAnimation(Self.exitAnimation) { shown = false }
        let work = DispatchWorkItem { [weak self] in self?.tearDown() }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    /// Everything the island held, released — after the last frame, never before.
    private func tearDown() {
        closing = nil
        watchers.removeAll()
        panel?.detach()
        panel?.orderOut(nil)
        panel = nil
        shown = false
        azzeraInviluppi()
    }

    private func azzeraInviluppi() {
        lento = Inviluppo()
        veloce = Inviluppo()
        level = 0
        detail = 0
    }

    /// One sample of microphone through the two envelopes.
    ///
    /// **The two are fed the same target and differ only in their haste**, which
    /// is what makes their distance mean "syllable": the slow one is where the
    /// phrase is, the fast one is where the voice is right now, and the gap
    /// between them is the part of the sound that a phrase does not explain.
    private func feed(rms: Double) {
        let taratura = Self.probeTaratura ?? .viva
        let obiettivo = Self.normalize(rms: rms, con: taratura)
        lento = lento.avanzato(verso: obiettivo, con: taratura)
        veloce = veloce.avanzato(verso: obiettivo, con: .sillabica)
        level = lento.livello
        detail = max(-1, min(1, veloce.livello - lento.livello))
    }

    // MARK: - The arithmetic, kept pure so it can be tested
    //
    // `nonisolated`: functions of their arguments and nothing else, and being
    // main-actor by inheritance would drag the test onto the main actor to do
    // arithmetic.

    /// Raw RMS → 0…1, under a given tuning.
    ///
    /// **The map is deliberately compressive, and that is the whole point.** What
    /// the picture has to say is *speaking / not speaking*, not *loud syllable /
    /// weak syllable*: his close-mic voice lives between about 0.02 and 0.06 RMS,
    /// and a map that spends real height on the difference between those two
    /// draws a wave that heaves with every stressed vowel. Under `.viva` that
    /// whole range draws between 0.77 and 0.91 of full height — a difference you
    /// can measure and hardly see, which is exactly the intent.
    ///
    /// Two pieces, and they answer two different questions. Below `ginocchio` a
    /// curve with an exponent under one climbs fast, so *any* speech is
    /// immediately near the top. Above it a straight line spends the remaining
    /// `1 − quotaGinocchio` on the whole way up to `tetto`, so shouting still
    /// draws more than talking — just not much more.
    ///
    /// The zero point is `AudioRecorder.speechFloor`, deliberately the same
    /// number the recorder and the transcriber already use for "is anybody
    /// speaking" — a third definition of silence in one app is how two of them
    /// end up disagreeing about the same audio.
    nonisolated static func normalize(rms: Double, con taratura: Taratura = .viva) -> Double {
        let floor = Double(AudioRecorder.speechFloor)
        guard rms > floor else { return 0 }
        // The span is measured FROM the floor, not from zero. Dividing by the
        // knee alone leaves the top of the range unreachable by exactly the
        // floor — the wave would top out at 0.986 and never at 1, which is the
        // kind of almost-right nobody notices by looking at it.
        let sotto = min(1, (rms - floor) / max(.leastNormalMagnitude, taratura.ginocchio - floor))
        let base = pow(sotto, taratura.esponente) * taratura.quotaGinocchio
        // A tuning whose ceiling IS its knee has no upper stretch: everything at
        // or above the knee is full. That is the shape the old tuning had, and
        // writing it as a degenerate case rather than a second formula is what
        // lets the probe run both through the same code.
        let sopra = taratura.tetto > taratura.ginocchio
            ? min(1, max(0, (rms - taratura.ginocchio) / (taratura.tetto - taratura.ginocchio)))
            : 1
        return min(1, base + (1 - taratura.quotaGinocchio) * sopra)
    }
}

/// **How loudness becomes height, and with what haste.** One struct rather than
/// five constants scattered through the code.
///
/// It is a struct because the probe has to run the film through the OLD tuning to
/// show that the bench sees the defect at all — the negative pole
/// (OperationalLessons, 2026-07-12). With the numbers written inside the
/// functions the only way to produce that pole would be to edit the code and put
/// it back, which is a proof nobody can re-run.
struct Taratura: Sendable, Equatable {
    /// The RMS at which the wave is as good as full.
    let ginocchio: Double
    /// How much height there is at the knee; the rest is kept for loud voices.
    let quotaGinocchio: Double
    /// The curve below the knee. Under one it compresses, i.e. lifts the quiet.
    let esponente: Double
    /// The RMS of absolute full height.
    let tetto: Double
    /// How much of the remaining distance is climbed per sample.
    let attacco: Double
    /// How much is given back per sample, AFTER the hold has run out.
    let rilascio: Double
    /// How many samples the height stays exactly still before it starts falling.
    let tenuta: Int

    /// **The live tuning — the one his eye judged on 2026-08-16.**
    ///
    /// The numbers, in seconds, at `WaveIsland.samplesPerSecond` = 30: the attack
    /// reaches 95% in about 0.28 s, the hold keeps the height perfectly still for
    /// 0.80 s, and only then does the release take about **1.20 s** to fall away.
    /// A pause therefore takes about **2.0 s** to bring the wave back down to the
    /// quiet line, and **1.37 s** to drop below a quarter of its height.
    ///
    /// Read them, do not trust them: `secondiDiTenuta`, `secondiPerScendere(a:)`
    /// and `coda(fino:)` derive all four from the coefficients, and
    /// `--misura-inviluppo --solo-coda` prints them next to the same figures
    /// counted on the written phrase.
    ///
    /// **The release was 0.15 until 2026-08-17, i.e. a tail of 0.61 s, and he
    /// said it went flat too fast**: «l'isoletta è bellina, mi piace, l'unica cosa
    /// è che si appiattisce troppo rapidamente quando smetto di parlare». At 0.08
    /// the tail is 1.20 s, which reads as dissolving rather than switching off.
    ///
    /// The direction is worth writing down because it is the opposite of the fear
    /// of the day before, when the worry was a wave that stayed up too long. Those
    /// two are not in tension: the HOLD is what keeps the wave up *through a
    /// phrase* and it has not moved, the RELEASE is what happens *after the
    /// speaking stops* and only that was lengthened. The bench still separates
    /// them — criterion 1 measures the hold and is unchanged at 0.94.
    ///
    /// **The hold is the piece that fixes the defect, not the release.** Ordinary
    /// speech has gaps of 100–300 ms between syllables and 300–450 ms between
    /// words; with a plain exponential release, every one of those gaps eats a
    /// fixed *fraction* of the height, so the wave pumps several times a second —
    /// «vibra tanto ed è fastidioso a vedersi». A hold longer than the gaps
    /// removes that entirely: inside a phrase the amplitude does not fall at all,
    /// and it starts falling only when the silence outlasts speech.
    ///
    /// **Why 0.80 s and not the 0.45 s of the longest gap** — this is the part
    /// that was guessed wrong twice, and both times the bench said so before the
    /// eye could. The hold is counted from the last ONSET, and between that onset
    /// and the end of a word gap there are three things, not one: the body of
    /// that last syllable (0.15), the quiet stretch that closes the word (0.15),
    /// and only then the gap itself (0.45). Three quarters of a second, and 0.80
    /// is that with a little margin — a hold sized to the gap alone leaves the
    /// release running for the last few samples of every word, which is a
    /// smaller, slower version of the very defect it was put there to remove.
    static let viva = Taratura(ginocchio: 0.025, quotaGinocchio: 0.86, esponente: 0.40,
                               tetto: 0.12, attacco: 0.30, rilascio: 0.08, tenuta: 24)

    /// **The tuning of the morning of 2026-08-16, kept alive on purpose.**
    ///
    /// Not history and not a comment: it is the negative pole of the pumping
    /// bench. `--isola-filmato --taratura=prima` films the wave with these
    /// numbers, and the measurement has to FAIL its first criterion — if it
    /// passes, the bench is not measuring the thing he was looking at, and the
    /// green next to it means nothing.
    ///
    /// A knee equal to the ceiling and an exponent of a half reproduce the old
    /// square-root map exactly; a hold of zero reproduces the old smoothing.
    static let diPrima = Taratura(ginocchio: 0.10, quotaGinocchio: 1.0, esponente: 0.5,
                                  tetto: 0.10, attacco: 0.65, rilascio: 0.15, tenuta: 0)

    /// The fast envelope, the one that follows syllables instead of phrases.
    ///
    /// It never touches the height. Its distance from the slow one is the
    /// `dettaglio` the drawing turns into a nudge of the crests' speed, which is
    /// where the syllabic detail went when it was taken out of the amplitude.
    /// Its map is irrelevant — only the two coefficients are ever used — so it
    /// carries the live one.
    static let sillabica = Taratura(ginocchio: viva.ginocchio, quotaGinocchio: viva.quotaGinocchio,
                                    esponente: viva.esponente, tetto: viva.tetto,
                                    attacco: 0.55, rilascio: 0.35, tenuta: 0)

    // MARK: - The tail, in seconds rather than in coefficients
    //
    // The three numbers above are per-sample fractions, which is the only form the
    // envelope can use and the one form nobody can read. Every sentence about this
    // tuning is about SECONDS — «si appiattisce troppo rapidamente quando smetto di
    // parlare» — so the seconds are derived here, once, and the doc comments and
    // the probes read them instead of each carrying its own copy of the arithmetic.
    //
    // The lesson underneath is the one paid for on 2026-08-06: a figure derived
    // from another and written down by hand goes stale the first time the source
    // changes, and nothing fails when it does.

    /// Seconds the height stays perfectly still after the last onset.
    var secondiDiTenuta: Double { Double(tenuta) / WaveIsland.samplesPerSecond }

    /// Seconds the release needs to fall to `quota` of the height it started from
    /// — the closed form of `livello *= (1 - rilascio)` repeated.
    func secondiPerScendere(a quota: Double) -> Double {
        guard rilascio > 0, rilascio < 1, quota > 0, quota < 1 else { return .infinity }
        return log(quota) / log(1 - rilascio) / WaveIsland.samplesPerSecond
    }

    /// **The whole tail: from the last syllable to `quota` of the height.** This is
    /// the number his eye is judging when he says the island flattens too fast.
    func coda(fino a: Double) -> Double { secondiDiTenuta + secondiPerScendere(a: a) }

    /// The same tuning with a different release — the knob for the sweep, and for
    /// the before/after that `--misura-inviluppo --rilascio=` prints.
    func con(rilascio nuovo: Double) -> Taratura {
        Taratura(ginocchio: ginocchio, quotaGinocchio: quotaGinocchio, esponente: esponente,
                 tetto: tetto, attacco: attacco, rilascio: nuovo, tenuta: tenuta)
    }
}

/// An envelope follower with a hold: level, plus how many samples of stillness
/// are still owed.
///
/// A value type and a pure step, so the whole of a spoken phrase can be run
/// through it in a test without a microphone, a window or a clock.
struct Inviluppo: Sendable, Equatable {
    var livello: Double = 0
    /// Samples of hold still to be spent.
    var tenutaRimasta: Int = 0
    /// The previous sample's target. Kept because an *onset* — the loudness going
    /// up from one sample to the next — is what re-arms the hold, and an onset
    /// cannot be recognised from the level alone.
    var obiettivoPrecedente: Double = 0

    /// **The hold is re-armed by onsets, not by rises, and the difference is the
    /// whole fix.**
    ///
    /// The first version re-armed only when the target went above the current
    /// level, and the bench caught it on the written phrase: within one word the
    /// height still collapsed to a fifth. The reason is that the syllables of a
    /// phrase are not equally loud — after a strong one the level sits above the
    /// peak of the next, so no rise happens, the hold drains through three or
    /// four weak syllables in a row, and the release takes over in the middle of
    /// a word. Exactly the pumping, with a hold in front of it.
    ///
    /// An onset — louder than the sample before — says *a syllable has started*
    /// whatever its height, so it re-arms. Presence alone deliberately does not:
    /// a steady hiss produces no onsets, the hold drains, and the level settles
    /// down onto the hiss instead of staying up on the memory of a voice.
    func avanzato(verso obiettivo: Double, con taratura: Taratura) -> Inviluppo {
        // With no hold configured this is exactly the old attack/release pair,
        // which is what makes `Taratura.diPrima` a faithful negative pole rather
        // than an approximation of one.
        let attacco = obiettivo > obiettivoPrecedente && taratura.tenuta > 0
        if obiettivo > livello {
            return Inviluppo(livello: livello + (obiettivo - livello) * taratura.attacco,
                             tenutaRimasta: taratura.tenuta, obiettivoPrecedente: obiettivo)
        }
        if attacco || tenutaRimasta > 0 {
            return Inviluppo(livello: livello,
                             tenutaRimasta: attacco ? taratura.tenuta : tenutaRimasta - 1,
                             obiettivoPrecedente: obiettivo)
        }
        return Inviluppo(livello: livello + (obiettivo - livello) * taratura.rilascio,
                         tenutaRimasta: 0, obiettivoPrecedente: obiettivo)
    }
}

/// Where the island is drawn while it is arriving or leaving — one value for
/// everything that moves, so a state can be looked at rather than inferred from
/// modifiers spread across a view.
///
/// **The two positions enter differently because they are different objects.**
/// From the notch there is a physical edge to be born from, so the island comes
/// out of it **as a drop**: it starts as a lip no wider than the notch and no
/// taller than its band, and opens out to full size on one clock. That is why
/// nothing here slides: the island does not arrive from somewhere, it opens where
/// it already was.
///
/// A free island has no edge to be born from — stretching it from a point would be
/// inventing an origin — so it fades up with a short uniform scale, which reads as
/// arriving without claiming a place it came from.
///
/// **The exit is this backwards, and since 2026-08-17 that is literal rather than
/// intended.** Both ends read the two states below, and both run the same curve —
/// one mirrored from the other — over the same duration, so the closing he likes
/// and the opening he did not are the same gesture in two directions. The pieces
/// that made them differ (a spring one side, an eased curve the other, and a delay
/// on the width) are gone; what is left of the delay is `attesaLarghezza`, kept at
/// zero as the negative pole of the test that checks all this.
struct IslandEntrance: Equatable {
    var scaleX: CGFloat
    var scaleY: CGFloat
    var anchor: UnitPoint
    var opacity: Double

    /// The scale a free island starts from. Small on purpose: below about 0.9 it
    /// stops reading as "arriving" and starts reading as "zooming".
    static let bubbleScale: CGFloat = 0.92

    /// **La larghezza del notch fisico**, in punti: circa 192 su questi schermi.
    /// Il labbro chiuso si misura contro l'hardware, non contro la banda.
    static let notchFisico: CGFloat = 192

    /// La striscia che l'isola tiene libera per l'hardware (`IslandView.notch`).
    ///
    /// **Si LEGGE dal sistema, non si indovina** (MacAppRules §0.1), e il 19/08 il
    /// numero scritto a mano era sbagliato di 14 punti: `safeAreaInsets.top` sul
    /// suo Mac dice **32**, il valore fisso diceva 18. Finché la banda era alta
    /// 128 l'errore stava nascosto nell'abbondanza; stringendola a 96 è uscito
    /// fuori come lui l'ha visto, cioè l'onda tagliata dal notch stesso.
    ///
    /// Su uno schermo senza notch `safeAreaInsets.top` è 0 e non c'è hardware da
    /// scansare: lì vale il valore di riserva, che serve solo a non incollare
    /// l'onda al bordo.
    static let strisciaPredefinita: CGFloat = 18

    static func strisciaHardware(_ schermo: NSScreen?) -> CGFloat {
        let notch = schermo?.safeAreaInsets.top ?? 0
        return notch > 0 ? notch : strisciaPredefinita
    }

    /// **Il pizzico**: la goccia parte un po' più STRETTA del notch da cui pende
    /// — 168 contro 192 — ed è lo schiacciamento che le dà il carattere. Una
    /// goccia che sta per staccarsi è più sottile del labbro che la tiene.
    static let pizzico: CGFloat = 168.0 / 192.0

    /// Dove parte la goccia, come frazione dell'isola a riposo.
    ///
    /// **Calcolate, non scritte a mano, dal 19/08.** Erano due numeri fissi (0,42
    /// e 0,14) giusti finché la banda era 400×128; stringendola a 320×96 il labbro
    /// sarebbe diventato più largo del notch fisico e la striscia si sarebbe
    /// rimpicciolita insieme alla banda, cioè due difetti silenziosi da un
    /// cambio di costante altrove. Una prova li ha presi entrambi. Adesso il
    /// numero segue la sua misura in PUNTI: cambiando la banda, il labbro resta
    /// quello dell'hardware.
    static var dropWidth: CGFloat { min(1, notchFisico * pizzico / IslandPanel.width) }
    static var dropHeight: CGFloat { min(1, strisciaPredefinita / IslandPanel.height) }

    // MARK: - The arrival is the departure backwards, and that is now literal
    //
    // 2026-08-17, his words: «l'animazione a goccia non mi fa impazzire, non la
    // intendevo in quel modo… quando scende, scende troppo dritto verso il basso
    // e si apre. Mentre quando si chiude mi piace, quindi facciamo che si deve
    // aprire in maniera opposta a come si chiude però con lo stesso tipo di
    // animazione».
    //
    // What he was looking at was an ASYMMETRY that had been put there on purpose
    // the day before. The arrival ran a spring of 0.40 with the width held back
    // for the first 0.18 s, so the shape dropped down at nearly the notch's width
    // and only then opened out — «scende dritto verso il basso e si apre», said
    // back to us in his own words. The departure had none of that: one curve,
    // both axes, 0.24 s.
    //
    // So the choreography is now ONE function of a progress 0→1, run forwards to
    // arrive and backwards to leave. Not two timings that agree today: the
    // arrival's curve is DERIVED from the departure's by mirroring it
    // (`Curva.rovesciata`), which is what time reversal is, so the day somebody
    // changes the departure the arrival follows it and cannot be left behind.
    //
    // `symmetry`, in `WaveIslandTests`, samples both directions and demands the
    // one be the reverse of the other; its negative pole feeds `attesaLarghezza`
    // back in and demands the same check go red.

    /// A cubic bézier timing curve, as its two control points — the four numbers
    /// CSS and SwiftUI both take, kept as data so the drawn curve and the tested
    /// curve are one object rather than two that resemble each other.
    struct Curva: Equatable, Sendable {
        let x1, y1, x2, y2: Double

        /// **The same curve run backwards in time**, which is the point reflection
        /// of its control points through the middle of the unit square.
        ///
        /// The identity this buys, and the one the test measures, is
        /// `rovesciata.frazione(p) == 1 - frazione(1 - p)`: a trajectory drawn with
        /// one is the other's read back to front, exactly and not approximately.
        var rovesciata: Curva { Curva(x1: 1 - x2, y1: 1 - y2, x2: 1 - x1, y2: 1 - y1) }

        /// How far along the movement is, at a given fraction of the duration.
        ///
        /// Bisection rather than Newton: the curve is solved once per sample in a
        /// test and never at draw time — SwiftUI draws it from the same four
        /// numbers — so sixty halvings of an interval of one are free and cannot
        /// diverge, which a Newton step on a bézier with a flat tangent can.
        func frazione(a progresso: Double) -> Double {
            let p = min(1, max(0, progresso))
            if p <= 0 { return 0 }
            if p >= 1 { return 1 }
            func ascissa(_ t: Double) -> Double {
                let u = 1 - t
                return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
            }
            func ordinata(_ t: Double) -> Double {
                let u = 1 - t
                return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
            }
            var basso = 0.0, alto = 1.0, t = p
            for _ in 0..<60 {
                if ascissa(t) < p { basso = t } else { alto = t }
                t = (basso + alto) / 2
            }
            return ordinata(t)
        }
    }

    /// **The departure's curve, and it is the one he said was right.**
    ///
    /// These four numbers are `Animation.easeIn` written out: CSS defines
    /// `ease-in` as `cubic-bezier(0.42, 0, 1, 1)` and SwiftUI's is the same, so
    /// the exit draws exactly what it drew before this change — which matters,
    /// because the exit is the half nobody asked to touch.
    ///
    /// It is spelled out rather than left as `.easeIn` for one reason: an
    /// `Animation` cannot be asked what it does, so as a named case it could
    /// neither be mirrored nor sampled, and the symmetry would be a claim in a
    /// comment.
    static let curvaUscita = Curva(x1: 0.42, y1: 0, x2: 1, y2: 1)

    /// The arrival's curve, DERIVED. Never write this one by hand: mirroring is
    /// the whole promise, and a second literal is how the two ends drift apart.
    static var curvaEntrata: Curva { curvaUscita.rovesciata }

    static func curva(entrando: Bool) -> Curva { entrando ? curvaEntrata : curvaUscita }

    /// **How long the width waits before it opens, as a fraction of the movement
    /// — and it is zero.**
    ///
    /// Zero is the fix: this held 0.45 until 2026-08-17, and that hold is exactly
    /// what he was describing. It stays here as a parameter instead of being
    /// deleted for the reason `Taratura.diPrima` stays: it is the NEGATIVE POLE of
    /// the symmetry test. Feed 0.45 back into `traiettoria` and the reversal check
    /// has to go red — if it does not, the green next to it is measuring nothing
    /// (OperationalLessons, 2026-07-12).
    static let attesaLarghezza: Double = 0

    /// The animation SwiftUI draws, built from the same four numbers the test
    /// samples. One clock for both axes and both directions.
    static func animation(entrando: Bool) -> Animation {
        let c = curva(entrando: entrando)
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: WaveIsland.durataTransizione)
    }

    /// **Where the island is at a given fraction of the movement** — the half a
    /// test can read, and the definition of the choreography rather than a model
    /// of it.
    ///
    /// `attesaLarghezza` is injectable so the bench can put the old defect back
    /// without editing the file; left alone it is zero and the width moves on the
    /// same clock as everything else.
    static func traiettoria(for position: WavePosition,
                            progresso: Double,
                            entrando: Bool,
                            attesaLarghezza: Double = attesaLarghezza) -> IslandEntrance {
        let chiusa = state(for: position, shown: false)
        let aperta = state(for: position, shown: true)
        let da = entrando ? chiusa : aperta
        let a = entrando ? aperta : chiusa
        let c = curva(entrando: entrando)
        let f = c.frazione(a: progresso)
        // The hold only ever existed coming out of the notch: a free island has no
        // edge to stretch from, and the departure never had it at all.
        let trattiene = entrando && position == .notch && attesaLarghezza > 0
        let fLarghezza = trattiene
            ? c.frazione(a: (progresso - attesaLarghezza) / (1 - attesaLarghezza))
            : f
        func fra(_ da: CGFloat, _ a: CGFloat, _ f: Double) -> CGFloat { da + (a - da) * CGFloat(f) }
        return IslandEntrance(scaleX: fra(da.scaleX, a.scaleX, fLarghezza),
                              scaleY: fra(da.scaleY, a.scaleY, f),
                              anchor: da.anchor,
                              opacity: da.opacity + (a.opacity - da.opacity) * f)
    }

    static func state(for position: WavePosition, shown: Bool) -> IslandEntrance {
        switch position {
        case .notch:
            // `.top`: the drop hangs from the hardware and grows DOWNWARD, so the
            // one edge that must never move is the one glued to the screen.
            return .init(scaleX: shown ? 1 : dropWidth,
                         scaleY: shown ? 1 : dropHeight,
                         anchor: .top,
                         // Opaque from the first frame, and deliberately: the drop
                         // is made of the notch's own black, and a lip fading in
                         // under the hardware would read as a glow rather than as
                         // something being born.
                         opacity: 1)
        case .bassoCentro, .libera:
            return .init(scaleX: shown ? 1 : bubbleScale,
                         scaleY: shown ? 1 : bubbleScale,
                         anchor: .center,
                         opacity: shown ? 1 : 0)
        }
    }
}

/// The island's window: borderless, floating, and **not** stealing the keyboard
/// from whatever you are dictating into.
///
/// `.nonactivatingPanel` plus `canBecomeKey == false` is the whole of it: a panel
/// that took focus would move the caret out of the field the text is about to be
/// injected into, which is the one thing this window must never do.
/// **La vista che si prende il trascinamento**, invece di cederlo al sistema.
///
/// Tre metodi e nessuna astuzia: si segna dov'era il puntatore e dov'era la
/// finestra, muove la finestra dello stesso scarto, e a mano alzata riferisce.
/// Lo scarto invece della posizione assoluta perché il puntatore non sta al
/// centro della pillola: sommare la differenza tiene il punto afferrato sotto le
/// dita per tutto il gesto, mentre inseguire con il centro fa saltare l'isola al
/// primo movimento.
///
/// Il motivo per cui questa classe esiste è misurato e sta accanto a
/// `isMovable = false` in `IslandPanel.init`: il trascinamento di sistema apre
/// l'affiancamento di macOS sul bordo superiore.
@MainActor
final class IslandPanel: NSPanel {
    // `nonisolated`: two numbers, immutable, and `IslandEntrance` — which is
    // deliberately pure so it can be tested off the main actor — measures the
    // slide in units of the panel's own height rather than repeating 128.
    //
    // **These two are the NOTCH's**, and the free island is square. The panel is
    // exactly the island's bounding box in both cases, which is not tidiness: a
    // panel wider than what it draws is an invisible window lying over the desktop
    // at `.statusBar`, and every click that lands in its empty part is a click the
    // app under it never receives.
    /// **320 e non 400 dal 19/08**, sua richiesta: «stringiamolo un po', perché
    /// abbiamo un bel po' di cose nella barra sopra». La banda scende così a 1,6
    /// volte il notch fisico invece di 2, e lascia respirare i menu ai due lati.
    /// Sotto i 300 non si può andare senza rompere il rapporto con la pillola
    /// (150), che una prova tiene inchiodato a metà della banda.
    nonisolated static let width: CGFloat = 320
    /// **96 e non 128 dal 19/08**, sua richiesta guardando la barra vera: «la barra
    /// che esce fuori la voglio più piccola», «più sottile». Il rapporto passa da
    /// 3,1:1 a 4,2:1, quindi la banda resta una banda e non diventa un riquadro.
    /// La larghezza NON cambia: quello che sporge di troppo è l'altezza, e la
    /// larghezza è ciò che la fa leggere come continuazione dell'hardware.
    nonisolated static let height: CGFloat = 96

    /// Room around the island for the movement to pass its settled size into, as a
    /// fraction of that size.
    ///
    /// **A window cannot draw outside itself, and whatever passes its edge is
    /// sliced off flat.** The failure would look like an animation that does not
    /// overshoot rather than like a window that is too small, which is why the
    /// margin is stated instead of assumed.
    ///
    /// Since 2026-08-17 the curve does not in fact overshoot: the spring that used
    /// to bounce past full size was replaced by the mirror of the exit's eased
    /// curve, which arrives at 1 and stops. The margin is kept and NOT reclaimed,
    /// deliberately — `theTransitionNeverPassesItsOwnSize` measures the real curve
    /// against it, so this stays a live cushion for whatever curve is here next
    /// rather than a number that quietly became decoration.
    nonisolated static let bounceSlack: CGFloat = 0.14

    /// What is DRAWN: the island itself, without the slack.
    nonisolated static func shellSize(for position: WavePosition) -> CGSize {
        switch position {
        case .notch:                    return CGSize(width: width, height: height)
        case .bassoCentro, .libera:     return BubbleGeometry.size
        }
    }

    /// **La forma a metà strada**, come funzione di un progresso solo.
    ///
    /// Ai due capi restituisce ESATTAMENTE le due forme discrete — non qualcosa
    /// che ci somiglia — così la transizione e le due posizioni ferme non possono
    /// divergere: sono la stessa funzione valutata in 0 e in 1.
    nonisolated static func shellSize(progresso p: Double) -> CGSize {
        let banda = shellSize(for: .notch), pillola = shellSize(for: .libera)
        return CGSize(width: banda.width + (pillola.width - banda.width) * p,
                      height: banda.height + (pillola.height - banda.height) * p)
    }

    nonisolated static func size(progresso p: Double) -> CGSize {
        let guscio = shellSize(progresso: p)
        return CGSize(width: guscio.width + (guscio.width * bounceSlack).rounded(),
                      height: guscio.height + (guscio.height * bounceSlack).rounded())
    }

    /// Dove sta il guscio dentro la finestra, a metà trasformazione.
    ///
    /// Nel notch il gioco della rimbalzata sta tutto sotto (il guscio tocca il
    /// bordo fisico); nella pillola è diviso a metà. Anche questo interpola,
    /// altrimenti il guscio salterebbe dentro la finestra nell'istante in cui la
    /// finestra smette di essere appesa.
    nonisolated static func shellFrame(progresso p: Double) -> CGRect {
        let finestra = size(progresso: p), guscio = shellSize(progresso: p)
        let x = (finestra.width - guscio.width) / 2
        let alto = finestra.height - guscio.height
        let centrato = (finestra.height - guscio.height) / 2
        return CGRect(x: x, y: alto + (centrato - alto) * p,
                      width: guscio.width, height: guscio.height)
    }

    /// The window: the island plus the room its bounce needs.
    nonisolated static func size(for position: WavePosition) -> CGSize {
        let shell = shellSize(for: position)
        return CGSize(width: shell.width + (shell.width * bounceSlack).rounded(),
                      height: shell.height + (shell.height * bounceSlack).rounded())
    }

    /// Where the island sits inside the window, in AppKit coordinates.
    ///
    /// The drop grows DOWNWARD out of the hardware, so in the notch the shell is
    /// pinned to the top of the panel and the whole slack is underneath it. The
    /// free island bounces in every direction from its middle, so there the slack
    /// is shared out all round.
    nonisolated static func shellFrame(for position: WavePosition) -> CGRect {
        let panel = size(for: position), shell = shellSize(for: position)
        let x = (panel.width - shell.width) / 2
        let y = position == .notch ? panel.height - shell.height
                                   : (panel.height - shell.height) / 2
        return CGRect(x: x, y: y, width: shell.width, height: shell.height)
    }

    private let state: AppState
    /// What to do with a move that was his hand — it is handed the island's
    /// CENTRE, not the corner of the window. Injectable for one reason only: the
    /// test that proves a placement of OURS is not filed as a drag must not be
    /// able to write into the real settings while it checks that nothing is
    /// written. Left out, it writes to `AppState`.
    private let alRilascio: ((NSPoint) -> Void)?
    /// True while the code is placing the panel — that is how a `setFrameOrigin`
    /// of ours is told apart from a drag by his hand.
    private var placingProgrammatically = false
    private var moveObserver: NSObjectProtocol?
    /// Il monitor globale che guarda passare il trascinamento.
    private var monitorGesto: Any?
    private var monitorLocale: Any?
    private var trascinando = false
    private var scartoDalCentro: CGPoint = .zero
    private var mossaAvvenuta = false

    /// **Come l'isola sopravvive al cambio di schermata**, e i tre flag servono
    /// tutti e tre: toglierne uno lascia un difetto diverso, e nessuno dei tre si
    /// vede su un fotogramma fermo.
    ///
    /// · `canJoinAllSpaces` — l'isola esiste su OGNI scrivania invece che su
    ///   quella dov'è nata. Senza, passando allo spazio accanto sparisce, e
    ///   ricompare tornando indietro: è il «compare e scompare» delle sue parole.
    /// · `fullScreenAuxiliary` — vale anche sopra un'app a tutto schermo, che su
    ///   macOS è uno spazio a sé. Senza, l'isola è viva ma sotto, cioè invisibile
    ///   proprio dove lui l'ha vista dare più problemi.
    /// · `stationary` — vale per Exposé e Mission Control, che è ciò che la
    ///   documentazione di Apple gli attribuisce, ed è tenuto per quello.
    ///
    /// **Quello che `stationary` NON fa, misurato il 2026-08-17 e scritto qui
    /// perché il commento precedente affermava il contrario.** Diceva che senza di
    /// esso «l'isola scappa di lato e torna», e che con esso resta «inchiodata allo
    /// schermo mentre le scrivanie scorrono sotto». La seconda metà è falsa.
    /// `--sonda-spazi` campiona a 60 Hz la posizione del pannello secondo AppKit e
    /// secondo il WindowServer, attraverso una transizione di spazio vera:
    ///
    /// · AppKit non muove mai la finestra — scarto 0,0 pt in ogni giro, cioè **il
    ///   difetto non è nostro**;
    /// · il WindowServer la trascina lo stesso: da x 528 fino a **x −1048**, cioè
    ///   fuori schermo, con una scivolata liscia di mezzo secondo, e la rimette a
    ///   posto di scatto quando la transizione finisce. **0,78 s spostata.**
    ///   Esattamente il «scappa di lato e torna» che il commento diceva risolto;
    /// · **togliere `stationary` non cambia niente** (`--variante=3`, il controllo
    ///   A/A): 44 istanti spostati contro 47, dentro il rumore fra un giro e
    ///   l'altro. Su questa transizione il flag è inerte.
    ///
    /// **E non c'è manopola che lo fermi.** Spazzati e tutti identici a ~0,78 s:
    /// il livello (24 `mainMenu`, 25 `statusBar`, 1000 `screenSaver`, e il livello
    /// di schermatura 2147483628 — quindi alzarlo, che era l'ipotesi più ovvia, non
    /// serve), `animationBehavior = .none`, togliere `fullScreenAuxiliary`,
    /// `isFloatingPanel = false`, aggiungere `ignoresCycle`. `moveToActiveSpace` al
    /// posto di `canJoinAllSpaces` è **peggio**: non ripara lo spostamento e in più
    /// lascia l'isola fuori dalla scrivania attiva per 204 istanti su 530.
    ///
    /// Quindi: per una transizione a tutto schermo questo è un limite del
    /// compositore, non una nostra configurazione da aggiustare, e i flag qui sotto
    /// restano quelli giusti fra quelli disponibili. **Quello che NON è stato
    /// misurato** è lo scorrimento con le dita fra due scrivanie normali, che è il
    /// caso delle sue parole: i tasti sintetici non lo producono (zero
    /// `activeSpaceDidChange`, contro i 2–3 del polo positivo a tutto schermo), e
    /// il gesto vero resta l'unico strumento. Prima di aggiungere un flag nuovo
    /// qui, rieseguire `--sonda-spazi --variante=<n>`: la spazzata sopra dice che
    /// non ce n'è uno che aiuti.
    ///
    /// Il livello è `.statusBar`, sopra il menu e sopra il contenuto di un'app a
    /// tutto schermo. Sta scritto accanto ai flag perché i due pezzi rispondono
    /// alla stessa domanda — dove vive questa finestra — e separarli è il modo in
    /// cui uno dei due cambia senza l'altro.
    ///
    /// `Onda/SondaPannello` li rilegge dalla finestra VIVA, perché una costante
    /// giusta e un `init` che non la applica sono indistinguibili dal sorgente.
    static let comportamentoPersistente: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    static let livelloPersistente: NSWindow.Level = .statusBar

    init(island: WaveIsland, state: AppState, alRilascio: ((NSPoint) -> Void)? = nil) {
        self.state = state
        self.alRilascio = alRilascio
        let size = Self.size(for: WaveIsland.posizioneCorrente(state))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = WaveIsland.probeFluttuante ?? true
        level = WaveIsland.probeLivello ?? Self.livelloPersistente
        if let a = WaveIsland.probeAnimazione { animationBehavior = a }
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // **Il gesto è nostro, e non è una preferenza di stile.** Misurato il
        // 19/08 con `Scripts/sonda-aggancio.swift` su un pannello NUDO con questi
        // stessi flag, quindi senza una riga di Kalamos dentro: lasciando il
        // trascinamento ad AppKit, il WindowServer lo riconosce come «finestra
        // trascinata» e sul bordo superiore apre l'affiancamento di macOS 26 —
        // due finestre `WindowManager Drag Guide Window` da 1542×905, cioè lo
        // schermo intero velato, che è il «vorrebbe prendere tutto lo schermo»
        // delle sue parole — e al rilascio ributta giù la finestra da y 953 a
        // y 488. Al centro dello schermo, controllo dello stesso banco: zero
        // finestre comparse, zero rimbalzi.
        //
        // Trascinandola noi in `VistaIsola`, i tre sintomi cadono insieme: niente
        // velo, niente rimbalzo, e sparisce anche il ritardo con cui la pillola
        // inseguiva il puntatore. In più il progresso del gesto diventa una cosa
        // che possediamo, senza la quale non si può né agganciare a un'ancora né
        // interpolare la forma fra banda e pillola.
        isMovable = false
        isMovableByWindowBackground = false
        collectionBehavior = WaveIsland.probeComportamento ?? Self.comportamentoPersistente
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = NSHostingView(rootView: IslandView(island: island, state: state))
        osservaIlGesto()

        // **Niente più osservatore di `didMove`.** Serviva a distinguere un
        // movimento della sua mano da uno nostro, e lo faceva con un flag: ora la
        // mano passa dal monitor qui sotto e nostra è ogni altra chiamata, quindi
        // la distinzione non ha più bisogno di essere indovinata da una notifica
        // che arriva identica nei due casi.
    }

    /// **Il trascinamento, guardato da fuori.**
    ///
    /// Il primo tentativo del 19/08 era la strada ovvia — una vista che
    /// sovrascrive `mouseDown` — e **non funziona**, misurato con
    /// `--sonda-trascinamento`: zero punti di spostamento, con `hitTest` che
    /// rispondeva correttamente. Il motivo è la ragione stessa per cui questa
    /// finestra esiste come è fatta: `canBecomeKey == false` e
    /// `.nonactivatingPanel` servono a non spostare il cursore dal campo in cui
    /// sta per essere iniettato il testo, e una finestra che non può diventare
    /// chiave, in un'app che non si attiva mai, non riceve eventi di mouse. Il
    /// trascinamento di sistema funzionava proprio perché scavalca questa strada.
    ///
    /// Un monitor globale li guarda passare senza consumarli e senza chiedere
    /// permessi (per il mouse non serve l'Accessibilità, serve per la tastiera).
    /// Il clic non finisce all'app sotto: la finestra non è trasparente al mouse,
    /// lo assorbe e basta.
    /// Se qualcuno stia davvero guardando il gesto. Per la prova: un monitor
    /// installato e uno mancante sono indistinguibili da fuori.
    var gestoOsservato: Bool { monitorGesto != nil }

    private func osservaIlGesto() {
        guard monitorGesto == nil else { return }
        let tipi: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // **Due monitor, e uno solo non basta — pagato sul campo il 19/08.**
        //
        // Il monitor GLOBALE vede solo gli eventi diretti ad ALTRE applicazioni:
        // è cieco proprio sul caso normale, cioè il clic sull'isola, che la
        // nostra finestra assorbe e quindi resta dentro Kalamos. La sonda non
        // l'aveva colto perché gli eventi sintetizzati, con la nostra app mai
        // attiva, finivano all'app davanti: verde in banco e pillola immobile in
        // mano sua, che è il difetto peggiore di tutti.
        //
        // Il monitor LOCALE prende gli eventi destinati a noi prima che vengano
        // smistati, quindi funziona anche se nessuna vista li raccoglie — ed è
        // il caso di questa finestra, che non potendo diventare chiave non li
        // riceverebbe mai. Restituisce l'evento invariato: guardare, non
        // consumare.
        monitorGesto = NSEvent.addGlobalMonitorForEvents(matching: tipi) { [weak self] evento in
            MainActor.assumeIsolated { self?.gesto(evento) }
        }
        monitorLocale = NSEvent.addLocalMonitorForEvents(matching: tipi) { [weak self] evento in
            MainActor.assumeIsolated { self?.gesto(evento) }
            return evento
        }
    }

    /// Rimette i monitor se erano stati restituiti. `present()` riusa il pannello
    /// fra una dettatura e l'altra, e senza questa riga la pillola sarebbe
    /// trascinabile solo la PRIMA volta: `hide()` chiama `detach()`.
    func riprendiIlGesto() { osservaIlGesto() }

    private func gesto(_ evento: NSEvent) {
        switch evento.type {
        case .leftMouseDown:
            let punto = NSEvent.mouseLocation
            // Solo sull'ISOLA, non su tutta la finestra: il gioco della rimbalzata
            // è finestra e non isola, e prenderlo per manico vorrebbe dire
            // afferrare del vuoto intorno a lei.
            let guscio = Self.shellFrame(for: WaveIsland.posizioneCorrente(state))
                .offsetBy(dx: frame.origin.x, dy: frame.origin.y)
            guard isVisible, guscio.contains(punto) else { return }
            trascinando = true
            // **Lo scarto fra il dito e il CENTRO dell'isola**, non fra il dito e
            // l'angolo della finestra. Il centro è l'unico punto che significa la
            // stessa cosa per la banda e per la pillola, quindi è l'unico
            // riferimento che sopravvive alla trasformazione che avviene durante
            // il gesto.
            scartoDalCentro = CGPoint(x: punto.x - islandCentre.x, y: punto.y - islandCentre.y)
            mossaAvvenuta = false
            // Il gesto comincia da dove la forma sta ADESSO, così il primo
            // fotogramma non salta.
            WaveIsland.shared.progressoForma = WaveIsland.progressoCorrente(state)
        case .leftMouseDragged:
            guard trascinando else { return }
            let ora = NSEvent.mouseLocation
            // **Tutto si calcola dal CENTRO voluto dal dito**, in un colpo solo, e
            // in quest'ordine preciso.
            //
            // Il difetto che questo ripara è suo, dal campo del 19/08: avvicinando
            // il notch **lentamente** l'isola veniva respinta e non si agganciava,
            // mentre avvicinandolo di scatto funzionava. La causa è che la finestra
            // CRESCE mentre si avvicina — da 46 a 146 punti di altezza — e
            // crescendo attorno a un centro fermo il suo bordo alto sale: sopra il
            // bordo dello schermo AppKit rifiuta l'origine e la ributta giù. Piano
            // si resta in quella zona per decine di eventi e non si arriva mai; di
            // scatto la si attraversa e l'aggancio al rilascio fa il resto.
            //
            // La riparazione è anche il modello che voleva lui, «un magnete»: il
            // progresso decide la forma **e** la posizione. Vicino all'ancora
            // l'isola è tirata dentro invece di essere lasciata dove capita, quindi
            // a progresso zero la finestra sta esattamente dove `place()` la
            // metterebbe, che è una posizione valida e non una che il sistema
            // rifiuta.
            //
            // Nessun ritorno di fiamma: il progresso si calcola dal centro VOLUTO
            // dal dito, non da quello dove l'isola è finita. Se dipendesse dalla
            // posizione raggiunta, la forma cambierebbe la posizione che decide la
            // forma, ed è il modo classico per far oscillare una cosa che dovrebbe
            // stare ferma.
            guard let screen = NSScreen.main else { return }
            let centroVoluto = NSPoint(x: ora.x - scartoDalCentro.x, y: ora.y - scartoDalCentro.y)
            let p = Ancore.progressoForma(centro: centroVoluto, schermo: screen.frame,
                                          altezzaGuscioNotch: Self.shellSize(for: .notch).height)
            let ancora = Ancore.centroNotch(schermo: screen.frame,
                                            altezzaGuscio: Self.shellSize(for: .notch).height)
            let centroFinale = NSPoint(x: ancora.x + (centroVoluto.x - ancora.x) * p,
                                       y: ancora.y + (centroVoluto.y - ancora.y) * p)
            WaveIsland.shared.progressoForma = p
            let prima = frame
            ridimensionaAttorno(centro: centroFinale)
            guard frame != prima else { return }
            mossaAvvenuta = true
        default:
            guard trascinando else { return }
            trascinando = false
            // Un clic secco non è un rilascio: senza questa riga, sfiorare l'isola
            // basterebbe a riscriverne la posizione.
            guard mossaAvvenuta else { return }
            let centro = islandCentre
            // `alRilascio` è iniettata solo dalle prove, per un motivo solo: il
            // rilascio SCRIVE nelle impostazioni vere, e una prova che lo
            // esercitasse davvero riconfigurerebbe la sua Kalamos.
            if let iniettata = alRilascio { iniettata(centro) } else { rilascioPredefinito(centro: centro) }
        }
    }

    /// **Che cosa fa un rilascio**, cioè il contratto che scioglie ISC-9 e ISC-11.
    ///
    /// Tre righe e nessuna quarta:
    /// · finito **vicino a un'ancora**, si aggancia e si salva il **nome**;
    /// · finito **lontano da tutte** con l'impostazione su un'ancora, il gesto
    ///   vale solo per questa dettatura e non si scrive niente — alla prossima
    ///   `place()` rimette l'isola dove dice l'impostazione;
    /// · finito lontano con l'impostazione su **libera**, si salvano le coordinate.
    ///
    /// Il difetto che questo ripara non era che il trascinamento salvasse: era che
    /// salvava un modo mai scelto e invisibile nel pannello. Nei suoi defaults
    /// c'era `wavePosition = bubble` senza che l'avesse mai toccato dalle
    /// Preferenze, e gliel'aveva scritto la mano.
    ///
    /// Statica e con lo schermo passato: così la prova non ha bisogno di una
    /// finestra viva.
    func rilascioPredefinito(centro: NSPoint) {
        guard let screen = NSScreen.main else { return }
        switch Ancore.rilascio(centro: centro,
                               impostazione: state.wavePosition,
                               schermo: screen.frame,
                               visibile: screen.visibleFrame,
                               altezzaGuscioNotch: Self.shellSize(for: .notch).height) {
        case .nome(let ancora):
            WaveIsland.shared.progressoForma = nil
            // Il nome, non i numeri. L'effimero cade perché adesso c'è una scelta
            // vera, e l'assegnazione fa ripartire `place()` attraverso il
            // publisher: è quello che porta l'isola ESATTAMENTE sull'ancora e le
            // dà la taglia di quella posizione. La crescita alla forma-notch
            // avviene quindi solo quando l'aggancio è avvenuto, mai per
            // avvicinamento — che è la seconda metà di ISC-10.
            WaveIsland.shared.posizioneEffimera = nil
            state.wavePosition = ancora
        case .coordinate(let punto), .lontano(let punto):
            WaveIsland.shared.progressoForma = nil
            // **Lasciata lontano da ogni ancora, diventa libera e ci RESTA**
            // (sua correzione del 19/08, dal campo): «di base è ancorata in basso
            // al centro oppure nel notch, ma è sempre movibile», e «a meno che io
            // nell'ultima registrazione non l'ho tenuta lontana da quell'ancora,
            // in quel caso resta dove l'ho lasciata».
            //
            // Prima di quella correzione questo caso era effimero e la dettatura
            // dopo tornava all'impostazione. Sbagliato, e per una ragione che vale
            // oltre questo punto: il modello non è «un'impostazione con un gesto
            // che la contraddice», è «sempre libera, con due magneti». Il gesto
            // non contraddice niente, sceglie.
            WaveIsland.shared.posizioneEffimera = nil
            state.waveCenter = "\(Int(punto.x)) \(Int(punto.y))"
            if state.wavePosition != .libera { state.wavePosition = .libera }
        }
    }

    /// **Il magnete, mentre la mano si muove.**
    ///
    /// Tirandola fuori dal notch la banda diventa pillola nell'istante in cui
    /// esce dal raggio dell'ancora, e ci ritorna banda se la riavvicini: è il
    /// magnete visto da dentro il gesto, ed è la cosa che gli piaceva del
    /// trascinamento vecchio. Non si scrive niente sul disco qui — la forma di
    /// adesso vive in `posizioneEffimera`, e la decisione la prende il rilascio.
    /// Cambia la taglia della finestra tenendo fermo il CENTRO dell'isola.
    ///
    /// Serve al solo caso effimero, che è l'unico in cui la forma cambia senza che
    /// cambi l'impostazione, quindi senza che `place()` venga chiamata da nessuno.
    /// Il centro e non l'angolo per la stessa ragione di sempre: fra una banda
    /// 400×128 e una pillola 150×40 l'angolo significa due punti diversi, e
    /// tenerlo fermo farebbe saltare l'isola nel momento in cui la lasci.
    func ridimensionaAttorno(centro: NSPoint) {
        let p = WaveIsland.progressoCorrente(state)
        let size = Self.size(progresso: p)
        let shell = Self.shellFrame(progresso: p)
        setFrame(NSRect(x: centro.x - shell.midX, y: centro.y - shell.midY,
                        width: size.width, height: size.height), display: true)
    }

    /// Restituisce quello che la finestra teneva del sistema.
    ///
    /// Chiamata da `WaveIsland.hide()` e non da `deinit`: una classe sull'attore
    /// principale non può toccare questi riferimenti da un `deinit` non isolato, e
    /// il posto onesto in cui rilasciare una cosa è il momento in cui il suo uso
    /// finisce, non quando l'ultimo riferimento capita di sparire. Un monitor
    /// globale vivo fra una dettatura e l'altra è esattamente la risorsa tenuta
    /// più a lungo del suo significato (MacAppRules §0.3).
    func detach() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        if let monitorGesto { NSEvent.removeMonitor(monitorGesto) }
        monitorGesto = nil
        if let monitorLocale { NSEvent.removeMonitor(monitorLocale) }
        monitorLocale = nil
        trascinando = false
    }

    /// Put the panel at an explicit point without it counting as a drag — for the
    /// `--scatta --isola` probe, which must photograph the island without
    /// reconfiguring the Kalamos somebody is using.
    func place(at origin: NSPoint) {
        placingProgrammatically = true
        defer { placingProgrammatically = false }
        setFrameOrigin(origin)
    }

    /// The middle of what he can SEE, in screen coordinates — not the middle of
    /// the window.
    ///
    /// The two differ by the bounce slack, and in the notch the slack is all on one
    /// side: the window's centre sits nine points below the island's. Reporting the
    /// window's centre would move the island by those nine points every time the
    /// shape changed, which is the exact class of silent drift the centre was
    /// chosen to remove.
    var islandCentre: NSPoint {
        let shell = Self.shellFrame(progresso: WaveIsland.progressoCorrente(state))
        return NSPoint(x: frame.origin.x + shell.midX, y: frame.origin.y + shell.midY)
    }

    /// Put the panel where the setting says, **at the size that position is**.
    ///
    /// The size travels with the position and not with the window's history: this
    /// is what runs when he flips the chip in Preferences with the island already
    /// on screen, and a rectangle that stayed 400 points wide after becoming a
    /// pill would be an invisible half-metre of window around it.
    func place() {
        guard let screen = NSScreen.main else { return }
        placingProgrammatically = true
        defer { placingProgrammatically = false }
        let position = WaveIsland.posizioneCorrente(state)
        let size = Self.size(for: position)
        let shell = Self.shellFrame(for: position)
        switch position {
        case .notch:
            // The SHELL flush with the PHYSICAL top edge, not the visible frame and
            // not the window's own edge: the black has to reach the hardware or it
            // floats under the notch instead of continuing it. The window now
            // reaches further down than the shell — that is the room the bounce
            // needs — so the top is computed from the shell and not from the frame.
            setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                            y: screen.frame.maxY - shell.maxY,
                            width: size.width, height: size.height), display: true)
        case .bassoCentro:
            // Ricalcolata dallo schermo di ADESSO, ogni volta. È tutto il
            // vantaggio del nome sul numero: cambia il Dock, cambia il monitor,
            // e l'ancora resta «in basso al centro» invece di restare dov'era
            // quando l'hai salvata.
            let centre = Ancore.centroBasso(visibile: screen.visibleFrame)
            setFrame(NSRect(x: centre.x - shell.midX, y: centre.y - shell.midY,
                            width: size.width, height: size.height), display: true)
        case .libera:
            let centre = Self.savedCenter(state.waveCenter, screen: screen)
                ?? Ancore.centroBasso(visibile: screen.visibleFrame)
            setFrame(NSRect(x: centre.x - shell.midX, y: centre.y - shell.midY,
                            width: size.width, height: size.height), display: true)
        }
    }

    /// Parse `"x y"` — **the island's CENTRE** — and refuse a point that is off
    /// every screen.
    ///
    /// The centre and not the corner, and that is the whole reason this function
    /// changed shape when the free island became round. A corner is a point on a
    /// rectangle 400×128; the same corner on a pill 150×40 is somewhere else
    /// entirely, so a saved corner teleports the island the day the shape changes —
    /// and it changes the instant he drags it out of the notch. A centre means the
    /// same thing to every shape.
    ///
    /// Pura, così i due poli si possono provare: una posizione salvata
    /// sopravvive, e una salvata contro un monitor che non c'è più **viene
    /// riportata dentro** invece di essere buttata.
    ///
    /// **Il 19/08 questa funzione ha cambiato verdetto, e il perché conta.**
    /// Prima rifiutava il punto fuori schermo e chi la chiamava cadeva sul
    /// default, cioè la scelta dell'utente spariva del tutto. Ma un punto salvato
    /// contro un monitor staccato non è un dato corrotto: è un dato giusto per un
    /// mondo che non c'è più, e la risposta proporzionata è riportarlo dentro
    /// l'area visibile conservando il più possibile di dov'era. Resta `nil` solo
    /// per una stringa che non è due numeri, che è l'unico caso in cui davvero
    /// non si sa niente.
    /// I due numeri, senza nessun giudizio su dove cadano.
    ///
    /// Separata da `savedCenter` perché la migrazione ha bisogno del punto
    /// GREZZO: chiedere a `savedCenter` significherebbe farselo già riportare
    /// dentro l'area visibile, e allora un centro salvato su un monitor staccato
    /// verrebbe migrato in base a dove è finito invece che a dove stava.
    static func puntoSalvato(_ raw: String) -> NSPoint? {
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    static func savedCenter(_ raw: String, screen: NSScreen) -> NSPoint? {
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let point = NSPoint(x: parts[0], y: parts[1])
        let reachable = NSScreen.screens.isEmpty ? [screen] : NSScreen.screens
        // Se il centro è ancora su uno schermo, si tiene com'è: è il caso
        // normale, e non deve pagare niente.
        if reachable.contains(where: { $0.frame.contains(point) }) { return point }
        // Altrimenti si riporta dentro l'area visibile dello schermo dato, col
        // guscio nel conto: quello che deve restare afferrabile è la pillola,
        // non il suo centro.
        return Ancore.dentroVisibile(point,
                                     visibile: screen.visibleFrame,
                                     guscio: shellSize(for: .libera))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What is inside the island — **two shapes, because they are two objects**.
///
/// In the notch the shell is SOLID BLACK with only its bottom corners rounded, so
/// it reads as a continuation of the hardware, and the wave lies across it in a
/// band. Free of the notch it is a small PILL: nothing out there is being
/// continued, there is no text to hold since the caption came off, and a plain
/// rectangle floating on the desktop reads as a window that lost its frame. The
/// wave lives along the pill, shaped by it rather than cut by it.
struct IslandView: View {
    @ObservedObject var island: WaveIsland
    @ObservedObject var state: AppState

    var body: some View {
        drawing
            // A veil that is clickable and invisible over the WHOLE shape, and
            // `contentShape` on top of it so the parts the shell does not paint —
            // all of the pill, when it is switched off — are still the
            // handle. Without them the transparent parts are click-through and the
            // island can only be dragged where something happens to be drawn: the
            // same defect as a button you can only press on the word
            // (MacAppRules §3).
            //
            // On the ISLAND and not on the window: the panel is bigger by the
            // bounce slack, and a veil stretched over that would be a strip of
            // desktop, invisible and unclickable, around something that looks like
            // it ends where it is drawn.
            .background(shape.fill(Color.black.opacity(0.001)))
            .contentShape(shape)
            // Arriving and leaving, from one value: the island opens out of the
            // notch (anchored to the hardware, growing down), the bubble fades up
            // in place. The exit is the same value run backwards, so it cannot
            // drift into a second piece of choreography.
            .opacity(entrance.opacity)
            // **One modifier and one clock**, which is the 2026-08-17 repair.
            //
            // Until then the two axes were split across two nested `scaleEffect`s
            // with an `.animation` each, so the width could be given a delay the
            // height did not have. That delay is what he was looking at when he
            // said the island «scende dritto verso il basso e si apre», so the
            // split has no reason to exist any more: `scaleEffect` takes both axes
            // at once, which is precisely the guarantee wanted — they cannot be
            // given separate timings by accident.
            //
            // No explicit `.animation(_:value:)` either: the ambient
            // `withAnimation` at the two call sites carries
            // `IslandEntrance.animation(entrando:)`, and one source for the curve
            // is the same argument as one clock for the axes.
            .scaleEffect(x: entrance.scaleX, y: entrance.scaleY, anchor: entrance.anchor)
            // L'isola sta al suo posto dentro la finestra, col gioco della
            // rimbalzata libero intorno: appesa al notch è tutto sotto, così
            // l'isola continua a toccare il bordo dello schermo; sulla pillola è
            // diviso a metà.
            //
            // **Uno scostamento e non un allineamento**, perché `Alignment` è un
            // valore discreto: sceglierlo con un ternario sul progresso
            // rimetterebbe esattamente il ramo che questa vista esiste per non
            // avere. Lo scarto fra le due posizioni è metà del gioco, e si
            // percorre con lo stesso progresso di tutto il resto.
            .offset(y: -(size.height - shellSize.height) / 2 * (1 - progresso))
            .frame(width: size.width, height: size.height)
            // Last resort. Nothing should reach here — that is what the slack is
            // for — but a window that draws over its own edge is a defect nobody
            // sees on the machine where it fits.
            .clipped()
    }

    /// Aria sopra e sotto il blocco dell'onda, nella banda.
    static let respiro: CGFloat = 6

    /// Quanto hardware c'è da scansare su questo schermo.
    private var striscia: CGFloat { IslandEntrance.strisciaHardware(NSScreen.main) }

    /// **Quello che resta all'onda nella banda**: il guscio, meno l'hardware,
    /// meno l'aria. Pura, così la prova può chiederla per qualunque taglia senza
    /// costruire una vista.
    static func altezzaOnda(guscio: CGFloat, striscia: CGFloat) -> CGFloat {
        max(24, guscio - striscia - respiro * 2)
    }

    /// **UNA forma sola, funzione di un progresso solo** — la banda del notch a 0,
    /// la pillola a 1, e in mezzo la stessa figura valutata a metà strada.
    ///
    /// **Qui NON c'è nessun `if` sul progresso, ed è la regola che questa vista
    /// esiste per rispettare** (pagata il 18/08): un ramo deciso su un valore che
    /// si muove cambia l'identità della vista, SwiftUI salta l'interpolazione, e
    /// il difetto è invisibile nel sorgente perché il codice sembra giusto. I due
    /// aspetti — il nero squadrato dell'hardware e la capsula colorata — sono
    /// quindi **due strati sempre presenti** che si scambiano per opacità, non due
    /// viste che si sostituiscono.
    ///
    /// Il ramo che resta è sull'interruttore del guscio, che durante il gesto è
    /// una costante: quello si può decidere, perché non si muove.
    private var drawing: some View {
        let p = progresso
        let guscio = IslandPanel.shellSize(progresso: p)
        let riquadro = riquadroOnda(p: p, guscio: guscio)
        let sagoma = Self.sagoma(p: p, guscio: guscio)
        let mostraGuscio = (WaveIsland.probeShell ?? state.waveShell) ? 1.0 : 0.0
        return ZStack(alignment: .top) {
            // Il nero che continua l'hardware: pieno nel notch, spento sulla
            // pillola.
            sagoma.fill(Color.black).opacity(1 - p)
            // La capsula colorata: assente nel notch, piena sulla pillola — e
            // solo se lui tiene acceso il guscio.
            sagoma.fill(WaveTint.color(from: state.waveShellTint).opacity(0.94))
                .opacity(p * mostraGuscio)
            wave(profilo: Self.profiloMisto(p: p, riquadro: riquadro, guscio: guscio))
                .frame(width: riquadro.width, height: riquadro.height)
                .padding(.top, insetSuperiore(p: p, guscio: guscio, riquadro: riquadro))
        }
        .frame(width: guscio.width, height: guscio.height)
        // La garanzia, non il metodo: niente può debordare nemmeno se un giorno
        // l'aritmetica dicesse altro.
        .clipShape(sagoma)
    }

    /// La sagoma a metà strada. Il notch ha gli angoli alti squadrati, perché in
    /// cima c'è l'hardware da continuare; la pillola è una capsula, cioè un
    /// rettangolo con tutti i raggi a metà altezza. Interpolando i quattro raggi
    /// si passa dall'una all'altra senza che nessun fotogramma sia una forma
    /// impossibile.
    static func sagoma(p: Double, guscio: CGSize) -> UnevenRoundedRectangle {
        // Il tetto è metà altezza, e non è una cautela: un raggio più grande di
        // metà lato è una forma che non esiste. Serve perché i due estremi si
        // muovono insieme — mentre il raggio in basso scende da 24 verso la
        // capsula, l'altezza cala da 96 a 40, e verso la fine del percorso metà
        // altezza passa SOTTO 24. Trovato dalla prova, non a occhio: fra il 90% e
        // il 100% il raggio superava il tetto di frazioni di punto.
        let capsula = guscio.height / 2
        let alto = min(capsula, capsula * p)
        let basso = min(capsula, 24 + (capsula - 24) * p)
        return UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: alto, bottomLeading: basso,
                               bottomTrailing: basso, topTrailing: alto),
            style: .continuous)
    }

    /// Il riquadro dell'onda: largo quanto il guscio nella banda, quello di
    /// `BubbleGeometry` sulla pillola.
    private func riquadroOnda(p: Double, guscio: CGSize) -> CGSize {
        let banda = CGSize(width: guscio.width,
                           height: Self.altezzaOnda(guscio: guscio.height, striscia: striscia))
        let pillola = BubbleGeometry.waveSize(in: guscio)
        return CGSize(width: banda.width + (pillola.width - banda.width) * p,
                      height: banda.height + (pillola.height - banda.height) * p)
    }

    /// Quanto scende l'onda dal bordo alto: sotto l'hardware nella banda, al
    /// centro sulla pillola.
    private func insetSuperiore(p: Double, guscio: CGSize, riquadro: CGSize) -> CGFloat {
        let banda = striscia + Self.respiro
        let pillola = (guscio.height - riquadro.height) / 2
        return banda + (pillola - banda) * p
    }

    /// I due profili dell'onda, mescolati dallo stesso progresso.
    ///
    /// Non sono intercambiabili: quello della banda si spegne solo sulle due code,
    /// quello della pillola abbassa il soffitto dove la capsula si chiude. Mescolarli
    /// invece di sceglierne uno è ciò che evita lo scatto anche nel disegno interno,
    /// che è la metà del passaggio che nessuno guarda.
    static func profiloMisto(p: Double, riquadro: CGSize, guscio: CGSize) -> @Sendable (Double) -> Double {
        let dellaBanda = WaveCanvas.profiloSfumato()
        let dellaPillola = BubbleGeometry.profile(box: riquadro, in: guscio)
        return { u in dellaBanda(u) * (1 - p) + dellaPillola(u) * p }
    }

    private var wave: some View { wave(profilo: WaveCanvas.profiloPieno) }

    private func wave(profilo: @escaping @Sendable (Double) -> Double) -> some View {
        WaveformView(livello: island.level,
                     dettaglio: island.detail,
                     tinta: WaveTint.color(from: state.waveTint),
                     attiva: true,
                     profilo: profilo)
            .allowsHitTesting(false)
    }

    private var position: WavePosition { WaveIsland.posizioneCorrente(state) }
    /// 0 la banda, 1 la pillola. È l'unico valore da cui dipende tutto il disegno.
    private var progresso: Double { WaveIsland.progressoCorrente(state) }
    /// The window, and the island inside it: the first is bigger by the room the
    /// bounce needs, and everything drawn is measured against the second.
    private var size: CGSize { IslandPanel.size(progresso: progresso) }
    private var shellSize: CGSize { IslandPanel.shellSize(progresso: progresso) }
    /// Il contorno dell'isola: quello che si afferra, e su cui è steso il velo
    /// cliccabile. Tutta la pillola, capi compresi — la prende dove capita.
    ///
    /// È la **stessa** sagoma del disegno, valutata allo stesso progresso, e non
    /// una seconda copia: un contorno che restasse rettangolare mentre il disegno
    /// è già capsula darebbe un'area cliccabile che non coincide con ciò che si
    /// vede, ed è il difetto che non si nota finché non si clicca di striscio.
    private var shape: AnyShape { AnyShape(Self.sagoma(p: progresso, guscio: shellSize)) }

    private var entrance: IslandEntrance {
        IslandEntrance.state(for: position, shown: island.shown)
    }
}
