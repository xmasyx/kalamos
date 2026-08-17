import Testing
@testable import Kalamos

/// **Il cursore del volume e le quattro velocità.**
///
/// Le pastiglie `+25/50/75/100` sono diventate un cursore con le tacchette
/// cliccabili. Qui si prova la parte che ha una risposta giusta: dove cade il
/// clic, e come si scrive un'etichetta. Il resto è armonia, e si giudica sulla
/// fotografia del pannello intero.
@Suite("Volume e velocità — dove cade il clic, e come si scrive un numero")
struct GainBarTests {

    private let tacche = Guadagno.quote   // 0, 25, 50, 75, 100

    // MARK: - Il clic sulla tacchetta ci va esatto

    @Test func unClicSullaTacchettaCiVaEsatto() {
        // 200 punti di barra: 6 punti di tolleranza sono il 3%.
        #expect(Guadagno.taccaVicina(a: 50, larghezza: 200, tacche: tacche) == 50)
        #expect(Guadagno.taccaVicina(a: 51.5, larghezza: 200, tacche: tacche) == 50)
        #expect(Guadagno.taccaVicina(a: 0.4, larghezza: 200, tacche: tacche) == 0)
        #expect(Guadagno.taccaVicina(a: 98, larghezza: 200, tacche: tacche) == 100)
    }

    /// **Il polo negativo, e senza di lui il test sopra non dice niente:** un clic
    /// lontano da ogni tacchetta deve restare dov'è. Se agganciasse comunque, le
    /// tacchette sarebbero magneti — la cosa che lui ha scartato per nome.
    @Test func unClicLontanoDaTutteRestaDovE() {
        // Su 200 punti la tolleranza è il 3%, quindi «lontano» comincia oltre i
        // tre punti percentuali. 47 sta ESATTAMENTE sul bordo e aggancia: è
        // giusto così, e sceglierlo come esempio di «lontano» sarebbe stato un
        // test che chiede al codice di essere incoerente con sé stesso.
        #expect(Guadagno.taccaVicina(a: 47, larghezza: 200, tacche: tacche) == 50)
        #expect(Guadagno.taccaVicina(a: 44, larghezza: 200, tacche: tacche) == nil)
        #expect(Guadagno.taccaVicina(a: 12, larghezza: 200, tacche: tacche) == nil)
        #expect(Guadagno.taccaVicina(a: 60, larghezza: 200, tacche: tacche) == nil)
    }

    /// La mira è una questione di punti sullo schermo, non di percentuale: una
    /// barra larga il doppio non deve essere il doppio più difficile da centrare,
    /// quindi la stessa distanza in percentuale aggancia su una barra stretta e
    /// non su una larga.
    @Test func laToleranzaEInPuntiNonInPercentuale() {
        // 5% di scarto: su 100 punti sono 5 punti (dentro i 6), su 400 sono 20.
        #expect(Guadagno.taccaVicina(a: 55, larghezza: 100, tacche: tacche) == 50)
        #expect(Guadagno.taccaVicina(a: 55, larghezza: 400, tacche: tacche) == nil)
    }

    /// Una barra di larghezza zero non esiste ancora: non deve agganciare né
    /// dividere per zero.
    @Test func unaBarraLargaZeroNonAggancia() {
        #expect(Guadagno.taccaVicina(a: 50, larghezza: 0, tacche: tacche) == nil)
    }

    // MARK: - Le quattro velocità

    @Test func leQuattroVelocitaCiSonoTutte() {
        #expect(Playback.speeds == [0.5, 1.0, 1.25, 1.5])
    }

    /// **Il caso che ha imposto la riparazione:** con `%.1f` fisso, `1.25`
    /// sarebbe uscito «1,2×», cioè un'altra velocità scritta sul bottone. Con
    /// `%.2f` fisso uscirebbe «0,50×», che è la stessa bruttezza dall'altra parte.
    @MainActor
    @Test func lEtichettaNonTagliaIlQuartoDiVelocita() {
        #expect(Playback.speedLabel(1.25).contains("1,25") || Playback.speedLabel(1.25).contains("1.25"))
        #expect(Playback.speedLabel(1.25).contains("1,2×") == false)
    }

    /// E l'altro polo: le velocità tonde restano a una cifra, non diventano
    /// «0,50×». Senza questo, la riparazione del quarto di velocità si potrebbe
    /// fare mettendo `%.2f` fisso, che ripara un capo e rompe l'altro.
    @MainActor
    @Test func leVelocitaTondeRestanoAUnaCifra() {
        for rate in [Float(0.5), 1.0, 1.5] {
            let s = Playback.speedLabel(rate)
            #expect(s.hasSuffix("×"), "\(rate) → \(s)")
            #expect(s.contains("50") == false, "\(rate) → \(s)")
            #expect(s.contains("00") == false, "\(rate) → \(s)")
        }
    }
}
