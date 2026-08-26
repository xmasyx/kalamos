import AppKit
import SwiftUI

// Sonda ISOLATA: la stessa barra di scorrimento di `ScrubBar` (ZStack +
// DragGesture(minimumDistance: 0) dentro un GeometryReader) dentro una finestra
// con gli STESSI flag di `TruthWindow`. Domanda: durante un trascinamento VERO,
// quanti `onChanged` arrivano?
//
// Due poli: `--movable` (come l'app oggi) DEVE mostrare il difetto,
// `--fisso` (isMovableByWindowBackground = false) NON deve mostrarlo.

let args = CommandLine.arguments
let movable = !args.contains("--fisso")
/// `--rimedio`: finestra trascinabile come oggi, ma sotto la barra una `NSView`
/// che dichiara `mouseDownCanMoveWindow = false`. È la riparazione candidata.
let rimedio = args.contains("--rimedio")

/// Dice ad AppKit che il clic su questo pezzo di finestra NON la sposta.
struct NonSpostaLaFinestra: NSViewRepresentable {
    final class Vista: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { Vista() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class Conta: ObservableObject {
    @Published var fraction: Double = 0.5
    var eventi: [Double] = []
}
let conta = Conta()

struct Barra: View {
    @ObservedObject var conta: Conta
    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3)).frame(height: 4)
                Capsule().fill(Color.blue).frame(width: w * conta.fraction, height: 4)
                Circle().fill(Color.blue).frame(width: 11, height: 11)
                    .offset(x: w * conta.fraction - 5.5)
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .background(rimedio ? AnyView(NonSpostaLaFinestra()) : AnyView(Color.clear))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = min(max(g.location.x / w, 0), 1)
                    conta.fraction = f
                    conta.eventi.append(f)
                })
        }
        .frame(height: 18)
    }
}

guard let schermo = NSScreen.main else { fatalError("nessuno schermo") }
let sf = schermo.frame

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let hosting = NSHostingController(rootView:
    Barra(conta: conta).padding(.horizontal, 40).frame(width: 600, height: 60))
hosting.sizingOptions = []
let w = NSWindow(contentViewController: hosting)
w.styleMask = [.titled, .closable, .resizable]
w.titlebarAppearsTransparent = true
w.isMovableByWindowBackground = movable
w.setContentSize(NSSize(width: 600, height: 60))
w.center()
w.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)

func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: sf.height - p.y) }
func posta(_ tipo: CGEventType, _ punto: CGPoint) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: tipo,
                          mouseCursorPosition: flip(punto), mouseButton: .left) else { return }
    e.post(tap: .cghidEventTap)
}

let framePrima = w.frame

DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 1.0)
    // La barra: 520 punti utili (600 meno 40+40 di padding), a metà altezza del contenuto.
    let contenuto = DispatchQueue.main.sync { w.contentView!.window!.frame }
    let y = contenuto.minY + 30
    let xInizio = contenuto.minX + 40 + 520 * 0.25
    let xFine   = contenuto.minX + 40 + 520 * 0.85
    posta(.mouseMoved, CGPoint(x: xInizio, y: y))
    Thread.sleep(forTimeInterval: 0.2)
    posta(.leftMouseDown, CGPoint(x: xInizio, y: y))
    Thread.sleep(forTimeInterval: 0.1)
    let passi = 30
    for i in 1...passi {
        let f = Double(i) / Double(passi)
        posta(.leftMouseDragged, CGPoint(x: xInizio + (xFine - xInizio) * f, y: y))
        Thread.sleep(forTimeInterval: 0.02)
    }
    Thread.sleep(forTimeInterval: 0.2)
    posta(.leftMouseUp, CGPoint(x: xFine, y: y))
    Thread.sleep(forTimeInterval: 0.3)
    DispatchQueue.main.async {
        let ev = conta.eventi
        let mosso = w.frame.origin != framePrima.origin
        print("polo: \(rimedio ? "RIMEDIO (movable + mouseDownCanMoveWindow=false)" : movable ? "MOVABLE (come l'app)" : "FISSO")")
        print("eventi onChanged ricevuti: \(ev.count)")
        print("frazione: prima \(String(format: "%.3f", ev.first ?? -1)) → ultima \(String(format: "%.3f", ev.last ?? -1))")
        print("la finestra si è spostata: \(mosso ? "SI (il gesto è finito al window server)" : "no")")
        let cursore = NSEvent.mouseLocation
        print("il gesto è avvenuto davvero: \(abs(cursore.x - xFine) < 3 ? "SI" : "NO — CGEvent inerte, manca il permesso Accessibilità")")
        // Il metro NON è il numero di eventi: con la finestra che si sposta sotto
        // il puntatore gli eventi arrivano lo stesso e la frazione resta ferma.
        // La domanda vera è di quanto si è mossa la frazione (attesa: 0,25 → 0,85).
        let corsa = (ev.last ?? 0) - (ev.first ?? 0)
        print("corsa della frazione: \(String(format: "%.3f", corsa)) (attesa ~0,600)")
        print("VERDETTO: il trascinamento \(corsa >= 0.4 ? "FUNZIONA" : "NON funziona")")
        exit(0)
    }
}
app.run()
