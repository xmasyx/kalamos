import Testing
@testable import Kalamos

/// La riga sotto il titolo, nel pannello in testa al menu.
///
/// Due rami e un confine, provati in tutti e due i versi: un test che guarda solo il ramo giusto
/// non distingue una scelta da una costante.
@Suite("MenuPanel — la riga di dettaglio")
struct MenuPanelDetailTests {

    @Test("Nelle prime dettature insegna il tasto")
    func hintWhileLearning() {
        let detail = MenuPanel.Content.detail(dictationCount: 0,
                                              hint: "Tieni premuto ⌥ per parlare",
                                              engine: "Whisper", language: "Italiano")
        #expect(detail == "Tieni premuto ⌥ per parlare")
    }

    @Test("Dalla quinta in poi dice motore e lingua")
    func factsOnceLearned() {
        let detail = MenuPanel.Content.detail(dictationCount: 5,
                                              hint: "Tieni premuto ⌥ per parlare",
                                              engine: "Whisper", language: "Italiano")
        #expect(detail == "Whisper · Italiano")
    }

    /// Il confine è a cinque, e si prova da entrambi i lati: con il solo caso a zero, un `detail`
    /// che ignorasse il conteggio e tornasse sempre il suggerimento sarebbe passato.
    @Test("Il confine sta esattamente a cinque")
    func boundary() {
        let four = MenuPanel.Content.detail(dictationCount: 4, hint: "H", engine: "E", language: "L")
        let five = MenuPanel.Content.detail(dictationCount: 5, hint: "H", engine: "E", language: "L")
        #expect(four == "H")
        #expect(five != four)
    }
}
