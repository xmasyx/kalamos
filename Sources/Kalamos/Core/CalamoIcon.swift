import AppKit

/// The reed pen in the menu bar, drawn rather than shipped.
///
/// Chosen by the user on 2026-07-31 out of three proposals judged at their real
/// size: a nib seen straight on, a bare cut reed, and this one — the reed with
/// the stroke it has just left. The stroke is what makes it about *dictation*
/// rather than about a pen.
///
/// **Drawn in code, not a PNG.** This app assembles its own bundle with a shell
/// script and has no asset catalog, so a bitmap would mean two files per size per
/// scale, copied by hand in `build-app.sh`, and blurry the day the menu bar
/// changes height. A path is crisp at every size and costs nothing.
///
/// **Template image.** `isTemplate = true` hands the shape to macOS, which paints
/// it dark on a light bar and light on a dark one, and dims it while the menu is
/// open. Any colour we baked in would be thrown away — or worse, kept, and be the
/// one icon on the bar that ignores the theme.
enum CalamoIcon {
    /// The menu bar gives about 18 points of height; the glyph sits inside it.
    static let size: CGFloat = 18

    /// At rest: the outline. Recording: the same shape filled in, which is the
    /// difference you can see from across the room without reading anything.
    static func image(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setShouldAntialias(true)
            c.setStrokeColor(NSColor.black.cgColor)
            c.setFillColor(NSColor.black.cgColor)
            c.scaleBy(x: size / 64, y: size / 64)   // the drawing is in a 64-unit box
            draw(in: c, filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kalamos"
        return image
    }

    /// The reed above, the stroke below. Line widths are in the 64-unit box: at
    /// 18 points a 5.6 stroke lands on about 1.6 pixels, which stays a line at 1×
    /// and sharpens at 2× instead of disappearing.
    private static func draw(in c: CGContext, filled: Bool) {
        let reed = CGMutablePath()
        reed.move(to: CGPoint(x: 12, y: 22))       // the writing point
        reed.addLine(to: CGPoint(x: 27, y: 31))    // the oblique cut
        reed.addLine(to: CGPoint(x: 60, y: 55))
        reed.addLine(to: CGPoint(x: 50, y: 63))
        reed.closeSubpath()

        if filled {
            c.addPath(reed)
            c.fillPath()
        } else {
            c.addPath(reed)
            c.setLineWidth(5.6)
            c.setLineJoin(.round)
            c.strokePath()
        }

        // One confident curve under the pen — the line it just wrote.
        let ink = CGMutablePath()
        ink.move(to: CGPoint(x: 4, y: 10))
        ink.addCurve(to: CGPoint(x: 60, y: 10),
                     control1: CGPoint(x: 22, y: -2),
                     control2: CGPoint(x: 42, y: 22))
        c.addPath(ink)
        c.setLineWidth(7.0)
        c.setLineCap(.round)
        c.strokePath()
    }
}
