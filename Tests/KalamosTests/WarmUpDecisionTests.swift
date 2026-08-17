import Testing
@testable import Kalamos

/// **Chi merita 4 GB di memoria residente, e chi non li merita più.**
///
/// Il difetto che questi test esistono per impedire è già successo: quando la
/// punteggiatura è passata al modello dedicato, `adaptive` ha smesso di chiamare
/// l'LLM, ma la condizione del riscaldamento continuava a nominarlo. Risultato
/// misurato su un'installazione vera, con Rifinitura AI spenta: 5747 MB di
/// impronta, 4,0 GB dei quali erano il modello MLX, tenuto caldo per un percorso
/// che nessuna dettatura percorreva più.
///
/// Nessun test poteva accorgersene, perché la decisione viveva dentro un metodo
/// il cui unico effetto osservabile era un precaricamento. Adesso è una funzione
/// pura, e questi test la **importano** invece di ricopiarla: il giorno che
/// l'instradamento cambia di nuovo, i due non possono divergere in silenzio.
@Suite("Riscaldamento — chi merita di restare in memoria")
struct WarmUpDecisionTests {

    private func vuole(
        _ mode: FormatterMode,
        punteggiaturaSulDisco: Bool = true,
        traduzione: Bool = false,
        rifinitura: Bool = false
    ) -> Bool {
        DictationController.wantsCleanupModelResident(
            mode: mode,
            punctuationModelOnDisk: punteggiaturaSulDisco,
            translating: traduzione,
            editMode: rifinitura
        )
    }

    // MARK: - Il polo che il difetto avrebbe fatto fallire

    /// Il caso della sua installazione: modo automatico, modello di punteggiatura
    /// scaricato, Rifinitura AI spenta. L'LLM non serve a nessuno.
    @Test func adaptiveColModelloDedicatoNonTieneLLesseLleEmme() {
        #expect(vuole(.adaptive, punteggiaturaSulDisco: true) == false)
    }

    /// **Il polo opposto, e senza di lui il primo non dice niente.** Tolto il
    /// modello di punteggiatura dal disco, `adaptive` ripiega davvero sull'LLM
    /// (`makeFormatter`, ramo «al modello (L1 non scaricato)»), quindi lì tenerlo
    /// caldo torna a essere giusto.
    @Test func adaptiveSenzaModelloDedicatoLoTieneAncora() {
        #expect(vuole(.adaptive, punteggiaturaSulDisco: false) == true)
    }

    // MARK: - Gli altri modi non sono stati toccati

    @Test func laRifinituraAIloVuoleSempre() {
        #expect(vuole(.localLLM, punteggiaturaSulDisco: true) == true)
        #expect(vuole(.localLLM, punteggiaturaSulDisco: false) == true)
    }

    @Test func iModiSenzaModelloNonLoVoglionoMai() {
        #expect(vuole(.off) == false)
        #expect(vuole(.ruleBased) == false)
    }

    /// Traduzione e Rifinitura girano sullo stesso motore, quindi valgono da sole
    /// anche quando il modo non lo chiederebbe: è la ragione per cui erano state
    /// aggiunte alla condizione, e il modello dedicato non le tocca.
    @Test func traduzioneERifinituraValgonoDaSole() {
        #expect(vuole(.ruleBased, traduzione: true) == true)
        #expect(vuole(.ruleBased, rifinitura: true) == true)
        #expect(vuole(.adaptive, punteggiaturaSulDisco: true, rifinitura: true) == true)
    }
}
