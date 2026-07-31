import Foundation

/// Everything the user reads, in the language he said he reads.
///
/// Three languages, written out at each call site instead of pulled from a
/// `.strings` table. The reason is that this app has one translator — the person
/// who owns it, a native Italian speaker — and a table hides the three versions
/// of a sentence in three different files, where they drift apart quietly. Side
/// by side, a bad translation is visible while you write the good one.
///
/// The language itself is `AppState.uiLanguage`, read fresh on every call rather
/// than cached: a cached copy is one more thing that can be stale, and this
/// costs a dictionary lookup.
///
/// Two standing rules, both learned the expensive way:
///  * **Key names stay in English** — "Right Command" is what is printed on the
///    keyboard, and translating it invents a key the hardware does not have.
///  * Short sentences. The English original is not the shape of the Italian one.
@MainActor
enum L {
    static func t(_ it: String, _ en: String, _ fr: String) -> String {
        switch AppState.shared.uiLanguage {
        case .italian: return it
        case .french:  return fr
        case .english: return en
        }
    }

    /// The name of a model in running text ("the speech model is loading").
    static func modelName(_ kind: ModelKind) -> String {
        switch kind {
        case .speech:  return t("modello vocale", "speech model", "modèle vocal")
        case .cleanup: return t("modello di pulizia", "cleanup model", "modèle de nettoyage")
        }
    }

    /// The one line that says what the app is doing, shown at the top of the menu
    /// and next to the icon. Written here, where the language is known — it used
    /// to be assembled in English inside the engines.
    static func statusLine(_ status: DictationStatus) -> String {
        switch status {
        case .idle:
            return t("Kalamos — in attesa", "Kalamos — idle", "Kalamos — au repos")
        case .listening:
            return t("Kalamos — ti ascolto…", "Kalamos — listening…", "Kalamos — j’écoute…")
        case .transcribing:
            return t("Kalamos — sto scrivendo…", "Kalamos — working…", "Kalamos — j’écris…")
        case .downloading(let kind, let fraction):
            let pct = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            return t("Kalamos — scarico il \(modelName(kind))\(pct)",
                     "Kalamos — downloading the \(modelName(kind))\(pct)",
                     "Kalamos — téléchargement du \(modelName(kind))\(pct)")
        case .loading(let kind):
            return t("Kalamos — apro il \(modelName(kind))…",
                     "Kalamos — opening the \(modelName(kind))…",
                     "Kalamos — ouverture du \(modelName(kind))…")
        case .working(let work):
            switch work {
            case .cleaning:
                return t("Kalamos — sistemo il testo…", "Kalamos — tidying up…",
                         "Kalamos — je corrige…")
            case .translating:
                return t("Kalamos — traduco…", "Kalamos — translating…", "Kalamos — je traduis…")
            case .summarizing:
                return t("Kalamos — riassumo…", "Kalamos — summarising…", "Kalamos — je résume…")
            case .editing:
                return t("Kalamos — riscrivo la selezione…", "Kalamos — rewriting your selection…",
                         "Kalamos — je réécris la sélection…")
            }
        case .error(let message):
            return "Kalamos — \(message)"
        }
    }
}
