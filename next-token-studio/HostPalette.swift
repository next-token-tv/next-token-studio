import SwiftUI

// Identity colors come from hosts.json, not channel positions.
enum HostPalette {
    static func color(_ hex: String?, scheme: ColorScheme, fallback: Color = .secondary) -> Color {
        guard let hex, hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return fallback }
        let r = Double((rgb >> 16) & 255) / 255
        let g = Double((rgb >> 8) & 255) / 255
        let b = Double(rgb & 255) / 255
        // Keep the black identity achromatic while making it visible on dark surfaces.
        if scheme == .dark, max(r, g, b) < 0.15 { return Color(white: 0.85) }
        return Color(red: r, green: g, blue: b)
    }
}
