import AppKit
import SwiftUI

/// Il blocco disegnato in testa al menu della barra.
///
/// **Perché esiste.** Otium e NoSleep aprono la loro tendina con un pannello nella livrea di
/// famiglia — nome dell'app in tondo semigrassetto, e accanto una riga che dice come sta —, mentre
/// Kalamos apriva con due voci di menu disabilitate, cioè testo grigio di sistema. Erano tre app
/// dello stesso principale che si leggevano come tre autori diversi. La differenza non era di
/// colore: la palette (`Theme`) qui c'era già e coincide alla cifra con quella di NoSleep.
///
/// **Niente sfondo pieno, ed è una scelta.** Dentro un `NSMenu` il pannello sta sopra il materiale
/// del menu, che è traslucido e con gli angoli arrotondati: dipingerci sopra un rettangolo di carta
/// lascerebbe quattro spigoli fuori posto in cima. Otium fa lo stesso e per la stessa ragione. Il
/// colore lo portano il testo e il glifo, che sono token `Theme` a due facce e quindi si risolvono
/// da soli quando il Mac passa alla notte.
///
/// **I dati arrivano già calcolati.** Il pannello non osserva `AppState`: una vista dentro un
/// `NSMenuItem` non ha un ciclo di aggiornamento su cui contare, quindi il contenuto si ricostruisce
/// a ogni apertura del menu (`menuNeedsUpdate`), che è l'unico istante in cui qualcuno lo guarda.
struct MenuPanel: View {
    /// Quello che il pannello dice, in tre pezzi già in lingua.
    struct Content: Equatable {
        var status: DictationStatus
        /// La frase di stato senza il nome dell'app davanti — il nome sta già nel titolo.
        var phrase: String
        /// La riga sotto: il suggerimento del tasto finché serve, poi motore e lingua.
        var detail: String
    }

    let content: Content

    /// Vero quando sta succedendo qualcosa. In quel caso lo stato prende l'accento, che è l'unico
    /// modo di distinguere «sto lavorando» da «in attesa» senza leggere.
    private var isBusy: Bool { content.status != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Allineati al centro, non alla linea di base. Il glifo è un'immagine da 18 punti, e
            // legarlo alla base del titolo con una guida a mano gli faceva rivendicare quindici
            // punti di spazio sopra la riga: il pannello misurava 92 invece di 77, e la fotografia
            // mostrava una fascia vuota in cima. Misurato, non stimato.
            HStack(alignment: .center, spacing: 7) {
                if let glyph = StatusGlyph.image(for: content.status) {
                    Image(nsImage: glyph)
                        .renderingMode(.template)
                        .foregroundStyle(isBusy ? Theme.pen : Theme.ink)
                }
                Text("Kalamos")   // lingua: ok nome proprio
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                Text(content.phrase)
                    .font(Theme.font(12))
                    .foregroundStyle(isBusy ? Theme.pen : Theme.inkFaded)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Undici, non undici e mezzo: a mezzo punto dallo stato le due righe pesavano uguale e
            // la testa del pannello si leggeva come tre frasi in fila invece che come un titolo con
            // due chiose. Visto nella fotografia, non nel codice.
            Text(content.detail)
                .font(Theme.font(11))
                .foregroundStyle(Theme.inkFaded)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 280, alignment: .leading)
    }
}

extension MenuPanel {
    /// La larghezza del pannello, e quindi la larghezza minima del menu.
    static let width: CGFloat = 280

    /// La vista pronta da infilare in un `NSMenuItem`, **misurata nell'ordine giusto**.
    ///
    /// `fittingSize` risponde alla larghezza che la vista ha in quel momento: chiesta prima di
    /// averle dato i suoi 280 punti, l'altezza torna calcolata su una riga di dettaglio mandata a
    /// capo più volte — 92 punti invece di 61, cioè una fascia vuota di trenta punti in cima al
    /// menu. Si vedeva nella fotografia e in nessun test. Quindi: prima la larghezza, poi il
    /// layout, poi la misura.
    @MainActor
    static func host(_ content: Content) -> NSHostingView<MenuPanel> {
        let host = NSHostingView(rootView: MenuPanel(content: content))
        resize(host)
        return host
    }

    /// La stessa misura, per quando il contenuto cambia sotto una vista che esiste già.
    @MainActor
    static func resize(_ host: NSHostingView<MenuPanel>) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
    }
}

extension MenuPanel.Content {
    /// La riga di sotto, scelta fra le due cose che vale la pena dire lì.
    ///
    /// Il suggerimento del tasto si ritira da solo: cinque dettature bastano a sapere quale tasto si
    /// tiene premuto, e da lì in poi è una riga che si legge oltre per sempre. Al suo posto restano
    /// i due fatti che cambiano davvero e che altrimenti si vedono solo aprendo le Preferenze —
    /// quale motore ascolta e in che lingua.
    ///
    /// Pura apposta: prende stringhe già tradotte, così i due rami si provano senza far partire
    /// l'app.
    static func detail(dictationCount: Int, hint: String, engine: String, language: String) -> String {
        dictationCount < 5 ? hint : "\(engine) · \(language)"
    }

    /// Il gesto che avvia una dettatura, scritto nel modo in cui lo si fa davvero.
    ///
    /// Sta qui, e non nel delegato, perché lo leggono in due: il menu vero e la sonda che lo
    /// fotografa. Riscritto nella sonda misurerebbe la copia invece dell'originale — il modo in cui
    /// una fotografia finisce per mostrare qualcosa che nell'app non c'è.
    @MainActor
    static func triggerHint(key: String, mode: TriggerMode) -> String {
        switch mode {
        case .both:
            return L.t("Tieni premuto \(key) per parlare · doppio tocco = mani libere",
                       "Hold \(key) to talk · double-tap = hands-free",
                       "Maintenez \(key) · double-appui = mains libres")
        case .hold:
            return L.t("Tieni premuto \(key) per parlare",
                       "Hold \(key) to talk",
                       "Maintenez \(key) pour parler")
        case .doubleTap:
            return L.t("Doppio tocco su \(key) = mani libere",
                       "Double-tap \(key) = hands-free",
                       "Double-appui sur \(key) = mains libres")
        case .singleTap:
            return L.t("Tocca \(key) per cominciare, toccalo di nuovo per finire",
                       "Tap \(key) to start, tap again to finish",
                       "Appuyez sur \(key) pour commencer, à nouveau pour finir")
        }
    }
}

/// L'immagine che dice cosa sta succedendo, **una sola volta per tutta l'app**.
///
/// La barra dei menu e il pannello devono mostrare lo stesso glifo per lo stesso stato: scritti in
/// due posti sarebbero divergiti alla prima aggiunta, e un'icona che contraddice la frase accanto è
/// peggio di nessuna icona. A riposo e in ascolto l'app usa il suo marchio — la canna e il segno che
/// ha appena lasciato —, per tutto il resto il simbolo di sistema che dice cosa sta accadendo.
enum StatusGlyph {
    @MainActor
    static func image(for status: DictationStatus) -> NSImage? {
        let label = L.statusLine(status)
        switch status {
        case .idle:         return CalamoIcon.image(filled: false)
        case .listening:    return CalamoIcon.image(filled: true)
        case .transcribing: return NSImage(systemSymbolName: "waveform", accessibilityDescription: label)
        case .downloading:  return NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: label)
        case .loading:      return NSImage(systemSymbolName: "hourglass", accessibilityDescription: label)
        case .working:      return NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: label)
        case .error:        return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: label)
        }
    }
}
