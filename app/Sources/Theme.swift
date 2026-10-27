import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
    init(r: Double, g: Double, b: Double, a: Double) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

struct Theme {
    let isDark: Bool
    let bg, bg2, card, tile, tileSelected, ink, ink2, ink3, navInk, line: Color
    let accent, accentSoft, ok, alarm, warn, btnBg, btnFg: Color
    let shadow: Color

    static let dark = Theme(
        isDark: true,
        bg: Color(hex: 0x101114), bg2: Color(hex: 0x15161A), card: Color(hex: 0x17191E),
        tile: Color(hex: 0x1D1F25), tileSelected: Color.white.opacity(0.10),
        ink: Color(r: 240, g: 238, b: 232, a: 0.94), ink2: Color(hex: 0xA6A69E),
        ink3: Color(hex: 0x6E6F6A), navInk: Color(hex: 0xC9C6BE),
        line: Color.white.opacity(0.07),
        accent: Color(hex: 0xE0596F), accentSoft: Color(r: 224, g: 89, b: 111, a: 0.15),
        ok: Color(hex: 0x4CC38A), alarm: Color(hex: 0xFF6A4D), warn: Color(hex: 0xE5A43B),
        btnBg: Color(hex: 0xE8E6E0), btnFg: Color(hex: 0x111111),
        shadow: Color.black.opacity(0.35))

    static let light = Theme(
        isDark: false,
        bg: Color(hex: 0xF5F4F0), bg2: Color(hex: 0xEEEDE8), card: Color.white,
        tile: Color(hex: 0xEEEDE8), tileSelected: Color.white,
        ink: Color(r: 20, g: 18, b: 14, a: 0.92), ink2: Color(hex: 0x5E5B55),
        ink3: Color(hex: 0x7D7A72), navInk: Color(hex: 0x3E3B36),
        line: Color(r: 20, g: 18, b: 14, a: 0.08),
        accent: Color(hex: 0x8A2F42), accentSoft: Color(hex: 0xF7E9EC),
        ok: Color(hex: 0x2E7D5B), alarm: Color(hex: 0xD4351C), warn: Color(hex: 0xB86E00),
        btnBg: Color(r: 20, g: 18, b: 14, a: 0.92), btnFg: Color.white,
        shadow: Color(r: 20, g: 18, b: 14, a: 0.08))

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? dark : light }

    func stateColor(_ s: VPNState) -> Color {
        switch s {
        case .ok: return ok
        case .slow, .degraded: return warn
        case .down: return alarm
        case .off: return ink3
        case .connecting: return ink2
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemedRoot<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content.environment(\.theme, Theme.of(scheme))
    }
}

enum Fonts {
    static let hasInter: Bool = NSFont(name: "Inter", size: 13) != nil
}

func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    Fonts.hasInter ? Font.custom("Inter", size: size).weight(weight)
                   : Font.system(size: size, weight: weight)
}

func appNum(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    appFont(size, weight).monospacedDigit()
}

struct CardStyle: ViewModifier {
    @Environment(\.theme) private var t
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(t.card)
                    .shadow(color: t.shadow, radius: t.isDark ? 15 : 8, x: 0, y: t.isDark ? 10 : 2))
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardStyle(padding: padding)) }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func numeric<V: Equatable>(_ value: V) -> some View {
        contentTransition(.numericText())
            .animation(.easeOut(duration: 0.3), value: value)
    }
}
