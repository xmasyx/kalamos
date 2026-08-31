import Testing
@testable import Kalamos

/// I due poli del tocco singolo, riscritti il 31/08 sulla sua regola: **si detta se
/// ⌥ è stato rilasciato da solo, non si detta se durante la pressione è stata premuta
/// anche una lettera**. L'avvio resta istantaneo: nessuna attesa, nessuna finestra.
///
/// Nascono da una misura. `SingleTapModeTests` copriva un solo ordine di arrivo degli
/// eventi, quello ideale, ed era verde. Enumerando gli altri il 31/08, la lettera
/// **persa dal tap** faceva partire la dettatura, ed era il sintomo in campo. Il tap
/// non è una fonte affidabile: macOS lo disabilita quando il gestore è lento, e un
/// campo a input sicuro gli nasconde i tasti. La domanda «c'era una lettera?» va
/// quindi fatta anche al sistema, ed è ciò che `HotkeyManager.aKeyWasPressed` passa
/// qui come `otherKeyDuringPress`.
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
    @Test func ilTastoRilasciatoDaSoloDettaSubito() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.08)
        #expect(azioni() == [.beginRecording], "deve partire sul rilascio, senza attese")
    }

    /// Ordine A — il tap VEDE la lettera mentre il tasto è giù.
    @Test func ordineA_letteraVistaDalTap() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.abort(); g.keyUp(at: 0.10)
        #expect(azioni().isEmpty)
    }

    /// Ordine C — la lettera non arriva affatto al tap: tap disabilitato per lentezza,
    /// oppure input sicuro. È il caso che spiega l'«ogni tanto», ed è quello che il
    /// vecchio codice non poteva vedere in nessun modo.
    @Test func ordineC_letteraPersaDalTapMaVistaDalSistema() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.10, otherKeyDuringPress: true)
        #expect(azioni().isEmpty)
    }

    /// Ordine B — la lettera risulta premuta un soffio PRIMA del modificatore. La
    /// tolleranza di 40 ms in `HotkeyManager` la fa ricadere dentro la pressione.
    @Test func ordineB_letteraUnSoffioPrimaDelModificatore() {
        let (g, azioni) = provino()
        g.abort(); g.keyDown(at: 0.0)
        g.keyUp(at: 0.10, otherKeyDuringPress: true)
        #expect(azioni().isEmpty)
    }

    /// Un clic mentre il tasto è giù: ⌥-clic è una scorciatoia vera, non una dettatura.
    @Test func unClicMentreIlTastoEGiuAnnulla() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.abort(); g.keyUp(at: 0.10)
        #expect(azioni().isEmpty)
    }

    /// Una lettera scritta PRIMA di toccare ⌥ non deve impedire la dettatura: il conto
    /// di `HotkeyManager` la vede più vecchia della pressione, quindi qui arriva falso.
    @Test func unaLetteraPrecedenteNonBloccaLaDettatura() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.08, otherKeyDuringPress: false)
        #expect(azioni() == [.beginRecording])
    }

    /// Il tocco che CHIUDE resta immediato.
    @Test func ilToccoCheChiudeEImmediato() {
        let (g, azioni) = provino()
        g.keyDown(at: 0.0); g.keyUp(at: 0.08)
        g.keyDown(at: 2.0)
        #expect(azioni() == [.beginRecording, .endRecordingAndProcess])
    }
}
