import AppKit

// Misura, sull'immagine RESA, se l'onda tocca il bordo del guscio.
// Il guscio è nero pieno; l'onda è tutto ciò che dentro il guscio non è nero.
// Domanda: fra l'inchiostro più alto/basso e il bordo del guscio quanti pixel
// restano? Zero significa tagliata.
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
    if it - t <= 1 { toccaSopra += 1 }
    if b - ib <= 1 { toccaSotto += 1 }
}
let scala = 2   // le foto sono a 2×
print("immagine \(W)×\(H) px · guscio alto \(bot - top + 1) px = \((bot - top + 1)/scala) pt")
print("colonne misurate: \(colonneConInchiostro)")
print("margine minimo sopra: \(inkTop) px = \(inkTop/scala) pt · colonne che toccano il bordo alto: \(toccaSopra)")
print("margine minimo sotto: \(inkBot) px = \(inkBot/scala) pt · colonne che toccano il bordo basso: \(toccaSotto)")
print(toccaSopra + toccaSotto == 0 ? "✓ l'onda non tocca il bordo del guscio"
                                   : "✗ l'onda arriva al bordo in \(toccaSopra + toccaSotto) colonne: è tagliata")
