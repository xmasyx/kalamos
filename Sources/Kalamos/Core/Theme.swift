import AppKit
import SwiftUI

/// Kalamos's livery: one sheet of paper, one pen.
///
/// The whole palette comes from a single idea — the app is named after a reed pen,
/// so the surface is paper and everything written on it is ink. What separates the
/// text from the things you can click is therefore NOT a different colour family,
/// which would arrive from nowhere, but the same ink at two depths: `ink` is the
/// dry writing, `pen` is a stroke just laid down and still wet. On a real page that
/// is exactly the difference you see.
///
/// Chosen against mockups rather than from taste: a warmer, more yellow paper read
/// as dated, a near-white one stopped being paper, and a single ink for both text
/// and accent was beautiful standing still and flat to use — with nothing but the
/// filled button left to say where the interface responds.
/// The livery has **two faces**, day and night, and the system decides which one.
///
/// The paper was always right at a desk with a window; at eleven at night, next to
/// windows that have all gone dark, a sheet of paper is a lamp pointed at your face.
/// The night face is *Inchiostro*, from the same three-livery comparison that chose
/// the paper: ink-dark ground, ivory text, a pen blue that stays luminous in the
/// dark. It was recommended then for a reason that still holds — it is the family
/// of Otium's break screen, so the two apps read as siblings.
///
/// Not sepia. Sepia was the third mockup and a *light* one — aged paper, brown ink —
/// advised against because it reads as old rather than as chosen.
///
/// Every token below is one colour with two values, resolved when it is drawn. That
/// matters more than it sounds: reading the appearance once, at startup, would leave
/// the window on paper when macOS turns dark on its own at sunset.
enum Theme {
    /// The sheet.
    static let paper = dual(0xFAF7F0, 0x141A22)
    /// The title bar and any raised edge — the same sheet, one shade deeper.
    static let paperEdge = dual(0xF4F0E7, 0x10151C)
    /// Dry ink: body text, headings. At night it is the ivory, and the name stops
    /// being literal — what it means is "the colour the writing is", either way.
    static let ink = dual(0x1E2B3A, 0xEFE7D6)
    /// The same pen, still wet: step labels, the active choice, the button.
    static let pen = dual(0x2F5C8A, 0x8FB3D9)
    /// Ink thinned with paper — secondary text, hints.
    ///
    /// Written out rather than as an opacity, for two reasons. The same transparent
    /// grey over paper and over a card is two greys, and secondary text should not
    /// change colour depending on what is under it. And the old `ink.opacity(0.62)`
    /// landed on #6C757F, which is **4.37:1 on paper — under AA**: a miss that
    /// shipped, because nothing here measured contrast until 2026-07-31. This value
    /// is Otium's, to the digit: one family, one secondary.
    static let inkFaded = dual(0x5C6672, 0x9AA3AE)
    /// The line of a resting element.
    static let rule = dual(0xD9D3C7, 0x263140)
    /// The wash behind the chosen option. Heavier at night: 13% of a luminous blue
    /// on an ink ground is a rumour, not a highlight.
    static let penWash = dual(Color(hex: 0x2F5C8A).opacity(0.13),
                              Color(hex: 0x8FB3D9).opacity(0.22))
    /// A raised card inside the window — the rows of a list, an option tile. This is
    /// what `Color.white.opacity(…)` used to be: white is invisible on paper and a
    /// milk stain on ink, so the surface needed a name of its own.
    static let card = dual(0xFFFFFF, 0x1A222C)

    /// The window background for AppKit, which colours the frame itself.
    static var paperNS: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x14 / 255, green: 0x1A / 255, blue: 0x22 / 255, alpha: 1)
                : NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF0 / 255, alpha: 1)
        }
    }

    /// Il colore della sola barra del titolo, per le finestre con la barra
    /// trasparente (2026-08-20).
    ///
    /// È `paperEdge`, cioè lo stesso della colonna: la barra diventa una fascia
    /// di bordo invece di un pezzo di pagina, e con la cucitura sotto (vedi
    /// `TitlebarSeam`) le due zone si distinguono anche di notte, dove un velo
    /// nero da solo si perde nel fondo scuro.
    static var paperEdgeNS: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x10 / 255, green: 0x15 / 255, blue: 0x1C / 255, alpha: 1)
                : NSColor(srgbRed: 0xF4 / 255, green: 0xF0 / 255, blue: 0xE7 / 255, alpha: 1)
        }
    }

    /// One colour, two values, resolved at draw time.
    private static func dual(_ light: UInt32, _ dark: UInt32) -> Color {
        dual(Color(hex: light), Color(hex: dark))
    }

    private static func dual(_ light: Color, _ dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    /// Rounded, because the alternative reads as either a system panel or a
    /// nineteenth-century title page, and this is neither.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    /// `0xRRGGBB` — a palette is easier to read and to diff in hex than in decimals.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
