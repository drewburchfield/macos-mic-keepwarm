import AppKit
import MicWarmCore

/// The "Fire circle" menu-bar glyph: a top-down campfire, flame inside a ring of six stones.
///
/// Geometry comes straight from the icon comps (18 × 18 pt view box, y down). The glyph is a
/// one-color template image, so each state reads from shape alone and macOS tints it for
/// light, dark, and highlighted menu bars.
enum FireCircleGlyph {
    static let size = NSSize(width: 18, height: 18)

    /// The ring has six stones, so a 60° turn looks identical to the start.
    static let ringSymmetry: CGFloat = 60

    static func image(for state: WarmState, ringRotation: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, ringRotation: ringRotation, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// Frames for one stone-to-stone step of the spinning ring. Looping them reads as a
    /// steady clockwise spin.
    static func spinFrames(for state: WarmState, count: Int) -> [NSImage] {
        (0..<count).map { i in
            image(for: state, ringRotation: ringSymmetry * CGFloat(i) / CGFloat(count))
        }
    }

    // MARK: - Geometry from the comps

    private static let flame = path("M9 1.5C9.8 4 13.5 5.8 13.5 9.6C13.5 11.9 11.5 13 9 13C6.5 13 4.5 11.9 4.5 9.6C4.5 7.6 5.7 6.4 6.6 5.6C6.7 7 7.3 7.8 8 8C7.6 5.8 8.2 3.3 9 1.5Z")
    private static let smoke = path("M6.6 12.4C4.6 11 8.6 9.7 6.6 8.3C4.6 6.9 8.6 5.6 6.6 4.2M11.4 12.4C9.4 10.8 13.4 9.1 11.4 7.5C9.4 5.9 13.4 4.2 11.4 2.6")
    private static let sparks: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(5.2, 6.2, 0.85), (12.6, 4.4, 0.75), (10.6, 1.9, 0.6)]
    private static let slashStart = CGPoint(x: 6, y: 5.4)
    private static let slashEnd = CGPoint(x: 12.4, y: 11.8)

    /// Shrinks the flame layers to sit inside the ring: translate(9 9) scale(.76) translate(-9 -7.25).
    private static let insideRing = CGAffineTransform(translationX: 9, y: 9)
        .scaledBy(x: 0.76, y: 0.76)
        .translatedBy(x: -9, y: -7.25)

    /// The recovering flame burns low: scale(.66) about the flame's base at (9, 13).
    private static let lowFlame = CGAffineTransform(translationX: 9, y: 13)
        .scaledBy(x: 0.66, y: 0.66)
        .translatedBy(x: -9, y: -13)

    private static func path(_ d: String) -> CGPath {
        // The strings above are fixed artwork; a parse failure is a programming error.
        let commands = try! parseSVGPath(d)
        let p = CGMutablePath()
        for command in commands {
            switch command {
            case let .move(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .curve(x1, y1, x2, y2, x, y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                           control2: CGPoint(x: x2, y: y2))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    // MARK: - Drawing

    static func draw(_ state: WarmState, ringRotation: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineCap(.round)

        switch state {
        case .warm:
            withTransform(insideRing, ctx) {
                ctx.addPath(flame)
                ctx.fillPath()
            }

        case .recovering:
            withTransform(insideRing, ctx) {
                withTransform(lowFlame, ctx) {
                    ctx.addPath(flame)
                    ctx.fillPath()
                }
                for s in sparks {
                    ctx.fillEllipse(in: CGRect(x: s.x - s.r, y: s.y - s.r, width: s.r * 2, height: s.r * 2))
                }
            }

        case .paused:
            withTransform(insideRing, ctx) {
                ctx.setLineWidth(2.3)
                ctx.addPath(smoke)
                ctx.strokePath()
            }

        case .needsAccess:
            // Hollow flame with a gap cut where the slash crosses it, then the slash itself.
            // The transparency layer keeps the cut from erasing whatever sits behind the image.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            withTransform(insideRing, ctx) {
                ctx.setLineWidth(1.8)
                ctx.setLineJoin(.round)
                ctx.addPath(flame)
                ctx.strokePath()
            }
            ctx.setBlendMode(.clear)
            strokeSlash(width: 3.6, ctx)
            ctx.setBlendMode(.normal)
            ctx.endTransparencyLayer()
            strokeSlash(width: 1.6, ctx)
        }

        drawRing(rotation: ringRotation, in: ctx)
    }

    private static func strokeSlash(width: CGFloat, _ ctx: CGContext) {
        ctx.setLineWidth(width)
        ctx.move(to: slashStart)
        ctx.addLine(to: slashEnd)
        ctx.strokePath()
    }

    /// Six stones: a dashed circle, r 7.6, stroke 2.4, dashes 3 on 4.96 off, rotated -80°.
    private static func drawRing(rotation: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 9, y: 9)
        ctx.rotate(by: (-80 + rotation) * .pi / 180)
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [3, 4.96])
        // Starts at 3 o'clock and runs clockwise in this y-down space, like an SVG circle.
        ctx.addArc(center: .zero, radius: 7.6, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func withTransform(_ t: CGAffineTransform, _ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.concatenate(t)
        body()
        ctx.restoreGState()
    }
}
