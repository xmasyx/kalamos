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
enum Theme {
    /// The sheet.
    static let paper = Color(hex: 0xFAF7F0)
    /// The title bar and any raised edge — the same sheet, one shade deeper.
    static let paperEdge = Color(hex: 0xF4F0E7)
    /// Dry ink: body text, headings.
    static let ink = Color(hex: 0x1E2B3A)
    /// The same pen, still wet: step labels, the active choice, the button.
    static let pen = Color(hex: 0x2F5C8A)
    /// Ink thinned with paper — secondary text, hints.
    static let inkFaded = Color(hex: 0x1E2B3A).opacity(0.62)
    /// The line of a resting element.
    static let rule = Color(hex: 0x1E2B3A).opacity(0.20)
    /// The wash behind the chosen option.
    static let penWash = Color(hex: 0x2F5C8A).opacity(0.13)

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
