import AppKit
import Testing
@testable import Kalamos

/// The wave has four pieces that can be wrong without anything looking wrong: the
/// map from loudness to height, the smoothing, the colour that has to survive a
/// trip through UserDefaults, and the rule that tells a drag from a placement.
///
/// None of them is visible in a screenshot — a wave drawn from a broken level
/// still looks like a wave — so they are the pieces that get a test.
@Suite struct WaveIslandTests {

    // MARK: - Loudness → height

    /// Silence draws nothing, and the floor is the app's ONE definition of
    /// silence, not a second one invented here.
    @Test func belowTheSpeechFloorTheWaveIsFlat() {
        let floor = Double(AudioRecorder.speechFloor)
        #expect(WaveIsland.normalize(rms: 0) == 0)
        #expect(WaveIsland.normalize(rms: floor) == 0)
        #expect(WaveIsland.normalize(rms: floor * 0.9) == 0)
    }

    /// The opposite pole: ordinary speech has to produce a wave you can SEE. This
    /// is the assertion that a "safe" mapping — one that returns near-zero for
    /// everything — cannot satisfy.
    @Test func ordinarySpeechIsWellOffTheFloor() {
        // 0.02 RMS is a quiet voice, 0.06 a normal one.
        #expect(WaveIsland.normalize(rms: 0.02) > 0.25)
        #expect(WaveIsland.normalize(rms: 0.06) > 0.55)
    }

    /// **The whole of ordinary speech has to draw nearly the same height**, which
    /// is the opposite demand from the one above and the reason the map was
    /// changed on 2026-08-16: what the picture says is *speaking / not speaking*,
    /// not *this syllable was louder than that one*. A quiet voice and a normal
    /// one must land within a fifth of each other, or the wave heaves on every
    /// stressed vowel — «vibra tanto ed è fastidioso a vedersi».
    ///
    /// The old map fails this by a mile: 0.41 against 0.76 is a ratio of 1.9.
    @Test func allOfOrdinarySpeechDrawsNearlyTheSameHeight() {
        let piano = WaveIsland.normalize(rms: 0.02)
        let normale = WaveIsland.normalize(rms: 0.06)
        #expect(piano > 0.7, "una voce piana disegna solo \(piano) del pieno")
        #expect(normale / piano < 1.25,
                "fra voce piana e voce normale ci sono \(normale / piano)× di altezza")

