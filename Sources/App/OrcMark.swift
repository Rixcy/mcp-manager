import AppKit
import SwiftUI

/// The MCP Manager emblem: the Orc head from `orc/assets/orc-logo.svg` worn as a
/// plug, with two prongs on top and a cable leaving the chin. Coordinates match
/// `assets/mcp-manager-icon.svg` (origin at the centre of the face, y down).
enum OrcEmblem {
    static let bounds = CGRect(x: -80, y: -92, width: 160, height: 176)
    static let silhouetteBounds = CGRect(x: -80, y: -92, width: 160, height: 146)

    static let earLeft = polygon([(-52, -14), (-78, -34), (-58, 2)])
    static let earRight = polygon([(52, -14), (78, -34), (58, 2)])

    static let head = Path { p in
        p.move(to: pt(-54, -18))
        p.addCurve(to: pt(0, -64), control1: pt(-54, -52), control2: pt(-30, -64))
        p.addCurve(to: pt(54, -18), control1: pt(30, -64), control2: pt(54, -52))
        p.addCurve(to: pt(26, 40), control1: pt(54, 10), control2: pt(40, 30))
        p.addCurve(to: pt(0, 52), control1: pt(14, 49), control2: pt(10, 52))
        p.addCurve(to: pt(-26, 40), control1: pt(-10, 52), control2: pt(-14, 49))
        p.addCurve(to: pt(-54, -18), control1: pt(-40, 30), control2: pt(-54, 10))
        p.closeSubpath()
    }

    static let prongLeft = Path(roundedRect: CGRect(x: -22, y: -90, width: 12, height: 32), cornerRadius: 3)
    static let prongRight = Path(roundedRect: CGRect(x: 10, y: -90, width: 12, height: 32), cornerRadius: 3)
    static let prongHoles = Path { p in
        p.addEllipse(in: CGRect(x: -18.5, y: -84.5, width: 5, height: 5))
        p.addEllipse(in: CGRect(x: 13.5, y: -84.5, width: 5, height: 5))
    }

    static let browLeft = polygon([(-40, -24), (-8, -14), (-8, -4), (-42, -12)])
    static let browRight = polygon([(40, -24), (8, -14), (8, -4), (42, -12)])
    static let eyeWhites = circles([(-24, 0), (24, 0)], radius: 6.5)
    static let pupils = circles([(-23, 1), (25, 1)], radius: 3)
    static let nose = polygon([(0, 8), (-9, 24), (9, 24)])
    static let mouth = Path { p in
        p.move(to: pt(-16, 36))
        p.addQuadCurve(to: pt(16, 36), control: pt(0, 44))
    }
    static let tuskLeft = polygon([(-16, 40), (-22, 14), (-9, 36)])
    static let tuskRight = polygon([(16, 40), (22, 14), (9, 36)])

    static let cable = Path { p in
        p.move(to: pt(0, 50))
        p.addCurve(to: pt(48, 70), control1: pt(2, 72), control2: pt(26, 76))
    }
    static let cableNode = Path(ellipseIn: CGRect(x: 46, y: 60, width: 18, height: 18))

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { p in
            p.addLines(points.map { pt($0.0, $0.1) })
            p.closeSubpath()
        }
    }

    private static func circles(_ centres: [(CGFloat, CGFloat)], radius: CGFloat) -> Path {
        Path { p in
            for c in centres {
                p.addEllipse(in: CGRect(x: c.0 - radius, y: c.1 - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    /// Scale-to-fit transform from emblem space into `rect`, centred.
    static func transform(fitting box: CGRect, into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / box.width, rect.height / box.height)
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
    }

    // MARK: Menu bar template

    /// 18pt monochrome silhouette for the status item. Facial features are cut
    /// out so the template reads as the orc on both light and dark menu bars.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let t = transform(fitting: silhouetteBounds, into: rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.concatenate(t)
            ctx.setFillColor(NSColor.black.cgColor)
            for part in [earLeft, earRight, prongLeft, prongRight, head] {
                ctx.addPath(part.cgPath)
            }
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.addPath(browLeft.cgPath)
            ctx.addPath(browRight.cgPath)
            ctx.addPath(circles([(-24, 2), (24, 2)], radius: 8).cgPath)
            ctx.addPath(nose.cgPath)
            ctx.fillPath()
            ctx.setLineWidth(7)
            ctx.setLineCap(.round)
            ctx.addPath(mouth.cgPath)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MCP Manager"
        return image
    }()
}

/// Full-colour emblem for headers. First-party brand art, so it may use palette
/// hues outside their status meaning (DESIGN.md, Orc Palette Rule).
struct OrcMark: View {
    var showsCable = true

    private static let skinTop = Color(nsColor: NSColor(srgbRed: 0x9d / 255.0, green: 0xc7 / 255.0, blue: 0x6b / 255.0, alpha: 1))
    private static let skinBottom = Color(nsColor: NSColor(srgbRed: 0x53 / 255.0, green: 0x74 / 255.0, blue: 0x3a / 255.0, alpha: 1))
    private static let ink = Color(nsColor: NSColor(srgbRed: 0x20 / 255.0, green: 0x27 / 255.0, blue: 0x22 / 255.0, alpha: 1))
    private static let bone = Color(nsColor: NSColor(srgbRed: 0xec / 255.0, green: 0xee / 255.0, blue: 0xec / 255.0, alpha: 1))
    private static let pupil = Color(nsColor: NSColor(srgbRed: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1b / 255.0, alpha: 1))
    private static let metal = Color(nsColor: NSColor(srgbRed: 0xc7 / 255.0, green: 0xcf / 255.0, blue: 0xca / 255.0, alpha: 1))

    private var box: CGRect { showsCable ? OrcEmblem.bounds : OrcEmblem.silhouetteBounds }

    var body: some View {
        Canvas { ctx, size in
            let box = self.box
            ctx.concatenate(OrcEmblem.transform(fitting: box, into: CGRect(origin: .zero, size: size)))
            let E = OrcEmblem.self
            let outline = StrokeStyle(lineWidth: 4, lineJoin: .round)

            if showsCable {
                ctx.stroke(E.cable, with: .color(Theme.cyan), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                ctx.fill(E.cableNode, with: .color(Theme.cyan))
                ctx.stroke(E.cableNode, with: .color(Self.ink), lineWidth: 3)
            }
            for prong in [E.prongLeft, E.prongRight] {
                ctx.fill(prong, with: .color(Self.metal))
                ctx.stroke(prong, with: .color(Self.ink), lineWidth: 3)
            }
            ctx.fill(E.prongHoles, with: .color(Self.ink))
            ctx.fill(E.earLeft, with: .color(Self.skinBottom))
            ctx.fill(E.earRight, with: .color(Self.skinBottom))
            ctx.fill(E.head, with: .linearGradient(
                Gradient(colors: [Self.skinTop, Self.skinBottom]),
                startPoint: CGPoint(x: 0, y: -64), endPoint: CGPoint(x: 0, y: 52)
            ))
            ctx.stroke(E.head, with: .color(Self.ink), style: outline)
            ctx.fill(E.browLeft, with: .color(Self.ink))
            ctx.fill(E.browRight, with: .color(Self.ink))
            ctx.fill(E.eyeWhites, with: .color(Self.bone))
            ctx.fill(E.pupils, with: .color(Self.pupil))
            ctx.fill(E.nose, with: .color(Self.ink))
            ctx.stroke(E.mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            for tusk in [E.tuskLeft, E.tuskRight] {
                ctx.fill(tusk, with: .color(Self.bone))
                ctx.stroke(tusk, with: .color(Self.ink), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
