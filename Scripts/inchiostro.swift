import AppKit

// Misura, sull'immagine RESA, se l'onda tocca il bordo del guscio.
// Il guscio è nero pieno; l'onda è tutto ciò che dentro il guscio non è nero.
// Domanda: fra l'inchiostro più alto/basso e il bordo del guscio quanti pixel
// restano? Zero significa tagliata.
// `--striscia=<pt>`: quanti punti in cima al guscio sono coperti dall'HARDWARE.
// **Senza questo la sonda misura la domanda debole.** Il 19/08 ha risposto «l'onda
// non tocca il bordo» — vero — mentre lui vedeva l'onda tagliata: il taglio non lo
// faceva il guscio, lo faceva il notch fisico, che copre i primi 32 punti. Una
// sonda che guarda il contenitore invece della parte VISIBILE del contenitore dà
// un verde onesto alla domanda sbagliata.
let striscia = CommandLine.arguments
    .first { $0.hasPrefix("--striscia=") }
    .flatMap { Double($0.split(separator: "=", maxSplits: 1).last ?? "") } ?? 0

guard CommandLine.arguments.count > 1,
      let img = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let tiff = img.tiffRepresentation,
      let bmp = NSBitmapImageRep(data: tiff) else { fatalError("immagine non leggibile") }
let W = bmp.pixelsWide, H = bmp.pixelsHigh
func px(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    guard let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0,0,0) }
    return (Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
}
// Lo sfondo della foto è il grigio-blu della carta scura; il guscio è nero (<12).
func nero(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r < 12 && p.g < 12 && p.b < 12 }
func sfondo(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 20 || p.g > 20 || p.b > 20 }

// Colonna centrale: dove comincia e finisce il guscio.
let xc = W/2
var top = -1, bot = -1
for y in 0..<H where nero(px(xc, y)) { if top < 0 { top = y }; bot = y }
// Dentro il guscio, in ogni colonna, il primo e l'ultimo pixel NON nero = inchiostro.
var inkTop = H, inkBot = -1, colonneConInchiostro = 0
var toccaSopra = 0, toccaSotto = 0
// I bordi del guscio sono arrotondati: si campionano solo le colonne centrali,
// dove il guscio è alto quanto la sua altezza piena.
for x in stride(from: W/2 - 300, through: W/2 + 300, by: 1) where x >= 0 && x < W {
    var t = -1, b = -1
    for y in 0..<H where nero(px(x, y)) { if t < 0 { t = y }; b = y }
    guard t >= 0, b - t > 40 else { continue }
    var it = -1, ib = -1
    for y in (t+1)..<b where !nero(px(x, y)) { if it < 0 { it = y }; ib = y }
    guard it >= 0 else { continue }
    colonneConInchiostro += 1
    inkTop = min(inkTop, it - t); inkBot = max(inkBot, b - ib)
    // Il bordo utile in cima non è il guscio: è il guscio più la striscia coperta.
    if Double(it - t) <= striscia * 2 + 1 { toccaSopra += 1 }
    if b - ib <= 1 { toccaSotto += 1 }
}
let scala = 2   // le foto sono a 2×
print("immagine \(W)×\(H) px · guscio alto \(bot - top + 1) px = \((bot - top + 1)/scala) pt")
print("colonne misurate: \(colonneConInchiostro)")
print("striscia hardware dichiarata: \(Int(striscia)) pt")
print("margine minimo sopra il guscio: \(inkTop) px = \(inkTop/scala) pt · sotto l'hardware ne restano \(inkTop/scala - Int(striscia)) pt · colonne coperte dal notch: \(toccaSopra)")
print("margine minimo sotto: \(inkBot) px = \(inkBot/scala) pt · colonne che toccano il bordo basso: \(toccaSotto)")
// **Zero colonne misurate NON è un verde.** Una sonda che non ha guardato niente
// e una che ha guardato e non ha trovato difetti si leggono identiche, ed è la
// forma peggiore di falso verde: qui è successo davvero, perché la schermata di
// pausa di Otium era finita sopra la foto.
guard colonneConInchiostro >= 50 else {
    print("✗ misurate solo \(colonneConInchiostro) colonne: la foto non contiene il guscio (un'altra finestra davanti?)")
    exit(3)
}
print(toccaSopra + toccaSotto == 0 ? "✓ l'onda sta dentro la parte VISIBILE del guscio"
                                   : "✗ l'onda finisce sotto l'hardware o contro il bordo in \(toccaSopra + toccaSotto) colonne: è tagliata")
