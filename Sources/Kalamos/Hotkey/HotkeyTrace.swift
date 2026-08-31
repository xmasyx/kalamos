import Foundation
import CoreGraphics
// `IsSecureEventInputEnabled` vive in HIToolbox, non in CoreGraphics: senza questo
// import il campo `secure` non compila, ed è il campo che decide la seconda ipotesi.
import Carbon.HIToolbox

/// Il registro grezzo di ciò che il tap RICEVE, non di ciò che il riconoscitore decide.
///
/// Esiste per una contraddizione precisa: `GestureRecognizerTests` è verde su
/// `anotherKeyWhileHeldCancelsTheGesture` in modalità `singleTap`, cioè la macchina a
/// stati annulla il gesto quando una lettera arriva col tasto premuto, e in campo
/// digitare ⌥ò fa partire lo stesso la dettatura. Delle due l'una: o gli eventi
/// arrivano in un ordine diverso da quello che il test simula, oppure non arrivano
/// affatto. Nessuna delle due è visibile da fuori, e un componente che butta il
/// proprio ingresso non è diagnosticabile.
///
/// **Non registra QUALE tasto premi.** Dei tasti diversi dal trigger tiene solo il
/// fatto che ce n'è stato uno: al difetto serve sapere se l'annullamento poteva
/// scattare, non cosa stavi scrivendo. Un registro che conserva i codici sarebbe un
/// registratore di tastiera, e su questa macchina non ne vogliamo uno nemmeno dietro
/// un interruttore.
///
/// Si accende a mano e resta spento di default:
/// `defaults write com.kalamos.app hotkeyTrace -bool true`
/// Scrive JSONL in `~/Library/Application Support/Kalamos/hotkey-trace.jsonl`, con un
/// tetto: superato, il file riparte da capo invece di crescere per sempre.
enum HotkeyTrace {

    /// Spento salvo richiesta esplicita.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "hotkeyTrace") }

    static var url: URL { ModelStorage.base.appendingPathComponent("hotkey-trace.jsonl") }

    /// Oltre questo il file riparte. Un evento sta in ~140 byte, quindi 2 MB sono
    /// circa quindicimila eventi: molte più di quante ne servono per cogliere il caso.
    private static let maxBytes = 2 * 1024 * 1024

    private static let queue = DispatchQueue(label: "kalamos.hotkey-trace")

    /// Una riga per evento ricevuto dal tap.
    ///
    /// - `ev`: il tipo, con i due `tapDisabled*` tenuti distinti perché sono
    ///   l'ipotesi numero uno: quando il sistema disabilita il tap, gli eventi di
    ///   quella finestra non arrivano a nessuno e l'annullamento non può scattare.
    /// - `trigger`: se l'evento riguarda il tasto scelto come innesco.
    /// - `secure`: `IsSecureEventInputEnabled()`. Con l'input sicuro acceso (un campo
    ///   password a fuoco) i tap non ricevono i tasti, e questo è il secondo sospetto.
    static func note(event ev: String,
                     trigger: Bool,
                     alternateHeld: Bool,
                     autorepeat: Bool,
                     stateBefore: String,
                     stateAfter: String) {
        guard enabled else { return }
        let t: String = String(format: "%.4f", ProcessInfo.processInfo.systemUptime)
        let secure: Bool = IsSecureEventInputEnabled()
        var line: String = "{\"t\":\(t),\"ev\":\"\(ev)\",\"trigger\":\(trigger)"
        line += ",\"alt\":\(alternateHeld),\"rep\":\(autorepeat),\"secure\":\(secure)"
        line += ",\"da\":\"\(stateBefore)\",\"a\":\"\(stateAfter)\"}\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
               size > maxBytes {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
