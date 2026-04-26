import SwiftUI

// MARK: - OKLCH conversion

private func linearize(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func delinearize(_ c: Double) -> Double {
    c <= 0.0031308 ? c * 12.92 : pow(c, 1.0 / 2.4) * 1.055 - 0.055
}

private func hexToHue(_ hex: String) -> Double {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if h.count == 3 { h = h.flatMap { [$0, $0] }.map(String.init).joined() }
    guard h.count == 6, let n = UInt32(h, radix: 16) else { return 300 }
    let r = linearize(Double((n >> 16) & 0xFF) / 255)
    let g = linearize(Double((n >>  8) & 0xFF) / 255)
    let b = linearize(Double( n        & 0xFF) / 255)
    let ll = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    let ml = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    let sl = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    let l_ = cbrt(ll), m_ = cbrt(ml), s_ = cbrt(sl)
    let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    var hue = atan2(B, A) * 180 / .pi
    if hue < 0 { hue += 360 }
    return hue
}

func colorFromHex(_ hex: String) -> Color {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if h.count == 3 { h = h.flatMap { [$0, $0] }.map(String.init).joined() }
    guard h.count == 6, let n = UInt32(h, radix: 16) else { return .purple }
    return Color(
        red:   Double((n >> 16) & 0xFF) / 255,
        green: Double((n >>  8) & 0xFF) / 255,
        blue:  Double( n        & 0xFF) / 255
    )
}

func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> Color {
    let hRad = h * .pi / 180
    let A = c * cos(hRad), B = c * sin(hRad)
    let l_ = l + 0.3963377774 * A + 0.2158037573 * B
    let m_ = l - 0.1055613458 * A - 0.0638541728 * B
    let s_ = l - 0.0894841775 * A - 1.2914855480 * B
    let lv = l_ * l_ * l_, mv = m_ * m_ * m_, sv = s_ * s_ * s_
    func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
    let r = delinearize(clamp( 4.0767416621 * lv - 3.3077115913 * mv + 0.2309699292 * sv))
    let g = delinearize(clamp(-1.2684380046 * lv + 2.6097574011 * mv - 0.3413193965 * sv))
    let b = delinearize(clamp(-0.0041960863 * lv - 0.7034186147 * mv + 1.7076147010 * sv))
    return Color(red: r, green: g, blue: b, opacity: alpha)
}

// MARK: - AppTheme

struct AppTheme {
    let canvas:     Color
    let paper:      Color
    let paper2:     Color
    let ink:        Color
    let ink2:       Color
    let ink3:       Color
    let ink4:       Color
    let hair:       Color
    let hair2:      Color
    let accent:     Color
    let accentSoft: Color
    let accentDeep: Color
    let rec:        Color
    let ok:         Color
    let fieldBg:    Color

    static func build(hex: String, dark: Bool) -> AppTheme {
        let H = hexToHue(hex)
        let a = colorFromHex(hex)
        if dark {
            return AppTheme(
                canvas:     oklch(0.13,  0.010, H),
                paper:      oklch(0.19,  0.014, H),
                paper2:     oklch(0.24,  0.018, H),
                ink:        oklch(0.96,  0.008, H),
                ink2:       oklch(0.80,  0.012, H),
                ink3:       oklch(0.62,  0.010, H),
                ink4:       oklch(0.45,  0.008, H),
                hair:       oklch(0.95,  0.010, H, alpha: 0.12),
                hair2:      oklch(0.95,  0.010, H, alpha: 0.06),
                accent:     a,
                accentSoft: oklch(0.45,  0.12,  H, alpha: 0.22),
                accentDeep: oklch(0.62,  0.16,  H),
                rec:        oklch(0.65,  0.18,  25),
                ok:         oklch(0.72,  0.13,  145),
                fieldBg:    oklch(0.95,  0.010, H, alpha: 0.05)
            )
        } else {
            return AppTheme(
                canvas:     oklch(0.92,  0.012, H),
                paper:      oklch(0.965, 0.010, H),
                paper2:     oklch(0.985, 0.008, H),
                ink:        oklch(0.20,  0.020, H),
                ink2:       oklch(0.35,  0.018, H),
                ink3:       oklch(0.55,  0.015, H),
                ink4:       oklch(0.72,  0.012, H),
                hair:       oklch(0.20,  0.020, H, alpha: 0.10),
                hair2:      oklch(0.20,  0.020, H, alpha: 0.06),
                accent:     a,
                accentSoft: oklch(0.92,  0.05,  H),
                accentDeep: oklch(0.42,  0.12,  H),
                rec:        oklch(0.58,  0.18,  25),
                ok:         oklch(0.65,  0.10,  145),
                fieldBg:    Color(white: 1, opacity: 0.62)
            )
        }
    }
}

// MARK: - ThemeManager

final class ThemeManager: ObservableObject {
    @Published private(set) var light: AppTheme
    @Published private(set) var dark:  AppTheme

    var accentHex: String {
        get { UserDefaults.standard.string(forKey: "murmur.accentHex") ?? "#b365d7" }
        set {
            UserDefaults.standard.set(newValue, forKey: "murmur.accentHex")
            rebuild()
        }
    }

    init() {
        let hex = UserDefaults.standard.string(forKey: "murmur.accentHex") ?? "#b365d7"
        light = AppTheme.build(hex: hex, dark: false)
        dark  = AppTheme.build(hex: hex, dark: true)
    }

    private func rebuild() {
        light = AppTheme.build(hex: accentHex, dark: false)
        dark  = AppTheme.build(hex: accentHex, dark: true)
        objectWillChange.send()
    }

    func theme(for scheme: ColorScheme) -> AppTheme {
        scheme == .dark ? dark : light
    }
}

// MARK: - Environment key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.build(hex: "#b365d7", dark: false)
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Presets

struct ThemePreset: Identifiable {
    let id:     String
    let name:   String
    let sub:    String
    let canvas: String
    let mid:    String
    let accent: String
}

let themePresets: [ThemePreset] = [
    ThemePreset(id: "warmCoral",    name: "Warm coral",       sub: "Off-white · soft coral",       canvas: "#f7f4ee", mid: "#4a4338", accent: "#d97757"),
    ThemePreset(id: "paperSage",    name: "Paper sage",       sub: "Cream · muted sage green",      canvas: "#f4f1e6", mid: "#46463a", accent: "#7a8c64"),
    ThemePreset(id: "graphiteBlue", name: "Graphite + steel", sub: "Cool minimal · slate blue",     canvas: "#eef0f3", mid: "#3c424c", accent: "#5d7eaa"),
    ThemePreset(id: "midnight",     name: "Midnight",         sub: "Dark · soft amber accent",      canvas: "#1e2026", mid: "#bcb6a8", accent: "#e0a560"),
    ThemePreset(id: "ivoryBerry",   name: "Ivory + berry",    sub: "Bright cream · plum accent",    canvas: "#f8f3ef", mid: "#4a3a40", accent: "#9c4a6e"),
    ThemePreset(id: "monoTerminal", name: "Mono terminal",    sub: "High-contrast · electric green", canvas: "#ebecec", mid: "#2c2e30", accent: "#3a8d6b"),
]

// MARK: - Color ↔ hex helpers

import AppKit

private func colorToHex(_ color: Color) -> String {
    guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "#b365d7" }
    let r = Int((ns.redComponent   * 255).rounded())
    let g = Int((ns.greenComponent * 255).rounded())
    let b = Int((ns.blueComponent  * 255).rounded())
    return String(format: "#%02x%02x%02x", r, g, b)
}

extension ThemeManager {
    var accentColor: Color {
        get { colorFromHex(accentHex) }
        set { accentHex = colorToHex(newValue) }
    }
}

// MARK: - Preset row view

struct PresetRow: View {
    let preset:     ThemePreset
    let isSelected: Bool
    let onSelect:   () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Swatch
                HStack(spacing: 0) {
                    colorFromHex(preset.canvas)
                    colorFromHex(preset.mid)
                    colorFromHex(preset.accent)
                }
                .frame(width: 60, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.hair, lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.ink)
                    Text(preset.sub)
                        .font(.caption)
                        .foregroundStyle(theme.ink3)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? theme.accentSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root theme wrapper

struct ThemedRoot<Content: View>: View {
    @ObservedObject var tm: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.theme, tm.theme(for: colorScheme))
    }
}
