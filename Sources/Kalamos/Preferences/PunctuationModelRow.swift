import SwiftUI

/// La riga del modello di punteggiatura dedicato: dice se è sul disco e, se
/// non c'è, lo scarica. Una volta scaricato, «Solo quando serve» smette di
/// pagare i secondi del modello grande per la sola punteggiatura.
struct PunctuationModelRow: View {
    @State private var scaricato = PunctuationModel.isDownloaded
    @State private var inCorso = false
    @State private var frazione: Double = 0
    @State private var errore: String?

    var body: some View {
        PrefRow(title: L.t("Punteggiatura veloce", "Fast punctuation", "Ponctuation rapide"),
                note: L.t("Un modello dedicato mette punti, virgole e maiuscole in una frazione di secondo, dove il modello grande impiega qualche secondo. Si scarica una volta (1,1 GB) e lavora del tutto offline.",
                          "A dedicated model places periods, commas and capitals in a fraction of a second, where the large model takes a few seconds. Downloaded once (1.1 GB), fully offline.",
                          "Un modèle dédié place points, virgules et majuscules en une fraction de seconde, là où le grand modèle prend quelques secondes. Téléchargé une fois (1,1 Go), entièrement hors ligne.")) {
            VStack(alignment: .leading, spacing: 8) {
                if scaricato {
                    Text(L.t("Sul disco e pronto.", "On disk and ready.", "Sur le disque et prêt."))
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.inkFaded)
                } else if inCorso {
                    ProgressView(value: min(max(frazione, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Theme.pen)
                    Text(L.t("Scaricamento in corso…", "Downloading…", "Téléchargement…"))
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.inkFaded)
                } else {
                    PrefButton(title: L.t("Scarica (1,1 GB)", "Download (1.1 GB)", "Télécharger (1,1 Go)"),
                               filled: true) {
                        avvia()
                    }
                }
                if let errore {
                    Text(errore)
                        .font(Theme.font(11.5))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func avvia() {
        inCorso = true
        errore = nil
        Task {
            do {
                try await PunctuationModel.download { f in
                    Task { @MainActor in frazione = f }
                }
                await MainActor.run {
                    scaricato = PunctuationModel.isDownloaded
                    inCorso = false
                }
            } catch {
                await MainActor.run {
                    errore = error.localizedDescription
                    inCorso = false
                }
            }
        }
    }
}
