import AppKit

// Sonda ISC-10, ISOLATA da Kalamos: un pannello con gli STESSI flag dell'isola
// (borderless, nonactivating, .statusBar, movableByWindowBackground) trascinato
// da un gesto VERO fino a un bersaglio. Se l'affiancamento di macOS interviene,
// interviene qui, e allora il difetto non è nostro.
//
// Due poli, che è il punto: `--bersaglio=alto` DEVE mostrare il difetto,
// `--bersaglio=centro` NON deve mostrarlo.

let args = CommandLine.arguments
let bersaglioAlto = !args.contains("--bersaglio=centro")
/// `--manuale`: il trascinamento lo gestiamo NOI dentro la vista, e il
/// WindowServer non vede mai una "finestra trascinata". È la riparazione
/// candidata: se il velo sparisce solo qui, la causa era aver ceduto il gesto
/// al sistema con `isMovableByWindowBackground`.
let manuale = args.contains("--manuale")

/// La vista che si prende il gesto. `setFrameOrigin` durante il trascinamento,
/// nessun coinvolgimento dell'affiancamento di sistema.
final class VistaTrascinabile: NSView {
    private var ancoraMouse: NSPoint = .zero
    private var ancoraFinestra: NSPoint = .zero
    override func mouseDown(with e: NSEvent) {
        ancoraMouse = NSEvent.mouseLocation
        ancoraFinestra = window?.frame.origin ?? .zero
    }
    override func mouseDragged(with e: NSEvent) {
        let ora = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: ancoraFinestra.x + (ora.x - ancoraMouse.x),
                                       y: ancoraFinestra.y + (ora.y - ancoraMouse.y)))
    }
}

guard let schermo = NSScreen.main else { fatalError("nessuno schermo") }
let sf = schermo.frame

// La pillola vera: guscio 150×40, finestra +14% di slack.
let guscio = CGSize(width: 150, height: 40)
let finestra = CGSize(width: guscio.width + (guscio.width * 0.14).rounded(),
                      height: guscio.height + (guscio.height * 0.14).rounded())
// Il suo centro salvato, letto dai defaults: 754 114.
let centro = CGPoint(x: 754, y: 114)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = NSPanel(contentRect: NSRect(origin: .zero, size: finestra),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.level = .statusBar
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.isMovableByWindowBackground = !manuale
panel.isMovable = !manuale
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.hidesOnDeactivate = false

let vista: NSView = manuale ? VistaTrascinabile(frame: NSRect(origin: .zero, size: finestra))
                           : NSView(frame: NSRect(origin: .zero, size: finestra))
vista.wantsLayer = true
let capsula = CALayer()
capsula.frame = CGRect(x: (finestra.width - guscio.width) / 2,
                       y: (finestra.height - guscio.height) / 2,
                       width: guscio.width, height: guscio.height)
capsula.backgroundColor = NSColor(red: 0.118, green: 0.169, blue: 0.227, alpha: 1).cgColor
capsula.cornerRadius = guscio.height / 2
vista.layer?.addSublayer(capsula)
panel.contentView = vista
panel.setFrameOrigin(NSPoint(x: centro.x - finestra.width / 2, y: centro.y - finestra.height / 2))
panel.orderFrontRegardless()

/// Il rettangolo secondo il WindowServer, che è l'unico che sa se il
/// compositore ha fatto qualcosa che AppKit non racconta.
func compositore(_ numero: Int) -> CGRect? {
    guard let lista = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in lista where (w[kCGWindowNumber as String] as? Int) == numero {
        if let b = w[kCGWindowBounds as String] as? [String: CGFloat],
           let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"] {
            return CGRect(x: x, y: y, width: ww, height: hh)
        }
    }
    return nil
}

/// AppKit ha l'origine in basso a sinistra, CGEvent in alto a sinistra.
func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: sf.height - p.y) }

func posta(_ tipo: CGEventType, _ punto: CGPoint) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: tipo,
                          mouseCursorPosition: flip(punto), mouseButton: .left) else { return }
    e.post(tap: .cghidEventTap)
}

struct Campione { let t: Double; let mouse: CGPoint; let appkit: CGRect; let ws: CGRect? }