        let prima = WaveIsland.normalize(rms: 0.06, con: .diPrima)
            / WaveIsland.normalize(rms: 0.02, con: .diPrima)
        #expect(prima > 1.5, "la taratura di prima non comprimeva: è il polo negativo di questa prova")
    }

    @Test func loudnessIsMonotoneAndSaturates() {
        var previous = -1.0
        for rms in stride(from: 0.0, through: 0.30, by: 0.005) {
            let value = WaveIsland.normalize(rms: rms)
            #expect(value >= previous, "louder audio must never draw a smaller wave")
            #expect(value <= 1, "the wave never goes over full height")
            previous = value
        }
        #expect(WaveIsland.normalize(rms: 0.15) == 1)
        #expect(WaveIsland.normalize(rms: 3.0) == 1)   // absurd input, still bounded
    }

    // MARK: - The envelope

    /// Fast attack, slow release — the asymmetry IS the feature: a wave that fell
    /// as fast as it rose would flicker on every gap between syllables.
    /// Measured in TIME rather than in coefficients, which is both the honest
    /// claim and the robust one: with a hold in front of the release, comparing
    /// the two coefficients would leave out the part that does most of the work.
    @Test func theWaveRisesFasterThanItFalls() {
        var e = Inviluppo()
        var salita = 0
        while e.livello < 0.9 { e = e.avanzato(verso: 1, con: .viva); salita += 1 }
        var discesa = 0
        while e.livello > 0.1 { e = e.avanzato(verso: 0, con: .viva); discesa += 1 }
        #expect(discesa > salita * 3,
                "salita \(salita) campioni, discesa \(discesa): l'asimmetria non c'è")
    }

    @Test func theEnvelopeConvergesAndNeverOvershoots() {
        var e = Inviluppo()
        for _ in 0..<200 { e = e.avanzato(verso: 0.8, con: .viva) }
        #expect(abs(e.livello - 0.8) < 0.001)
        #expect(e.livello <= 0.8)

        for _ in 0..<400 { e = e.avanzato(verso: 0, con: .viva) }
        #expect(e.livello < 0.001)
        #expect(e.livello >= 0)
    }

    /// Half a second of speech has to get the wave most of the way up — a release
    /// coefficient copied into the attack slot would pass every test above and
    /// fail this one.
    @Test func aVoiceFillsTheWaveWithinHalfASecond() {
        var e = Inviluppo()
        for _ in 0..<Int(WaveIsland.samplesPerSecond / 2) { e = e.avanzato(verso: 1, con: .viva) }
        #expect(e.livello > 0.9, "dopo 0,5 s di parlato l'onda era solo a \(e.livello)")
    }

    /// **The other pole of the same coin, and the one the defect was made of.**
    /// The attack must not be a step either: from silence to full in fewer than
    /// three samples reads as a snap, not as a wave waking up.
    @Test func theAttackIsARampAndNotAStep() {
        var e = Inviluppo()
        var campioni = 0
        while e.livello < 0.9 && campioni < 100 {
            e = e.avanzato(verso: 1, con: .viva)
            campioni += 1
        }
        #expect(campioni > 3, "l'onda ha raggiunto il pieno in \(campioni) campioni: è uno scalino")
        #expect(campioni < Int(WaveIsland.samplesPerSecond * 0.4),
                "e non deve nemmeno strisciare: \(campioni) campioni")
    }

    /// **The hold is what stops the pumping, and this is where it is proved.**
    ///
    /// A gap between two syllables — 150 ms of near-silence in the middle of a
    /// phrase — must not cost the wave any height at all. Under the old tuning it
    /// cost about half of it, several times a second, which is exactly what he
    /// was looking at: «vibra tanto ed è fastidioso a vedersi».
    ///
    /// The negative pole is in the same test on purpose: if `.diPrima` ever
    /// stopped collapsing, the green above would have stopped meaning anything.
    @Test func aGapBetweenSyllablesCostsNoHeight() {
        func dopoUnoStacco(_ taratura: Taratura, secondi: Double) -> Double {
            var e = Inviluppo()
            for _ in 0..<30 { e = e.avanzato(verso: 1, con: taratura) }   // un secondo di voce
            let pieno = e.livello
            for _ in 0..<Int(WaveIsland.samplesPerSecond * secondi) {
                e = e.avanzato(verso: 0, con: taratura)
            }
            return e.livello / pieno
        }
        #expect(dopoUnoStacco(.viva, secondi: 0.15) == 1.0,
                "uno stacco di sillaba ha abbassato l'onda")
        #expect(dopoUnoStacco(.viva, secondi: 0.45) > 0.85,
                "uno stacco di parola ha abbassato l'onda troppo")
        #expect(dopoUnoStacco(.diPrima, secondi: 0.15) < 0.6,
                "la taratura di prima NON collassa più: il polo negativo è morto")
    }

    /// And the opposite: a real silence has to bring it down. A hold long enough
    /// to swallow a pause would be the defect of 2026-08-16 in the other
    /// direction — «semplicemente scorre verso destra, non dà l'idea di qualcosa
    /// che sale e scende come l'audio».
    ///
    /// **The window is derived and not written down**, which is the change of
    /// 2026-08-17: this used to say «after 1.5 s it is below 0.1», and 1.5 was the
    /// tail of that day's release copied into a test. Lengthening the release
    /// would have failed it for the right reason and with a wrong message. Now it
    /// asks the tuning how long its own tail is and checks it keeps that promise.
    @Test func arealSilenceStillBringsTheWaveDown() {
        /// Il silenzio, campione per campione: la frazione dell'altezza piena a
        /// ogni istante dopo l'ultima voce.
        func discesa(campioni: Int) -> [Double] {
            var e = Inviluppo()
            for _ in 0..<30 { e = e.avanzato(verso: 1, con: .viva) }
            let pieno = e.livello
            return (0..<campioni).map { _ -> Double in
                e = e.avanzato(verso: 0, con: .viva)
                return e.livello / pieno
            }
        }
        let quota = 0.05
        let previsto = Taratura.viva.coda(fino: quota)
        let passo = 1 / WaveIsland.samplesPerSecond
        let curva = discesa(campioni: Int((previsto * 2 * WaveIsland.samplesPerSecond).rounded(.up)))
        guard let sceso = curva.firstIndex(where: { $0 < quota }) else {
            Issue.record("in silenzio l'onda non scende mai sotto il \(quota * 100)%")
            return
        }
        // **Due misure indipendenti dello stesso fatto**: la forma chiusa di
        // `Taratura.coda` e il conteggio sui campioni. Devono coincidere entro un
        // campione — se divergono di più, a sbagliare è la formula, ed è il
        // confronto a scoprirlo (OperationalLessons, 2026-08-05).
        let misurato = Double(sceso + 1) * passo
        #expect(abs(misurato - previsto) <= passo,
                "la coda dichiarata è \(previsto) s, quella contata sui campioni \(misurato) s")

        // Il polo che tiene onesto il primo: la discesa dev'essere una discesa, non
        // un interruttore. A metà della coda dev'essere ancora chiaramente su —
        // altrimenti «scende sotto il 5% entro la coda» sarebbe soddisfatto anche
        // da un crollo istantaneo, che è il difetto che lui ha segnalato.
        let aMetà = curva[min(curva.count - 1, Int(previsto / 2 * WaveIsland.samplesPerSecond))]
        #expect(aMetà > 0.15, "a metà coda è già a \(aMetà): si spegne invece di dissolversi")
    }

    /// **La coda, in secondi, ed è la manopola che ha toccato il 17/08.**
    ///
    /// Sue parole: «l'isoletta è bellina, mi piace, l'unica cosa è che si
    /// appiattisce troppo rapidamente quando smetto di parlare». Il rilascio è
    /// passato da 0,15 a 0,08, cioè da una coda di 0,61 s a una di 1,20 s.
    ///
    /// La forbice è quella che il brief ha chiesto. I due poli sono che la coda
    /// dev'essere abbastanza lunga da leggersi come un dissolversi e abbastanza
    /// corta da non lasciare l'isola accesa dopo che ha smesso di parlare.
    @Test func theTailDissolvesInsteadOfSwitchingOff() {
        let rilascio = Taratura.viva.secondiPerScendere(a: 0.05)
        #expect(rilascio > 1.0 && rilascio < 1.4,
                "il rilascio dura \(rilascio) s: fuori dalla forbice chiesta il 17/08")
        // Tenuta e rilascio sono due cose diverse e la tenuta NON è stata toccata:
        // è lei a reggere l'altezza dentro una frase, ed è il criterio 1 del banco.
        #expect(Taratura.viva.secondiDiTenuta == 0.80)
        // Il polo negativo: la misura deve distinguere: la taratura di prima aveva
        // il rilascio corto, e se le due codine risultassero uguali questo test
        // starebbe leggendo una costante invece di un comportamento.
        #expect(Taratura.diPrima.secondiPerScendere(a: 0.05) < rilascio * 0.75,
                "la coda di prima non risulta più corta: la misura non vede il rilascio")
    }

    /// **The syllabic detail exists, and it never touches the height.**
    ///
    /// Run a written phrase — the one the film uses — through both envelopes and
    /// check the two halves of the bargain: the height stays put inside the
    /// phrase, and the difference between fast and slow, which is what nudges the
    /// crests, does move. A `detail` that never left zero would mean the
    /// horizontal life had been taken away along with the vertical one.
    @Test func theSyllablesLiveInTheDetailAndNotInTheHeight() {
        var lento = Inviluppo(), veloce = Inviluppo()
        var altezze: [Double] = [], dettagli: [Double] = []
        let campioni = Int(MisuraPompaggio.ProfiloParlato.durata * WaveIsland.samplesPerSecond)
        for n in 0..<campioni {
            let obiettivo = WaveIsland.normalize(rms: MisuraPompaggio.ProfiloParlato.rms(campione: n))
            lento = lento.avanzato(verso: obiettivo, con: .viva)
            veloce = veloce.avanzato(verso: obiettivo, con: .sillabica)
            // Solo il parlato assestato, le stesse finestre del filmato.
            let t = Double(n) / WaveIsland.samplesPerSecond
            guard MisuraPompaggio.ProfiloParlato.finestraParlata.contains(t) else { continue }
            altezze.append(lento.livello)
            dettagli.append(veloce.livello - lento.livello)
        }
        let minimo = altezze.min() ?? 0, massimo = altezze.max() ?? 1
        #expect(minimo / massimo >= MisuraPompaggio.Soglia.tenuta,
                "l'altezza è collassata a \(minimo / massimo) del suo massimo dentro il parlato")
        let escursione = (dettagli.max() ?? 0) - (dettagli.min() ?? 0)
        #expect(escursione > 0.15, "il dettaglio sillabico è piatto (\(escursione)): niente spinta")
    }

    /// The same phrase under the old tuning **must** collapse: this is the bench's
    /// negative pole in pure arithmetic, alongside the one measured on pixels.
    @Test func theOldTuningPumpsOnTheSamePhrase() {
        var e = Inviluppo()
        var altezze: [Double] = []
        let campioni = Int(MisuraPompaggio.ProfiloParlato.durata * WaveIsland.samplesPerSecond)
        for n in 0..<campioni {
            let obiettivo = WaveIsland.normalize(rms: MisuraPompaggio.ProfiloParlato.rms(campione: n),
                                                 con: .diPrima)
            e = e.avanzato(verso: obiettivo, con: .diPrima)
            let t = Double(n) / WaveIsland.samplesPerSecond
            guard MisuraPompaggio.ProfiloParlato.finestraParlata.contains(t) else { continue }
            altezze.append(e.livello)
        }
        let rapporto = (altezze.min() ?? 0) / (altezze.max() ?? 1)
        #expect(rapporto < MisuraPompaggio.Soglia.tenuta,
                "la taratura di prima passa il criterio della tenuta (\(rapporto)): il banco non misura il pompaggio")
    }

    // MARK: - The colour, as it is stored

    /// The persistence contract: four numbers separated by spaces, so
    /// `defaults read app.kalamos.mac waveTint` is readable by a person.
    @Test func aTintIsStoredAsFourReadableNumbers() {
        for raw in [WaveTint.defaultWave, WaveTint.defaultShell,
                    WaveTint.string(from: WavePalette.wave[3].color)] {
            let parts = raw.split(separator: " ").map(String.init)
            #expect(parts.count == 4, "\(raw) is not \"r g b a\"")
            #expect(parts.allSatisfy { Double($0) != nil })
            #expect(parts.allSatisfy { (Double($0) ?? -1) >= 0 && (Double($0) ?? 2) <= 1 })
        }
    }

    @Test func everyPaletteColourSurvivesTheRoundTrip() {
        for tint in WavePalette.wave + WavePalette.shell {
            let there = WaveTint.string(from: tint.color)
            let back = WaveTint.string(from: WaveTint.color(from: there))
            #expect(TintRow.sameColour(there, back), "\(tint.name) did not survive: \(there) → \(back)")
        }
    }

    /// A setting read back as nonsense must fall back, not paint an invisible
    /// wave. The empty string is the case that actually happens: a key that was
    /// never written.
    @Test func nonsenseFallsBackToTheFamilyPen() {
        let pen = WaveTint.string(from: WaveTint.color(from: WaveTint.defaultWave))
        for bad in ["", "boh", "1 2", "0.1 0.2 0.3", "0.1 0.2 0.3 0.4 0.5"] {
            #expect(WaveTint.string(from: WaveTint.color(from: bad)) == pen,
                    "\"\(bad)\" should have fallen back to the pen")
        }
    }

    /// The pill that is lit has to be the pill he clicked. Comparing the strings
    /// exactly would light none of them, because the `Color → NSColor → sRGB` trip
    /// shaves the third decimal — and the negative pole says the tolerance did not
    /// go so wide that two different colours became one.
    @Test func theChosenPillIsTheOneHeClicked() {
        #expect(TintRow.sameColour("0.184 0.361 0.541 1.0", "0.1841 0.3609 0.5412 1.0"))
        #expect(!TintRow.sameColour("0.184 0.361 0.541 1.0", "0.850 0.250 0.200 1.0"))
        #expect(!TintRow.sameColour("0.184 0.361 0.541 1.0", ""))
        // Two pills of the same row are never the same colour, or one of them can
        // never be selected.
        for row in [WavePalette.wave, WavePalette.shell] {
            let values = row.map { WaveTint.string(from: $0.color) }
            for (i, a) in values.enumerated() {
                for b in values[(i + 1)...] {
                    #expect(!TintRow.sameColour(a, b), "\(a) and \(b) are indistinguishable")
                }
            }
        }
    }

    // MARK: - Where the island comes back

    /// The saved spot survives; a spot on a monitor that is no longer plugged in
    /// does not, because an island whose grab handle is off-screen cannot be
    /// brought back.
    @MainActor
    @Test func aSavedSpotSurvivesButAnUnreachableOneDoesNot() throws {
        let screen = try #require(NSScreen.main)
        let inside = NSPoint(x: screen.frame.midX - 200, y: screen.frame.midY)
        let raw = "\(Int(inside.x)) \(Int(inside.y))"
        let recovered = try #require(IslandPanel.savedCenter(raw, screen: screen))
        #expect(abs(recovered.x - inside.x) < 1 && abs(recovered.y - inside.y) < 1)

        // `nil` resta per una stringa che non è due numeri: è l'unico caso in cui
        // davvero non si sa niente.
        #expect(IslandPanel.savedCenter("", screen: screen) == nil)
        #expect(IslandPanel.savedCenter("boh", screen: screen) == nil)
        #expect(IslandPanel.savedCenter("100", screen: screen) == nil)

        // **Il monitor che se n'è andato cambia verdetto il 19/08.** Prima queste
        // due righe volevano `nil`, e chi chiamava cadeva sul default: la sua
        // scelta spariva. Un punto salvato contro uno schermo staccato non è un
        // dato corrotto, è un dato giusto per un mondo che non c'è più, e la
        // risposta proporzionata è riportarlo dentro l'area visibile.
        let visibile = screen.visibleFrame
        let guscio = IslandPanel.shellSize(for: .libera)
        for grezzo in ["-9000 -9000", "40000 40000"] {
            let riportato = try #require(IslandPanel.savedCenter(grezzo, screen: screen))
            #expect(visibile.insetBy(dx: guscio.width / 2 - 1, dy: guscio.height / 2 - 1)
                        .contains(riportato),
                    "\(grezzo) è tornato dentro solo a metà: \(riportato)")
        }
    }

    /// **The saved point is the CENTRE, and that is what makes the two shapes
    /// interchangeable.**
    ///
    /// The island is 400×128 in the notch and a circle 112 across once it is free,
    /// and dragging it out of the notch changes the shape under his hand. Saved as
    /// a corner, the same number would put the circle 144 points left and 8 points
    /// down of where the rectangle was — a jump nobody asked for, in the one
    /// gesture whose whole promise is "it stays where I put it". Saved as a
    /// centre, the middle is the middle for both.
    @MainActor
    @Test func theSavedPointIsTheCentreSoTheShapeCanChange() throws {
        let screen = try #require(NSScreen.main)
        let dropped = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let raw = "\(Int(dropped.x)) \(Int(dropped.y))"
        let centre = try #require(IslandPanel.savedCenter(raw, screen: screen))

        // The same saved number, read by both shapes: the middles of what he SEES
        // coincide. Placed by the rule `place()` uses — the window offset by where
        // the island sits inside it, never by the window's own middle.
        for position in WavePosition.allCases {
            let shell = IslandPanel.shellFrame(for: position)
            let origin = NSPoint(x: centre.x - shell.midX, y: centre.y - shell.midY)
            let island = NSPoint(x: origin.x + shell.midX, y: origin.y + shell.midY)
            #expect(abs(island.x - dropped.x) < 0.5 && abs(island.y - dropped.y) < 0.5,
                    "\(position) came back at \(island) instead of \(dropped)")
        }
    }

    // MARK: - The free island is round

    /// The two shapes, as measurements rather than as a look: the notch island is
    /// a wide band, the free one is a SMALL PILL.
    ///
    /// «una piccola pillola… non grande come quello del notch, decisamente più
    /// piccolo» (2026-08-16). Two of these lines are the words turned into
    /// numbers: a pill is much wider than it is tall, and it is decidedly smaller
    /// than the notch island — not a bit smaller, a quarter of its area at most.
    /// The upper bounds are what stop it drifting back towards the band it was
    /// asked not to be.
    @Test func theFreeIslandIsASmallPill() {
        let notch = IslandPanel.shellSize(for: .notch)
        #expect(notch.width == IslandPanel.width && notch.height == IslandPanel.height)
        #expect(notch.width > notch.height * 2, "the notch island is a band")

        let pill = IslandPanel.shellSize(for: .bassoCentro)
        #expect(pill == BubbleGeometry.size)
        #expect(pill.width > pill.height * 2.5, "a pill is long and low, not a lozenge")
        // Small, and said in numbers so "small" cannot drift.
        #expect(pill.width <= notch.width / 2, "as wide as half the band, at most")
        #expect(pill.height <= notch.height / 2)
        #expect(pill.width * pill.height <= notch.width * notch.height / 4)
        // And not so small it stops being visible from across the desk.
        #expect(pill.width >= 120 && pill.height >= 30)
    }

    /// The pill's ceiling: flat down the middle, closing only on the two caps.
    ///
    /// This is the shape's whole argument over the circle it replaced, so it is
    /// worth holding in numbers: on a circle the room above the axis starts
    /// shrinking the moment you leave the centre, so most of the island could not
    /// hold a crest. On a pill the middle is all full height.
    @Test func thePillIsFlatInTheMiddleAndClosesOnlyAtTheEnds() {
        let shell = BubbleGeometry.size
        let r = shell.height / 2
        let straight = shell.width / 2 - r

        #expect(BubbleGeometry.halfHeight(atDistance: 0, in: shell) == r)
        #expect(BubbleGeometry.halfHeight(atDistance: straight, in: shell) == r,
                "the straight part must keep full height right up to the cap")
        #expect(BubbleGeometry.halfHeight(atDistance: shell.width / 2, in: shell) == 0,
                "the pill has closed by its own end")
        // Monotone on the cap, and symmetric.
        var previous = r
        for step in 0...20 {
            let dx = straight + (r * CGFloat(step) / 20)
            let here = BubbleGeometry.halfHeight(atDistance: dx, in: shell)
            #expect(here <= previous + 0.0001, "the cap must not rise again at \(dx)")
            #expect(here == BubbleGeometry.halfHeight(atDistance: -dx, in: shell))
            previous = here
        }
    }

    /// **The crests must not die against the rounded ends**, and this is the test
    /// that says so in numbers instead of in a screenshot.
    ///
    /// The wave now runs the whole length of the pill, because the thread has to
    /// reach both ends. What keeps the crests off the caps is therefore not a
    /// smaller box — that was the old arrangement, and it is exactly the one he
    /// rejected — but `BubbleGeometry.profile`, which lowers the ceiling where the
    /// pill closes. The claim is that every ribbon, at every phase, stays under
    /// the edge with the halo's width to spare.
    ///
    /// The maths is the app's own (`WaveModel`, `NastroOnda.nastri`), the geometry
    /// is the island's own (`BubbleGeometry`) and the fill fraction is the
    /// drawing's own (`WaveCanvas.riempimento`): a probe that recopied any of the
    /// three would end up measuring itself the day one of them moved
    /// (OperationalLessons, 2026-08-05).
    @Test func theWaveNeverDiesAgainstTheRoundedEnd() {
        let shell = BubbleGeometry.size
        let box = BubbleGeometry.waveSize(in: shell)
        let profile = BubbleGeometry.profile(box: box, in: shell)

        /// The tallest ordinate anywhere at this x, over a full sweep of phases:
        /// the envelope's centre drifts, so the tall part of the wave visits every
        /// x in turn and one instant proves nothing.
        func tallest(at u: Double) -> Double {
            var top = 0.0
            for tick in 0..<400 {
                let t = Double(tick) * 0.05
                for nastro in NastroOnda.nastri {
                    let (dorso, ventre) = WaveModel.ordinate(x: u, t: t, livello: 1, nastro: nastro)
                    top = max(top, max(abs(dorso), abs(ventre)))
                }
            }
            return top
        }

        var worst = CGFloat.greatestFiniteMagnitude
        var worstAt = 0.0
        for step in 0...200 {
            let u = Double(step) / 100 - 1                     // −1 … 1 across the box
            let dx = CGFloat(u) * box.width / 2
            let ceiling = BubbleGeometry.halfHeight(atDistance: abs(dx), in: shell)
            // How `WaveCanvas` turns an ordinate into points, profile included.
            let drawn = CGFloat(tallest(at: u) * WaveCanvas.riempimento * profile(u))
                * (box.height / 2)
            let room = ceiling - drawn - BubbleGeometry.glowMargin * CGFloat(profile(u))
            if room < worst { worst = room; worstAt = u }
        }
        #expect(worst >= 0,
                "the wave reaches the edge at x=\(worstAt): \(worst) points short of the halo")

        // The negative pole, and without it the line above is just a number that
        // happened to be positive: the same full-width box drawn WITHOUT the
        // profile — which is what a rectangle gets — must collide with the caps.
        // The day this stops failing, the check above has stopped checking
        // anything, because the profile would have stopped doing anything.
        var collides = false
        for step in 0...200 {
            let u = Double(step) / 100 - 1
            let ceiling = BubbleGeometry.halfHeight(atDistance: abs(CGFloat(u) * box.width / 2),
                                                    in: shell)
            let drawn = CGFloat(tallest(at: u) * WaveCanvas.riempimento) * (box.height / 2)
            if drawn > ceiling { collides = true }
        }
        #expect(collides, "a full-width wave should be cut by the pill's ends — it was not")
    }

    /// **The thread runs from one end to the other.**
    ///
    /// His words, 2026-08-16: «il filo dell'onda deve essere da un estremo
    /// all'altro, non in mezzo e basta». Two things had to be true for that, and
    /// this holds both.
    ///
    /// The envelope keeps a floor, so there is still a ribbon at the very edges
    /// instead of nothing; and the box is the whole width of the shell, so the
    /// axis the thread is drawn on spans the island rather than a strip in the
    /// middle of it. The negative pole is the envelope with no floor — the shape
    /// it had before — which dies to nothing at the ends.
    @Test func theThreadReachesBothEnds() {
        #expect(BubbleGeometry.waveWidthRatio == 1,
                "a box narrower than the shell leaves the thread short of the ends")

        // At the extremes, over a full sweep of phases, the envelope never goes
        // to nothing: something is always drawn out there.
        var weakest = Double.greatestFiniteMagnitude
        for tick in 0..<400 {
            let t = Double(tick) * 0.05
            for u in [-1.0, -0.95, 0.95, 1.0] {
                weakest = min(weakest, WaveModel.campana(u, t: t))
            }
        }
        #expect(weakest > 0.2, "the wave dies at the ends: envelope down to \(weakest)")

        // The negative pole: without the floor the same envelope reaches zero, and
        // that is precisely the picture he objected to.
        let senzaFondo = (WaveModel.campana(1, t: 0) - WaveModel.bordoVivo)
            / (1 - WaveModel.bordoVivo)
        #expect(senzaFondo < 0.05,
                "the floor is carrying nothing — the envelope was already alive at the edge")
    }

    /// **The ribbons settle INTO the thread at the ends; they are not sliced by
    /// the edge.**
    ///
    /// This is the second half of what he asked for, and the two halves pull in
    /// opposite directions: the thread has to reach the edge, so the canvas is the
    /// full width of the shell — but a ribbon at full height against that same
    /// edge gets cut off flat, and an amputated crest reads as a drawing error.
    /// The taper is what lets both be true, and it is deliberately NOT the old
    /// margin under a new name: the margin shrank the canvas, so it shortened the
    /// thread too, which is the gap he photographed.
    @Test func theRibbonsFadeIntoTheThreadAtTheEnds() {
        let profilo = WaveCanvas.profiloSfumato()

        // Full height across the middle: the taper must not quietly become a
        // margin that flattens the whole wave.
        for u in stride(from: -0.8, through: 0.8, by: 0.1) {
            #expect(profilo(u) == 1, "the wave is being held down at x=\(u)")
        }
        // And gone by the edges, where the shell cuts.
        #expect(profilo(1) < 0.01)
        #expect(profilo(-1) < 0.01)
        // Monotone and symmetric through the taper, with no knee: a linear ramp
        // shows the exact point where the fade starts.
        var previous = 1.0
        for step in 0...20 {
            let u = 0.88 + 0.12 * Double(step) / 20
            let here = profilo(u)
            #expect(here <= previous + 1e-9, "the taper rises again at \(u)")
            #expect(abs(here - profilo(-u)) < 1e-9)
            previous = here
        }

        // The negative pole: with no taper the same edge keeps full height, which
        // is the sliced crest. If this ever stops being true, the taper above has
        // stopped meaning anything.
        #expect(WaveCanvas.profiloPieno(1) == 1)
        #expect(WaveCanvas.profiloSfumato(coda: 0)(1) == 1)
    }

    /// The halo is drawn beyond the wave's own path, so the margin above has to
    /// cover it. It lives in the vendored `WaveformView`, where nothing forces the
    /// two numbers to agree — hence a guard that reads the file, in the manner of
    /// `SourceGuardTests`: change the blur and this fails, pointing at the
    /// constant that has to follow.
    @Test func theHaloFitsInsideTheMarginItIsGiven() throws {
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Kalamos/Onda/WaveformView.swift")
        let text = try String(contentsOf: view, encoding: .utf8)
        let radius = text
            .components(separatedBy: ".blur(radius: ").dropFirst()
            .compactMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
        #expect(!radius.isEmpty, "no blur found in WaveformView — did the halo move?")
        for r in radius {
            #expect(CGFloat(r) <= BubbleGeometry.glowMargin,
                    "the halo is \(r) wide and BubbleGeometry.glowMargin is \(BubbleGeometry.glowMargin)")
        }
    }

    /// Le stringhe salvate sono un contratto: rinominare un caso rimette in
    /// silenzio la posizione di tutti sul notch.
    @Test func positionsKeepTheirStoredNames() {
        #expect(WavePosition.notch.rawValue == "notch")
        #expect(WavePosition.bassoCentro.rawValue == "bassoCentro")
        #expect(WavePosition.libera.rawValue == "libera")
        #expect(WavePosition(rawValue: "notch") == .notch)
        #expect(WavePosition(rawValue: "quello di prima") == nil)
        // `bubble` è il mondo di ieri e NON deve più essere un nome valido: se lo
        // fosse, la migrazione non verrebbe mai interrogata.
        #expect(WavePosition(rawValue: "bubble") == nil)
        // Due posizioni disegnano la pillola, una sola è la banda.
        #expect(!WavePosition.notch.disegnaPillola)
        #expect(WavePosition.bassoCentro.disegnaPillola && WavePosition.libera.disegnaPillola)
        // E una sola porta con sé dei numeri.
        #expect(WavePosition.libera.salvaCoordinate)
        #expect(!WavePosition.notch.salvaCoordinate && !WavePosition.bassoCentro.salvaCoordinate)
    }

    // MARK: - A placement of ours is not a drag

    /// The one piece here that broke while being written, and would have broken
    /// silently.
    ///
    /// `didMove` fires for OUR `setFrameOrigin` exactly as it does for his hand, so
    /// the panel guards it with a flag — and with the observer on a queue the block
    /// ran after the flag had already been cleared, which filed every placement as
    /// a drag and flipped the position to `bubble` the first time the island was
    /// shown in the notch. Indistinguishable from a setting that does not stick.
    ///
    /// Two poles, and the second one is what makes the first mean anything: a real
    /// move MUST be reported, or "nothing was reported" would also be true of a
    /// panel that reports nothing at all. `onDrag` is injected so neither pole can
    /// write into the real settings.
    /// **L'isola sopravvive al cambio di schermata**, e la prova legge la
    /// finestra VIVA invece della costante.
    ///
    /// Sua richiesta del 2026-08-16: «quando passo da una schermata all'altra, il
    /// notch resti persistente con l'onda che va, e non che compaia e
    /// scompaia... soprattutto con lo schermo intero dà problemi». I tre flag
    /// erano due: mancava `stationary`, che è quello che tiene la finestra
    /// inchiodata allo schermo mentre le scrivanie scorrono sotto invece di
    /// farla scivolare via insieme al desktop.
    ///
    /// **Sulla finestra costruita e non su `comportamentoPersistente`**, perché
    /// una costante giusta e un `init` che si dimentica di applicarla si leggono
    /// identiche nel sorgente — e la seconda lascia l'isola a sparire.
    ///
    /// Quello che questa prova NON può dire: se lo swipe è davvero fluido. Quello
    /// è un gesto del sistema che nessuno script fa partire, e resta del suo
    /// campo. Qui si chiude la causa, cioè i permessi della finestra.
    @MainActor
    @Test func theIslandLivesOnEverySpaceAndDoesNotSlide() {
        let panel = IslandPanel(island: WaveIsland.shared, state: AppState.shared,
                                alRilascio: { _ in })
        defer { panel.detach() }
        let esito = SondaPannello.esamina(panel)
        #expect(esito.mancanti.isEmpty, "flag mancanti: \(esito.mancanti.joined(separator: ", "))")
        #expect(esito.livelloBastante,
                "livello \(esito.livello.rawValue): sotto la barra di stato finisce dietro un'app a tutto schermo")
        #expect(!esito.nascondeQuandoInattiva, "l'isola sparisce quando Kalamos perde il fuoco")

        // Il polo negativo, sulla stessa finestra: senza `stationary` la sonda
        // deve accorgersene. Senza questo, «non manca niente» sarebbe vero anche
        // di una sonda che non guarda.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        #expect(SondaPannello.esamina(panel).mancanti == ["stationary"],
                "la sonda non vede la mancanza di stationary: non sta guardando i flag")
        panel.collectionBehavior = IslandPanel.comportamentoPersistente
    }

    /// **Il gesto non si cede al sistema**, e la prova legge la finestra viva.
    ///
    /// Misurato il 19/08 con `Scripts/sonda-aggancio.swift` su un pannello nudo
    /// con questi stessi flag: col trascinamento di AppKit, portandola contro il
    /// bordo superiore compaiono due `WindowManager Drag Guide Window` da
    /// 1542×905 (lo schermo velato, cioè il «vorrebbe prendere tutto lo schermo»)
    /// e al rilascio la finestra viene ributtata a metà schermo. Al centro,
    /// controllo dello stesso banco, non succede niente.
    ///
    /// Qui si chiude la causa: i due interruttori che cedevano il gesto. Che il
    /// velo non compaia più è il banco a dirlo, perché nessun test in-processo
    /// può vedere una finestra del WindowServer che non è nostra.
    @MainActor
    @Test func theDragBelongsToUsAndNotToTheSystem() {
        let panel = IslandPanel(island: WaveIsland.shared, state: AppState.shared,
                                alRilascio: { _ in })
        defer { panel.detach() }
        #expect(!panel.isMovable, "AppKit può ancora muovere la finestra: torna l'affiancamento")
        #expect(!panel.isMovableByWindowBackground,
                "il trascinamento dallo sfondo è di nuovo di sistema")
        // E qualcuno deve pur raccogliere il gesto al posto del sistema: senza il
        // monitor la pillola resterebbe immobile, che è peggio del difetto.
        #expect(panel.gestoOsservato, "nessuno guarda il trascinamento: la pillola è immobile")
    }

    /// **L'onda entra nella banda, e la banda comincia SOTTO l'hardware.**
    ///
    /// Difetto dal campo del 19/08, con la banda appena stretta a 96: «l'onda
    /// viene tagliata dal notch stesso». Erano due errori sovrapposti, e nessuno
    /// dei due si vedeva finché la banda era alta 128.
    ///
    /// Primo: l'onda aveva un'altezza scritta a mano, 72, e la somma faceva
    /// 32 + 72 + 12 = 116 punti dentro un guscio di 96 — venti punti sotto
    /// `.clipped()`. Secondo: la striscia riservata all'hardware era la costante
    /// 18, mentre `safeAreaInsets.top` su quello schermo dice **32**, quindi i
    /// primi quattordici punti dell'onda stavano dietro il notch fisico anche
    /// quando ci stavano dentro il guscio.
    ///
    /// La prova gira sui NUMERI e non sullo schermo di chi la esegue: una riga
    /// che asserisse `safeAreaInsets` proverebbe la macchina, non il codice.
    @Test func theWaveFitsUnderTheHardware() {
        let guscio = IslandPanel.height        // 96
        let striscia: CGFloat = 32             // quanto misura il suo notch
        let onda = IslandView.altezzaOnda(guscio: guscio, striscia: striscia)
        #expect(striscia + onda + IslandView.respiro * 2 == guscio,
                "la somma non torna: \(striscia) + \(onda) + \(IslandView.respiro * 2) contro \(guscio)")
        // Il polo negativo, che è la forma di prima: 72 non ci stava, e deve
        // continuare a non starci, altrimenti l'uguaglianza qui sopra passerebbe
        // per qualunque numero.
        #expect(striscia + 72 + IslandView.respiro * 2 > guscio,
                "la vecchia altezza fissa entrerebbe: la prova non sta misurando niente")
        // E stringendo ancora la banda l'onda si assottiglia invece di uscire.
        let stretta = IslandView.altezzaOnda(guscio: 80, striscia: striscia)
        #expect(stretta < onda && striscia + stretta + IslandView.respiro * 2 == 80)
        // Senza schermo, o su uno schermo senza notch, resta il valore di riserva.
        #expect(IslandEntrance.strisciaHardware(nil) == IslandEntrance.strisciaPredefinita)
    }

    /// **La transizione notch↔pillola è UNA funzione di UN progresso.**
    ///
    /// Il falsificatore di ISC-18, preso alla lettera: nessun fotogramma in cui la
    /// forma non sia né la banda, né la capsula, né un punto della curva fra le
    /// due; e nessuna seconda durata che si possa cambiare da sola.
    @Test func theShapeIsOneFunctionOfOneProgress() {
        let banda = IslandPanel.shellSize(for: .notch)
        let pillola = IslandPanel.shellSize(for: .libera)

        // Agli estremi coincide ESATTAMENTE con le due forme discrete: sono la
        // stessa funzione valutata in 0 e in 1, non due cose che si somigliano.
        #expect(IslandPanel.shellSize(progresso: 0) == banda)
        #expect(IslandPanel.shellSize(progresso: 1) == pillola)
        #expect(IslandPanel.shellFrame(progresso: 0) == IslandPanel.shellFrame(for: .notch))
        #expect(IslandPanel.shellFrame(progresso: 1) == IslandPanel.shellFrame(for: .libera))

        // Monotona, e senza salti: fra due passi vicini la taglia cambia di poco.
        var precedente = banda
        var saltoMax: CGFloat = 0
        for i in 1...100 {
            let g = IslandPanel.shellSize(progresso: Double(i) / 100)
            #expect(g.width <= precedente.width && g.height <= precedente.height,
                    "la forma torna indietro a \(i)%")
            saltoMax = max(saltoMax, precedente.width - g.width)
            precedente = g
        }
        #expect(saltoMax < (banda.width - pillola.width) / 20,
                "un passo dell'1% muove più di un ventesimo del percorso: è uno scatto travestito")

        // Ogni fotogramma è una forma VALIDA: i raggi non superano mai metà
        // altezza, che è la condizione perché una capsula sia una capsula.
        for i in 0...100 {
            let p = Double(i) / 100
            let g = IslandPanel.shellSize(progresso: p)
            let raggi = IslandView.sagoma(p: p, guscio: g).cornerRadii
            #expect(raggi.topLeading <= g.height / 2 + 1e-9 && raggi.bottomLeading <= g.height / 2 + 1e-9,
                    "a \(i)% il raggio supera metà altezza: la forma non esiste")
            #expect(g.width >= g.height, "a \(i)% la 'pillola' sarebbe più alta che larga")
        }
        // E i due capi sono le due forme volute: in cima squadrato nel notch,
        // capsula piena sulla pillola.
        #expect(IslandView.sagoma(p: 0, guscio: banda).cornerRadii.topLeading == 0)
        #expect(IslandView.sagoma(p: 1, guscio: pillola).cornerRadii.topLeading == pillola.height / 2)
    }

    /// **Il progresso viene dalla distanza, e da niente altro.**
    @Test func theProgressComesFromTheDistanceAlone() {
        let schermo = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let h = IslandPanel.shellSize(for: .notch).height
        let ancora = Ancore.centroNotch(schermo: schermo, altezzaGuscio: h)
        func p(_ d: CGFloat) -> Double {
            Ancore.progressoForma(centro: NSPoint(x: ancora.x, y: ancora.y - d),
                                  schermo: schermo, altezzaGuscioNotch: h)
        }
        // Dentro il raggio dell'aggancio è banda piena; oltre il distacco è
        // pillola piena. Gli estremi sono esatti, non «quasi».
        #expect(p(0) == 0)
        #expect(p(Ancore.raggioAggancio) == 0)
        #expect(p(Ancore.raggioDistacco) == 1)
        #expect(p(Ancore.raggioDistacco + 500) == 1)
        // In mezzo cresce, e a metà strada sta a metà: `smoothstep` è simmetrica.
        let mezzo = (Ancore.raggioAggancio + Ancore.raggioDistacco) / 2
        #expect(abs(p(mezzo) - 0.5) < 1e-9)
        #expect(p(mezzo - 20) < p(mezzo) && p(mezzo) < p(mezzo + 20))
        // Derivata nulla ai capi: è ciò che toglie lo scatto in partenza e in
        // arrivo anche se i numeri sono già continui.
        #expect(p(Ancore.raggioAggancio + 1) < 0.001)
        #expect(p(Ancore.raggioDistacco - 1) > 0.999)
    }

    /// **Anche il disegno dentro si mescola**, che è la metà del passaggio che
    /// nessuno guarda: i due profili dell'onda non sono intercambiabili.
    @Test func theWaveProfileBlendsToo() {
        let guscio = IslandPanel.shellSize(for: .libera)
        let riquadro = BubbleGeometry.waveSize(in: guscio)
        let banda = WaveCanvas.profiloSfumato()
        let pillola = BubbleGeometry.profile(box: riquadro, in: guscio)
        for u in stride(from: -1.0, through: 1.0, by: 0.1) {
            #expect(abs(IslandView.profiloMisto(p: 0, riquadro: riquadro, guscio: guscio)(u) - banda(u)) < 1e-12)
            #expect(abs(IslandView.profiloMisto(p: 1, riquadro: riquadro, guscio: guscio)(u) - pillola(u)) < 1e-12)
        }
        // Il polo che tiene onesto il resto: i due profili sono DIVERSI, altrimenti
        // mescolarli non vorrebbe dire niente.
        #expect(stride(from: -1.0, through: 1.0, by: 0.1).contains { abs(banda($0) - pillola($0)) > 0.05 },
                "i due profili coincidono: la mescolanza non sta facendo niente")
    }

    // MARK: - Le ancore

    /// **Un rilascio vicino a un'ancora salva il NOME; lontano da tutte, no.**
    ///
    /// I due poli sono la sostanza della regola, non un contorno: senza il
    /// secondo, «si aggancia» sarebbe vero anche di una funzione che aggancia
    /// sempre, cioè che toglie di mezzo il modo `libera`.
    @Test func aDropNearAnAnchorTakesItsName() {
        // Il suo schermo, misurato il 19/08.
        let schermo = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visibile = NSRect(x: 0, y: 74, width: 1512, height: 875)
        let hNotch = IslandPanel.shellSize(for: .notch).height

        // La sua posizione vera, `waveCenter = "754 114"`: due punti dall'ancora.
        #expect(Ancore.aggancio(centro: NSPoint(x: 754, y: 114), schermo: schermo,
                                visibile: visibile, altezzaGuscioNotch: hNotch) == .bassoCentro)
        // Appesa in cima.
        let cimaSuo = Ancore.centroNotch(schermo: schermo, altezzaGuscio: hNotch)
        #expect(Ancore.aggancio(centro: cimaSuo, schermo: schermo,
                                visibile: visibile, altezzaGuscioNotch: hNotch) == .notch)
        // Il polo negativo: in mezzo allo schermo non c'è niente da agganciare.
        #expect(Ancore.aggancio(centro: NSPoint(x: 400, y: 500), schermo: schermo,
                                visibile: visibile, altezzaGuscioNotch: hNotch) == nil)
        // E appena fuori dal raggio nemmeno, altrimenti «vicino» non vuol dire niente.
        let bassa = Ancore.centroBasso(visibile: visibile)
        #expect(Ancore.aggancio(centro: NSPoint(x: bassa.x, y: bassa.y + Ancore.raggioAggancio + 1),
                                schermo: schermo, visibile: visibile,
                                altezzaGuscioNotch: hNotch) == nil)
    }

    /// **L'ancora bassa sta 40 punti sopra l'AREA VISIBILE**, non 114 sopra lo
    /// schermo, ed è la correzione del 19/08.
    ///
    /// La misura del 18/08 diceva 114 e chiedeva di riferirla al `visibleFrame`:
    /// applicate insieme, le due avrebbero alzato l'isola di 74 punti rispetto a
    /// dove ce l'ha davvero, perché i 114 erano contati dal bordo dello schermo e
    /// sotto ci sono 74 punti di Dock.
    @Test func theBottomAnchorReproducesHisRealPosition() {
        let visibile = NSRect(x: 0, y: 74, width: 1512, height: 875)
        let c = Ancore.centroBasso(visibile: visibile)
        #expect(c.x == 756, "il centro orizzontale è quello dell'area visibile")
        #expect(c.y == 114, "40 sopra il visibile sono i suoi 114 sopra lo schermo")
        // Il polo che tiene onesto il numero: nascosto il Dock, l'ancora scende
        // con l'area visibile invece di restare inchiodata a 114.
        let senzaDock = NSRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Ancore.centroBasso(visibile: senzaDock).y == 40)
    }

    /// **Una posizione salvata contro uno schermo che non c'è più torna dentro**,
    /// invece di essere buttata.
    @Test func aSavedPositionIsBroughtBackInsteadOfDropped() {
        let visibile = NSRect(x: 0, y: 74, width: 1512, height: 875)
        let guscio = BubbleGeometry.size
        // Salvata su un monitor largo 2560: la x è fuori, la y no. Il riporto
        // tocca SOLO l'asse che sfora — questa riga è nata sbagliata, chiedendo
        // che si muovesse anche la y, e il rosso l'ha corretta.
        let riportata = Ancore.dentroVisibile(NSPoint(x: 2400, y: 900),
                                              visibile: visibile, guscio: guscio)
        #expect(riportata.x == visibile.maxX - guscio.width / 2)
        #expect(riportata.y == 900, "la y era già dentro e non si tocca")
        // Un punto fuori da entrambi i lati: tornano dentro tutti e due.
        let sopra = Ancore.dentroVisibile(NSPoint(x: -500, y: 5000),
                                          visibile: visibile, guscio: guscio)
        #expect(sopra.x == visibile.minX + guscio.width / 2)
        #expect(sopra.y == visibile.maxY - guscio.height / 2)
        // Il polo negativo: un punto già dentro non si tocca, o il riporto
        // diventerebbe uno spostamento a ogni avvio.
        let dentro = NSPoint(x: 700, y: 400)
        #expect(Ancore.dentroVisibile(dentro, visibile: visibile, guscio: guscio) == dentro)
    }

    /// **La migrazione guarda DOVE stava**, non indovina.
    @Test func theMigrationLooksAtWhereItWas() {
        let visibile = NSRect(x: 0, y: 74, width: 1512, height: 875)
        // Il suo caso vero: `bubble` con centro 754 114 → l'ancora bassa, e non si
        // sposta niente.
        #expect(Ancore.migra(vecchioValore: "bubble", centroSalvato: NSPoint(x: 754, y: 114),
                             visibile: visibile) == .bassoCentro)
        // Un punto suo, lontano dall'ancora: resta dov'è, e diventa `libera`.
        #expect(Ancore.migra(vecchioValore: "bubble", centroSalvato: NSPoint(x: 300, y: 700),
                             visibile: visibile) == .libera)
        // I poli negativi: un nome già nuovo non si migra, e nemmeno il notch.
        #expect(Ancore.migra(vecchioValore: "libera", centroSalvato: nil, visibile: visibile) == nil)
        #expect(Ancore.migra(vecchioValore: "notch", centroSalvato: nil, visibile: visibile) == nil)
    }

    /// **Le tre righe del contratto del rilascio**, una prova per riga.
    ///
    /// È la regola che scioglie la contraddizione fra «il trascinamento non
    /// decide il modo» e «lasciandola vicino a un'ancora si salva il nome».
    @Test func theThreeRowsOfTheDropContract() {
        let schermo = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visibile = NSRect(x: 0, y: 74, width: 1512, height: 875)
        let h = IslandPanel.shellSize(for: .notch).height
        func rilascio(_ p: NSPoint, _ imp: WavePosition) -> Ancore.Esito {
            Ancore.rilascio(centro: p, impostazione: imp, schermo: schermo,
                            visibile: visibile, altezzaGuscioNotch: h)
        }
        // (a) vicino a un'ancora → il nome, qualunque fosse l'impostazione.
        #expect(rilascio(NSPoint(x: 754, y: 114), .notch) == .nome(.bassoCentro))
        #expect(rilascio(NSPoint(x: 754, y: 114), .libera) == .nome(.bassoCentro))
        // (b) lontano da tutte, partendo da un'ancora → diventa libera e ci resta.
        // Era `.niente` fino alla sua correzione del 19/08 dal campo: «a meno che
        // io nell'ultima registrazione non l'ho tenuta lontana da quell'ancora,
        // in quel caso resta dove l'ho lasciata».
        #expect(rilascio(NSPoint(x: 300, y: 600), .notch) == .lontano(NSPoint(x: 300, y: 600)))
        #expect(rilascio(NSPoint(x: 300, y: 600), .bassoCentro) == .lontano(NSPoint(x: 300, y: 600)))
        // (c) lontano da tutte, in modo libera → le coordinate.
        #expect(rilascio(NSPoint(x: 300, y: 600), .libera) == .coordinate(NSPoint(x: 300, y: 600)))
    }

    // MARK: - Arriving and leaving

    /// The two positions must not enter the same way, and the difference is the
    /// point: from the notch the island slides out from under a physical edge, as
    /// a free island there is no edge to slide from, so it scales up instead.
    ///
    /// The negative pole is the one that matters — a free island that entered
    /// with an offset would be sliding in from a direction nobody chose, and a
    /// notch island that entered by scaling would pull away from the hardware it
    /// is supposed to continue.
    @Test func theTwoPositionsEnterFromDifferentPlaces() {
        // The drop: it starts as a lip the size of the notch and grows DOWNWARD
        // out of it. Squashed in both directions, anchored to the hardware, and
        // opaque from the first frame — it is made of the notch's own black.
        let notch = IslandEntrance.state(for: .notch, shown: false)
        #expect(notch.anchor == .top, "the drop hangs from the hardware")
        #expect(notch.scaleY < 0.25, "it must start as a lip, not as an island: \(notch.scaleY)")
        #expect(notch.scaleX < 0.6 && notch.scaleX > 0.3,
                "about as wide as the notch, and no wider: \(notch.scaleX)")
        #expect(notch.scaleX > notch.scaleY,
                "the lip is wider than it is deep — it is a strip of the hardware, not a dot")
        #expect(notch.opacity == 1, "a lip fading in under the hardware reads as a glow")

        // The bubble: no edge to be born from, so no stretch and no anchor — it
        // fades up in place with a short uniform scale.
        let bubble = IslandEntrance.state(for: .bassoCentro, shown: false)
        #expect(bubble.anchor == .center, "a free island grows from its own middle")
        #expect(bubble.scaleX == bubble.scaleY, "uniform: stretching it would invent an origin")
        #expect(bubble.scaleX > 0.85 && bubble.scaleX < 1,
                "a short scale, not a zoom: got \(bubble.scaleX)")
        #expect(bubble.opacity == 0)

        // Both end in exactly the same place: the exit is the entrance backwards,
        // so the settled state cannot depend on position.
        for position in WavePosition.allCases {
            let settled = IslandEntrance.state(for: position, shown: true)
            #expect(settled.scaleX == 1 && settled.scaleY == 1 && settled.opacity == 1,
                    "\(position) settles at \(settled)")
        }
    }

    /// **Whatever passes the window's edge is sliced off flat**, so what the
    /// movement does past its settled size is a fact about the window, not taste.
    ///
    /// Until 2026-08-17 the arrival was an under-damped spring that deliberately
    /// overshot, and this test tied the damping to `IslandPanel.bounceSlack`. The
    /// mirror of the exit's eased curve does not overshoot at all: it arrives at 1
    /// and stops. So the claim changes shape — it is now measured off the REAL
    /// curve at two hundred instants rather than off a spring formula — but it
    /// keeps doing the same job, which is stopping a future curve from being
    /// clipped in silence.
    @Test func theTransitionNeverPassesItsOwnSize() {
        func picco(_ curva: IslandEntrance.Curva) -> Double {
            var massimo = 0.0
            for i in 0...200 { massimo = max(massimo, curva.frazione(a: Double(i) / 200)) }
            return massimo
        }
        for entrando in [true, false] {
            let oltre = picco(IslandEntrance.curva(entrando: entrando)) - 1
            #expect(oltre <= 1e-9,
                    "la curva \(entrando ? "d'entrata" : "d'uscita") passa la propria misura di \(oltre)")
            #expect(CGFloat(max(0, oltre)) < IslandPanel.bounceSlack,
                    "quello che sborda (\(oltre)) non ci sta nel margine \(IslandPanel.bounceSlack)")
        }

        // **The negative pole: the sampler has to SEE an overshoot when there is
        // one.** A curve that shoots past its size — the classic `back` ease — must
        // come out over the margin, or the two greens above would be the answer to
        // a question nobody asked.
        let rimbalzante = IslandEntrance.Curva(x1: 0.34, y1: 1.8, x2: 0.64, y2: 1)
        #expect(picco(rimbalzante) - 1 > Double(IslandPanel.bounceSlack),
                "una curva che rimbalza NON deve entrare nel margine: il margine non misura niente")
    }

    /// The window is the island plus that room, and the island is where it is
    /// drawn — pinned to the top in the notch, so the shell keeps touching the
    /// hardware while the slack hangs underneath it.
    @Test func theWindowLeavesRoomWhereTheBounceGoes() {
        for position in WavePosition.allCases {
            let panel = IslandPanel.size(for: position)
            let shell = IslandPanel.shellSize(for: position)
            let frame = IslandPanel.shellFrame(for: position)
            #expect(panel.width > shell.width && panel.height > shell.height)
            #expect(frame.size == shell)
            #expect(frame.minX > 0 && frame.maxX < panel.width, "the sides share the slack")
        }
        // In the notch every point of slack is BELOW the island: the top edge of
        // the shell is the top edge of the window, or the black stops short of the
        // hardware it is supposed to continue.
        let notch = IslandPanel.shellFrame(for: .notch)
        #expect(notch.maxY == IslandPanel.size(for: .notch).height)
        // Free of it, the island floats in the middle of its own slack.
        let bubble = IslandPanel.shellFrame(for: .bassoCentro)
        #expect(bubble.midY == IslandPanel.size(for: .bassoCentro).height / 2)
    }

    /// The panel is taken off screen only AFTER the exit has finished drawing.
    ///
    /// Closing it on time would cut the last frames off, which is the abrupt thing
    /// the animation exists to remove, at the other end. Written as numbers
    /// precisely so this can be checked: an `Animation` cannot be asked how long
    /// it lasts.
    @Test func theWindowClosesOnlyAfterTheExitHasFinished() {
        #expect(WaveIsland.closeDelay > WaveIsland.exitDuration,
                "the window would close mid-exit: \(WaveIsland.closeDelay) ≤ \(WaveIsland.exitDuration)")
        // And not so long after it that a dead window sits between two dictations.
        #expect(WaveIsland.closeDelay < WaveIsland.exitDuration + 0.25)
    }

    /// Fast enough not to be waited for, slow enough to be seen — and now ONE
    /// number for both ends, which is the 2026-08-17 promise stated where a test
    /// can reach it.
    ///
    /// Both poles: a transition of 60 ms is the snap the animation exists to
    /// replace, one of a second would hold up a dictation that has already
    /// started.
    @Test func theTransitionLastsLongEnoughToBeSeen() {
        #expect(WaveIsland.durataTransizione > 0.10 && WaveIsland.durataTransizione < 0.50,
                "durata \(WaveIsland.durataTransizione): fuori dalla forbice fra lo scatto e l'attesa")
        // The one that matters: there is no second duration to drift. Reading the
        // exit's name has to land on the same number, or the symmetry is a claim
        // about two things that only happen to agree today.
        #expect(WaveIsland.exitDuration == WaveIsland.durataTransizione,
                "l'uscita ha una durata sua: l'entrata non può esserne il rovescio")
    }

    // MARK: - The wave answers the voice

    /// **The wave has to rise and fall with the voice, and this is the number.**
    ///
    /// His words on the field, 2026-08-16: «si muove poco quando parlo,
    /// semplicemente scorre verso destra, non dà l'idea di qualcosa che sale e
    /// scende come l'audio». The complaint is about a RATIO — how much taller the
    /// wave gets when he speaks — and a ratio is exactly the thing a screenshot
    /// cannot show and an opinion cannot settle.
    ///
    /// The band is measured through `MisuraMoto`, which calls the app's own maths
    /// inside the app's own container, and the claim is the one the brief set: at
    /// least twice as much vertical band at level 0.7 as at level 0.1.
    @Test func theBandAtLeastDoublesBetweenAQuietVoiceAndALoudOne() {
        let shell = BubbleGeometry.size
        let box = BubbleGeometry.waveSize(in: shell)
        let profile = BubbleGeometry.profile(box: box, in: shell)

        let quiet = MisuraMoto.banda(livello: 0.1, profilo: profile)
        let loud = MisuraMoto.banda(livello: 0.7, profilo: profile)
        #expect(loud >= quiet * 2,
                "the wave barely answers the voice: \(quiet) at 0.1 against \(loud) at 0.7")

        // And the two poles that stop the ratio being bought the cheap way — by
        // drawing nothing when quiet, or by never filling the island when loud.
        #expect(quiet > 0.10, "a quiet voice draws almost nothing: \(quiet)")
        #expect(loud > 0.55, "a normal voice never fills the island: \(loud)")
        // Silence is not a quiet voice: it must be flatter than both.
        #expect(MisuraMoto.banda(livello: 0, profilo: profile) < quiet / 2)
    }

    // MARK: - The arrival is the departure backwards

    /// **The claim he asked for on 2026-08-17, as a number.**
    ///
    /// His words: «quando si chiude mi piace, quindi facciamo che si deve aprire
    /// in maniera opposta a come si chiude però con lo stesso tipo di
    /// animazione». Opposite is a word; the trajectory sampled at two hundred
    /// instants in each direction is what can actually be checked, and what is
    /// checked is that the arrival at fraction `p` sits exactly where the
    /// departure sits at `1 - p` — every axis, and the opacity too.
    ///
    /// It cannot pass by accident: the curves are mirrored control points and the
    /// duration is a single constant, so the tolerance below is the bisection's
    /// own noise floor and nothing else. If a spring came back on one side, or a
    /// second duration appeared, the two trajectories would separate immediately.
    @Test func theArrivalIsTheDepartureRunBackwards() {
        let campioni = 200
        for position in WavePosition.allCases {
            var scarto = 0.0
            for i in 0...campioni {
                let p = Double(i) / Double(campioni)
                let entrando = IslandEntrance.traiettoria(for: position, progresso: p, entrando: true)
                let uscendo = IslandEntrance.traiettoria(for: position, progresso: 1 - p, entrando: false)
                scarto = max(scarto, abs(Double(entrando.scaleX - uscendo.scaleX)))
                scarto = max(scarto, abs(Double(entrando.scaleY - uscendo.scaleY)))
                scarto = max(scarto, abs(entrando.opacity - uscendo.opacity))
            }
            #expect(scarto < 1e-9,
                    "\(position): l'entrata non è l'uscita al contrario, scarto massimo \(scarto)")
        }

        // **The negative pole, and it is the defect itself put back.** Until this
        // morning the width waited 0.45 of the entrance before opening — that hold
        // is exactly what he was describing — so feeding it back in has to break
        // the check above. If it does not, the green is measuring nothing.
        var scartoColDifetto = 0.0
        for i in 0...campioni {
            let p = Double(i) / Double(campioni)
            let entrando = IslandEntrance.traiettoria(for: .notch, progresso: p,
                                                     entrando: true, attesaLarghezza: 0.45)
            let uscendo = IslandEntrance.traiettoria(for: .notch, progresso: 1 - p, entrando: false)
            scartoColDifetto = max(scartoColDifetto, abs(Double(entrando.scaleX - uscendo.scaleX)))
        }
        #expect(scartoColDifetto > 0.1,
                "rimessa l'attesa sulla larghezza la simmetria regge lo stesso (\(scartoColDifetto)): la prova non prova niente")
        // And the knob really is off in production, which is the other half.
        #expect(IslandEntrance.attesaLarghezza == 0,
                "l'attesa sulla larghezza è tornata viva: è il difetto del 16/08")
    }

    /// The mirroring is the mechanism the test above rests on, so it gets its own
    /// two lines: reversing a curve twice is the curve, and the reversal identity
    /// `rovesciata(p) == 1 - f(1 - p)` holds pointwise.
    ///
    /// Without this, a broken `rovesciata` that returned its input would make the
    /// symmetry test pass trivially — both directions would draw the same curve
    /// and agree with each other about a shape that is not the exit's.
    @Test func reversingTheCurveIsTimeReversalAndNothingElse() {
        let uscita = IslandEntrance.curvaUscita
        let entrata = IslandEntrance.curvaEntrata
        #expect(entrata != uscita, "la curva d'entrata è identica a quella d'uscita: non è stata rovesciata")
        // Con tolleranza e non con `==`: `1 - (1 - 0.42)` fa 0,41999999999999993, e
        // un'uguaglianza esatta su Double qui proverebbe l'aritmetica in virgola
        // mobile invece del rovesciamento.
        let ritorno = entrata.rovesciata
        #expect(abs(ritorno.x1 - uscita.x1) < 1e-12 && abs(ritorno.y1 - uscita.y1) < 1e-12
                && abs(ritorno.x2 - uscita.x2) < 1e-12 && abs(ritorno.y2 - uscita.y2) < 1e-12,
                "rovesciare due volte non torna al punto di partenza: \(ritorno) contro \(uscita)")
        for i in 0...100 {
            let p = Double(i) / 100
            #expect(abs(entrata.frazione(a: p) - (1 - uscita.frazione(a: 1 - p))) < 1e-9,
                    "a \(p) il rovescio non è il rovescio")
        }
        // The exit's curve is still `.easeIn` spelled out — the half he said was
        // right, and the one nobody asked to touch.
        #expect(uscita == IslandEntrance.Curva(x1: 0.42, y1: 0, x2: 1, y2: 1))
        // And the curve is a curve: monotone, from 0 to 1.
        #expect(uscita.frazione(a: 0) == 0 && uscita.frazione(a: 1) == 1)
        #expect(uscita.frazione(a: 0.5) < 0.5, "`ease-in` parte piano: a metà tempo è oltre metà strada")
        #expect(entrata.frazione(a: 0.5) > 0.5, "il suo rovescio deve partire svelto")
    }

    /// **The closed state is a lip of the hardware, and it is now BOTH ends.**
    ///
    /// Since 2026-08-17 this shape is where the arrival starts *and* where the
    /// departure lands, so it is the frame the whole gesture is anchored on: the
    /// island is never smaller than the notch it belongs to, and never a point.
    ///
    /// The negative pole is the one that keeps it honest: narrower than the
    /// hardware, but still ABOUT the hardware's width, or the island would be
    /// forming out of nothing instead of out of the notch.
    @Test func theClosedStateIsALipOfTheHardware() {
        let start = IslandEntrance.state(for: .notch, shown: false)
        // The hardware notch is roughly 192 of the island's 400 points.
        let hardware = 192.0 / Double(IslandPanel.width)
        #expect(Double(start.scaleX) < hardware,
                "the lip is not narrower than the hardware it sits under")
        #expect(Double(start.scaleX) > hardware * 0.75,
                "narrowed, not born out of nothing: \(start.scaleX)")
        #expect(start.scaleY < start.scaleX,
                "at the closed frame it is a lip: shallower than it is wide")
        // And the trajectory really does start there, rather than there being a
        // second closed state hidden inside the interpolation. Con tolleranza: a
        // fine corsa l'interpolazione fa `1 + (0.42 - 1)`, che in virgola mobile è
        // 0,41999999999999993 — un'uguaglianza esatta qui misurerebbe l'aritmetica.
        func combacia(_ a: IslandEntrance, _ b: IslandEntrance) -> Bool {
            abs(a.scaleX - b.scaleX) < 1e-12 && abs(a.scaleY - b.scaleY) < 1e-12
                && abs(a.opacity - b.opacity) < 1e-12 && a.anchor == b.anchor
        }
        let primoFotogramma = IslandEntrance.traiettoria(for: .notch, progresso: 0, entrando: true)
        #expect(combacia(primoFotogramma, start), "l'entrata non parte dallo stato chiuso: \(primoFotogramma)")
        let ultimoFotogramma = IslandEntrance.traiettoria(for: .notch, progresso: 1, entrando: false)
        #expect(combacia(ultimoFotogramma, start), "l'uscita non finisce nello stato chiuso: \(ultimoFotogramma)")
    }

    /// Vendored maths, one property: silence must draw a nearly flat line and
    /// speech a tall one. If this ever inverts, the island animates beautifully
    /// and says nothing about whether the microphone is hearing anything.
    @Test func silenceIsFlatAndSpeechIsTall() {
        let nastro = NastroOnda.nastri[0]
        var quiet = 0.0, loud = 0.0
        for step in 0..<60 {
            let t = Double(step) * 0.1
            for x in stride(from: -1.0, through: 1.0, by: 0.05) {
                quiet = max(quiet, abs(WaveModel.ordinate(x: x, t: t, livello: 0, nastro: nastro).dorso))
                loud = max(loud, abs(WaveModel.ordinate(x: x, t: t, livello: 1, nastro: nastro).dorso))
            }
        }
        #expect(quiet < 0.10, "silence should barely breathe, got \(quiet)")
        #expect(loud > 0.80, "a voice should fill the island, got \(loud)")
        #expect(loud > quiet * 5)
    }
}
