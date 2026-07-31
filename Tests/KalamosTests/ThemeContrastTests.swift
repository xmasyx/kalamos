import XCTest
import AppKit
import SwiftUI
@testable import Kalamos

/// The livery, measured instead of admired.
///
/// Kalamos had no test on its colours at all, which was survivable while there was
/// one face chosen against mockups on a bright desk. A second face changes that: the
/// night values were picked in a browser mockup, and a mockup is not the app. WCAG AA
/// asks 4.5:1 for body text and 3:1 for large text and controls; below that line
/// somebody stops reading.
///
/// The values are not copied into the test. They are **resolved out of `Theme`**
/// against each appearance, the same way a view resolves them when it draws — so this
/// also proves the dynamic colours really are dynamic, which a hardcoded table could
/// never catch.
final class ThemeContrastTests: XCTestCase {

    private func resolve(_ color: Color, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    private func luminance(_ c: NSColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every pair the windows actually use, on both faces.
    func testBothFacesMeetWcag() {
        for dark in [false, true] {
            let paper = resolve(Theme.paper, dark: dark)
            let edge = resolve(Theme.paperEdge, dark: dark)
            let card = resolve(Theme.card, dark: dark)
            let ink = resolve(Theme.ink, dark: dark)
            let faded = resolve(Theme.inkFaded, dark: dark)
            let pen = resolve(Theme.pen, dark: dark)
            let face = dark ? "Inchiostro" : "Carta"

            let pairs: [(String, NSColor, NSColor, Double)] = [
                ("body text on paper", ink, paper, 4.5),
                ("body text on a card", ink, card, 4.5),
                ("body text on the edge", ink, edge, 4.5),
                ("secondary text on paper", faded, paper, 4.5),
                ("secondary text on a card", faded, card, 4.5),
                ("pen on paper", pen, paper, 4.5),
                // The filled button: paper-coloured label on a pen-coloured ground.
                // It works on both faces only because `paper` flips too — at night the
                // label is the ink, not the ivory.
                ("label over the filled button", paper, pen, 4.5),
            ]
            for (name, fg, bg, floor) in pairs {
                let r = ratio(fg, bg)
                XCTAssertGreaterThanOrEqual(
                    r, floor,
                    String(format: "%@ · %@: %.2f:1, below %.1f", face, name, r, floor))
            }
        }
    }

    /// **The two faces are actually two.**
    ///
    /// The whole mechanism is one dynamic colour per token, and the failure mode that
    /// looks like success is a colour that resolves to the same value in both
    /// appearances — every test above would still pass while the app never changed at
    /// night. This is the control that says the switch is wired.
    func testEveryTokenChangesBetweenTheFaces() {
        let tokens: [(String, Color)] = [
            ("paper", Theme.paper), ("paperEdge", Theme.paperEdge), ("ink", Theme.ink),
            ("pen", Theme.pen), ("inkFaded", Theme.inkFaded), ("rule", Theme.rule),
            ("card", Theme.card),
        ]
        for (name, color) in tokens {
            let day = resolve(color, dark: false), night = resolve(color, dark: true)
            XCTAssertGreaterThan(
                ratio(day, night), 1.05,
                "\(name) resolves to the same colour day and night — the token is not dual")
        }
    }

    /// A separator has to be seen without becoming a table border.
    func testRulesAreVisibleWithoutShouting() {
        for dark in [false, true] {
            let r = ratio(resolve(Theme.rule, dark: dark), resolve(Theme.paper, dark: dark))
            XCTAssertGreaterThanOrEqual(r, 1.15, "the rule disappears into its ground")
            XCTAssertLessThan(r, 4.5, "the rule is louder than the secondary text")
        }
    }
}
