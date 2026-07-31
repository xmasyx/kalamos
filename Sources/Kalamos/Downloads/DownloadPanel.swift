import AppKit
import SwiftUI

/// A small panel that appears while a model is being downloaded, and goes away
/// by itself when the download ends.
///
/// It exists because the honest answer to "is it downloading?" used to live in a
/// 16-pixel icon and a line of text you had to open a menu to read — and the icon
/// was drawing a download arrow for three different things anyway, so it wasn't
/// an answer. The first cleanup model is 1.8–4.3 GB: something that big, started
/// on the app's own initiative, has to be visible without being asked about.
///
/// Deliberately not a dialog. It never takes focus (`.nonactivatingPanel`), never
/// blocks anything, and can be dismissed — the download carries on either way,
/// and the menu bar keeps the percentage.
@MainActor
final class DownloadPanel: NSObject, NSWindowDelegate {
    static let shared = DownloadPanel()

    private var panel: NSPanel?
    private var model = DownloadProgress()
    /// Set when the user closes the panel for a download already in flight, so it
    /// stays closed for that one and returns for the next.
    private var dismissed = false

    /// Called on every status change. Shows, updates, or hides — one entry point,
    /// so the panel cannot disagree with the state.
    func update(for status: DictationStatus) {
        guard case .downloading(let kind, let fraction) = status else {
            hide()
            dismissed = false
            return
        }
        model.kind = kind
        model.fraction = fraction
        guard !dismissed else { return }
        show()
    }

    private func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let hosting = NSHostingController(rootView: DownloadPanelView(progress: model))
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = Theme.paperNS
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        // Top right, under the menu bar: the corner the status icon lives in, so
        // the panel and the icon that carries the same percentage are together.
        if let screen = NSScreen.main {
            let size = p.frame.size
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 18,
                                     y: visible.maxY - size.height - 18))
        }
        panel = p
        // `orderFrontRegardless` and NOT `makeKeyAndOrderFront`: a panel that
        // takes the keyboard away mid-sentence would be a worse bug than the one
        // this fixes.
        p.orderFrontRegardless()
    }

    private func hide() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        dismissed = true
    }
}

/// The live numbers behind the panel. A class, so the panel is built once and
/// then simply told the new percentage.
@MainActor
final class DownloadProgress: ObservableObject {
    @Published var kind: ModelKind = .cleanup
    @Published var fraction: Double?
}

private struct DownloadPanelView: View {
    @ObservedObject var progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            // Determinate when the transfer says how far along it is, and a moving
            // bar in the seconds before the first byte lands — a bar frozen at zero
            // is indistinguishable from a download that never started.
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(Theme.pen)

            HStack(spacing: 6) {
                Text(percentage)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.pen)
                    .monospacedDigit()
                Text(L.t("si scarica una volta sola, poi resta sul tuo Mac",
                         "it downloads once, then stays on your Mac",
                         "il se télécharge une fois, puis reste sur votre Mac"))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
        .background(Theme.paper)
    }

    private var title: String {
        switch progress.kind {
        case .cleanup:
            return L.t("Scarico il modello che sistema il testo",
                       "Downloading the model that tidies your text",
                       "Téléchargement du modèle qui corrige le texte")
        case .speech:
            return L.t("Scarico il modello che ti ascolta",
                       "Downloading the model that hears you",
                       "Téléchargement du modèle qui vous écoute")
        }
    }

    private var percentage: String {
        guard let fraction = progress.fraction else {
            return L.t("in avvio…", "starting…", "démarrage…")
        }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