/// Tutte le finestre del compositore, come "proprietario | numero | rettangolo".
/// Serve a vedere se durante il gesto ne COMPARE una nuova, cioè il velo
/// dell'affiancamento, che è una finestra di sistema e non un effetto sulla nostra.
func inventario() -> [String: String] {
    var out: [String: String] = [:]
    guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else { return out }
    for w in lista {
        guard let n = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
        let nome = (w[kCGWindowName as String] as? String) ?? ""
        out["\(n)"] = String(format: "%@ %@ | %.0f,%.0f %.0fx%.0f", owner, nome,
                             b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
    }
    return out
}
var invPrima: [String: String] = [:]
var invDurante: [String: String] = [:]
var campioni: [Campione] = []
let numero = panel.windowNumber
let inizio = Date()

func campiona() {
    campioni.append(Campione(t: Date().timeIntervalSince(inizio),
                             mouse: NSEvent.mouseLocation,
                             appkit: panel.frame,
                             ws: compositore(numero)))
}

let bersaglio = bersaglioAlto ? CGPoint(x: sf.midX, y: sf.maxY - 6)
                              : CGPoint(x: sf.midX, y: 500)

DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 0.8)
    DispatchQueue.main.sync { campiona(); invPrima = inventario() }
    let partenza = CGPoint(x: centro.x, y: centro.y)
    posta(.mouseMoved, partenza)
    Thread.sleep(forTimeInterval: 0.15)
    posta(.leftMouseDown, partenza)
    Thread.sleep(forTimeInterval: 0.1)
    let passi = 45
    for i in 1...passi {
        let f = Double(i) / Double(passi)
        let p = CGPoint(x: partenza.x + (bersaglio.x - partenza.x) * f,
                        y: partenza.y + (bersaglio.y - partenza.y) * f)
        posta(.leftMouseDragged, p)
        Thread.sleep(forTimeInterval: 0.016)
        if i % 5 == 0 { DispatchQueue.main.sync { campiona() } }
    }
    Thread.sleep(forTimeInterval: 0.35)          // il velo, se c'è, si mostra qui
    DispatchQueue.main.sync { campiona(); invDurante = inventario() }
    posta(.leftMouseUp, bersaglio)
    for _ in 0..<8 {
        Thread.sleep(forTimeInterval: 0.12)
        DispatchQueue.main.sync { campiona() }
    }
    DispatchQueue.main.async {
        print("bersaglio: \(bersaglioAlto ? "ALTO (bordo superiore)" : "CENTRO (controllo)") · gesto: \(manuale ? "NOSTRO" : "di sistema")")
        print("schermo \(Int(sf.width))x\(Int(sf.height)) · finestra attesa \(Int(finestra.width))x\(Int(finestra.height))")
        print("     t         mouse           AppKit frame              WindowServer")
        for c in campioni {
            let ws = c.ws.map { String(format: "%5.0f,%5.0f %4.0fx%4.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "(sparita)"
            print(String(format: "%6.2f %6.0f,%5.0f %6.0f,%5.0f %4.0fx%4.0f %@",
                         c.t, c.mouse.x, c.mouse.y,
                         c.appkit.minX, c.appkit.minY, c.appkit.width, c.appkit.height, ws))
        }
        let mosso = campioni.last!.mouse != campioni.first!.mouse
        let cresciuta = campioni.contains { $0.appkit.width > finestra.width * 1.5 || ($0.ws?.width ?? 0) > finestra.width * 1.5 }
        let nuove = invDurante.filter { invPrima[$0.key] == nil }
        print("\nfinestre COMPARSE durante il gesto: \(nuove.count)")
        for (n, d) in nuove.sorted(by: { $0.key < $1.key }) { print("  +\(n)  \(d)") }
        let sparite = invPrima.filter { invDurante[$0.key] == nil }
        print("finestre sparite: \(sparite.count)")
        for (n, d) in sparite.sorted(by: { $0.key < $1.key }) { print("  -\(n)  \(d)") }
        print("\nil gesto è avvenuto davvero: \(mosso ? "SI" : "NO — CGEvent inerte, manca il permesso Accessibilità")")
        print("la finestra è cresciuta oltre la sua taglia: \(cresciuta ? "SI (difetto riprodotto)" : "no")")
        exit(0)
    }
}
app.run()
