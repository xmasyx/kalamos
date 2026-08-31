import Testing
@testable import Kalamos

/// I due poli della riparazione del 31/08: ⌥ò non deve mai dettare, ⌥ da solo deve
/// sempre dettare.
///
/// Nascono da una misura, non da un'intuizione. `SingleTapModeTests` copriva un solo
/// ordine di arrivo degli eventi, quello ideale — ⌥ giù, lettera, ⌥ su — ed era verde.
/// Enumerando gli altri tre il 31/08, **tre su quattro facevano partire una
/// dettatura**: la lettera prima del modificatore, la lettera persa dal tap, e la
/// lettera un soffio dopo la risalita. In campo il sintomo era esattamente quello,
/// «ogni tanto parte il trascrittore quando scrivo ⌥ò».
///
/// La causa non era la macchina a stati ma il momento della decisione: aprire il
/// microfono sulla risalita significa scegliere quando l'intenzione è ancora
/// ambigua. Ora la risalita apre una finestra di grazia, e solo alla sua scadenza il
/// microfono si apre davvero.
@Suite struct OptionPiuLetteraNonDetta {

    private func provino() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30, mode: .singleTap)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    /// Il polo POSITIVO, e senza di lui gli altri non valgono niente: una riparazione
    /// che spegne anche il gesto buono passerebbe ogni prova negativa.
    @Test func unToccoPulitoApreIlMicrofono() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.08)
        #expect(azioni().isEmpty, "il microfono non si apre prima della grazia")
        g.tick(at: 0.08 + g.singleTapGrace + 0.01)
        #expect(azioni() == [.beginRecording], "un tocco pulito deve dettare")
    }

    /// E il tocco che CHIUDE non aspetta niente: la grazia protegge solo l'apertura.
    @Test func ilToccoCheChiudeNonAspetta() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.keyUp(at: 0.08); g.tick(at: 0.30)
        g.keyDown(at: 2.0)
        #expect(azioni() == [.beginRecording, .endRecordingAndProcess])
    }

    /// Ordine A — ⌥ giù, lettera, ⌥ su. Il tap vede la lettera mentre il tasto è giù.
    @Test func ordineA_letteraMentreIlTastoEGiu() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.abort(); g.keyUp(at: 0.10); g.tick(at: 0.50)
        #expect(azioni().isEmpty)
    }

    /// Ordine B — la lettera risulta premuta un soffio PRIMA del modificatore.
    /// Il tap non ha niente da annullare: a salvarla è la guardia di sistema, che
    /// `HotkeyManager` calcola e passa qui.
    @Test func ordineB_letteraPrimaDelModificatore() {
        let (g, azioni) = provino()
        g.abort(); g.keyDown(at: 0.0)
        g.keyUp(at: 0.10, otherKeyDuringPress: true)
        g.tick(at: 0.50)
        #expect(azioni().isEmpty)
    }

    /// Ordine C — la lettera non arriva affatto al tap (tap disabilitato per
    /// lentezza, oppure input sicuro). Stessa guardia: la risposta la dà il sistema.
    @Test func ordineC_letteraPersaDalTap() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.10, otherKeyDuringPress: true)
        g.tick(at: 0.50)
        #expect(azioni().isEmpty)
    }

    /// Ordine D — la lettera arriva subito DOPO la risalita. È il caso che la vecchia
    /// versione non poteva vedere in nessun modo, perché aveva già aperto il microfono.
    @Test func ordineD_letteraSubitoDopoLaRisalita() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.keyUp(at: 0.10)
        g.abort()                       // la lettera, dentro la grazia
        g.tick(at: 0.50)
        #expect(azioni().isEmpty)
    }

    /// Anche un clic dentro la grazia annulla: ⌥-clic è una scorciatoia vera.
    @Test func unClicDentroLaGraziaAnnulla() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.keyUp(at: 0.10)
        g.abort()                       // il tasto del mouse passa dalla stessa porta
        g.tick(at: 0.50)
        #expect(azioni().isEmpty)
    }

    /// Il polo negativo del polo negativo: senza la grazia l'ordine D dettava.
    /// Si misura chiedendo al riconoscitore di aprire subito, cioè saltando il tick.
    @Test func senzaAspettareLaGraziaIlMicrofonoResterebbeChiuso() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.keyUp(at: 0.10)
        #expect(azioni().isEmpty, "l'apertura non avviene più sulla risalita")
    }
}
