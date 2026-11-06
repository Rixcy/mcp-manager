import AppKit
import SwiftUI

/// Orc design tokens (`orc/theme/orc-tokens.json`) as appearance-aware colours.
enum Theme {
    static let bg = dynamic(day: 0xe3e5e4, night: 0x1a1c20)
    static let panel = dynamic(day: 0xeceeec, night: 0x16181b)
    static let border = dynamic(day: 0xa8b0aa, night: 0x3b4540)
    static let text = dynamic(day: 0x38423c, night: 0xc7cfca)
    static let heading = dynamic(day: 0x202722, night: 0xe0e5e2)
    static let muted = dynamic(day: 0x6e7971, night: 0x707a73)
    static let accent = dynamic(day: 0x2d6983, night: 0x78a9c2)
    static let accentSoft = dynamic(day: 0xcbd1cc, night: 0x29312c)
    static let chip = dynamic(day: 0xcbd1cc, night: 0x29312c)
    static let code = dynamic(day: 0xd4d8d5, night: 0x1f2422)
    static let green = dynamic(day: 0x53743a, night: 0x9dc76b)
    static let yellow = dynamic(day: 0x8a6a2f, night: 0xd5b05c)
    static let red = dynamic(day: 0xb83f50, night: 0xe87878)
    static let purple = dynamic(day: 0x76518f, night: 0xb497d6)
    static let cyan = dynamic(day: 0x256f72, night: 0x77b8b1)
    static let orange = dynamic(day: 0x9a5a25, night: 0xe69257)

    // AA text variants: small coloured text never uses a raw hue that fails 4.5:1,
    // so the day values are mixed toward heading ink (DESIGN.md, AA Text Variant Rule).
    static let gateText = dynamic(day: mix(0x9a5a25, 0x202722, 0.3), night: rgb(0xe69257))
    static let redText = dynamic(day: mix(0xb83f50, 0x202722, 0.2), night: rgb(0xe87878))
    static let greenText = dynamic(day: mix(0x53743a, 0x202722, 0.2), night: rgb(0x9dc76b))
    static let yellowText = dynamic(day: mix(0x8a6a2f, 0x202722, 0.25), night: rgb(0xd5b05c))
    static let mutedStrong = dynamic(day: mix(0x6e7971, 0x38423c, 0.4), night: mix(0x707a73, 0xc7cfca, 0.35))

    static let panelRadius: CGFloat = 8
    static let chipRadius: CGFloat = 12

    static let tintFill = 0.13
    static let tintBorder = 0.4

    static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        if jetBrainsMonoInstalled {
            return .custom("JetBrains Mono", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static let headline = Font.system(size: 17, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .semibold)

    private static let jetBrainsMonoInstalled = NSFont(name: "JetBrainsMono-Regular", size: 12) != nil

    private static func dynamic(day: UInt32, night: UInt32) -> Color {
        dynamic(day: rgb(day), night: rgb(night))
    }

    private static func dynamic(day: NSColor, night: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? night : day
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        let (r, g, b) = components(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// `color-mix(in srgb, a, b t)`: t is the share of `b`.
    private static func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> NSColor {
        let (ar, ag, ab) = components(a)
        let (br, bg, bb) = components(b)
        return NSColor(srgbRed: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
    }

    private static func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
    }
}

/// Semantic tone for chips and banners. Every tone is paired with text, never colour alone.
enum Tone {
    case neutral, accent, gate, green, yellow, red

    var hue: Color {
        switch self {
        case .neutral: return Theme.border
        case .accent: return Theme.accent
        case .gate: return Theme.orange
        case .green: return Theme.green
        case .yellow: return Theme.yellow
        case .red: return Theme.red
        }
    }

    var textColor: Color {
        switch self {
        case .neutral: return Theme.text
        case .accent: return Theme.accent
        case .gate: return Theme.gateText
        case .green: return Theme.greenText
        case .yellow: return Theme.yellowText
        case .red: return Theme.redText
        }
    }

    var fill: Color { self == .neutral ? Theme.chip : hue.opacity(Theme.tintFill) }
    var stroke: Color { self == .neutral ? Theme.border : hue.opacity(Theme.tintBorder) }
}
