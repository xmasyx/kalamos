import SwiftUI

/// La riga del modello di punteggiatura dedicato: dice se è sul disco e, se
/// non c'è, lo scarica. Una volta scaricato, «Solo quando serve» smette di
/// pagare i secondi del modello grande per la sola punteggiatura.
struct PunctuationModelRow: View {
    @State private var scaricato = PunctuationModel.isDownloaded
    @State private var inCorso = false
    @State private var avanzamento: Avanzamento?
    @State private var errore: String?
    @State private var reteInterrotta = false

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
                    ProgressView(value: min(max(avanzamento?.frazione ?? 0, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Theme.pen)
                    HStack(spacing: 8) {
                        Text(L.t("Scaricamento in corso…", "Downloading…", "Téléchargement…"))
                        if let a = avanzamento {
                            Text(L.t("\(L.byte(a.scaricati)) di \(L.byte(a.totale))",
                                     "\(L.byte(a.scaricati)) of \(L.byte(a.totale))",
                                     "\(L.byte(a.scaricati)) sur \(L.byte(a.totale))"))
                                .monospacedDigit()
                        }
                    }
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                } else {
                    PrefButton(title: titoloBottone,
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
        // Una ripresa non azzera la misura: i byte sono ancora sul disco, e
        // mostrare zero mentre la sessione prepara il nuovo `Range` direbbe a
        // chi guarda esattamente la bugia che questo lavoro esiste per togliere.
        if !reteInterrotta {
            avanzamento = nil
        }
        inCorso = true
        errore = nil
        Task { @MainActor in
            do {
                try await PunctuationModel.download { nuovo in
                    Task { @MainActor in
                        // Task distinti possono arrivare al MainActor in ordine
                        // diverso dai callback: un valore vecchio non deve far
                        // arretrare la barra dopo che quello nuovo è già visibile.
                        if nuovo.frazione >= (avanzamento?.frazione ?? 0) {
                            avanzamento = nuovo
                        }
                    }
                }
                scaricato = PunctuationModel.isDownloaded
                inCorso = false
                reteInterrotta = false
            } catch {
                errore = messaggio(error)
                if let failure = error as? DownloadFailure, case .rete = failure {
                    reteInterrotta = true
                } else {
                    reteInterrotta = false
                }
                inCorso = false
            }
        }
    }

    private var titoloBottone: String {
        if reteInterrotta {
            return L.t("Riprendi", "Resume", "Reprendre")
        } else {
            return L.t("Scarica (1,1 GB)", "Download (1.1 GB)", "Télécharger (1,1 Go)")
        }
    }

    private func messaggio(_ error: any Error) -> String {
        guard let failure = error as? DownloadFailure else {
            return error.localizedDescription
        }
        switch failure {
        case .rete:
            return L.t("Connessione interrotta. Riprova: riprende da dove si era fermato.",
                       "Connection lost. Try again: it resumes where it stopped.",
                       "Connexion interrompue. Réessayez : la reprise part d'où elle s'est arrêtée.")
        case .http(_, let stato):
            return L.t("Il server ha risposto \(stato).",
                       "The server replied \(stato).",
                       "Le serveur a répondu \(stato).")
        case .tagliaErrata:
            return L.t("File scaricato incompleto o corrotto: riprova.",
                       "Downloaded file incomplete or corrupt: try again.",
                       "Fichier téléchargé incomplet ou corrompu : réessayez.")
        case .contenuto:
            return L.t("Il file scaricato non è quello atteso.",
                       "The downloaded file is not the expected one.",
                       "Le fichier téléchargé n'est pas celui attendu.")
        case .disco:
            return L.t("Non riesco a scrivere sul disco: controlla lo spazio libero.",
                       "Cannot write to disk: check free space.",
                       "Impossible d'écrire sur le disque : vérifiez l'espace libre.")
        }
    }
}
