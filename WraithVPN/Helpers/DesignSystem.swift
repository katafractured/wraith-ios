// DesignSystem.swift
// WraithVPN
//
// Centralised colour palette, typography scale, spacing, and gradient helpers.
// All UI files import nothing extra — they reference these tokens directly.

import SwiftUI

// MARK: - Colour palette

extension Color {
    // Backgrounds
    static let kfBackground      = Color(hex: "#0d0f14")
    static let kfSurface         = Color(hex: "#13161e")
    static let kfSurfaceElevated = Color(hex: "#1a1d27")
    static let kfBorder          = Color(hex: "#252836")

    // Accent gradient stops
    static let kfAccentBlue      = Color(hex: "#3b82f6")
    static let kfAccentPurple    = Color(hex: "#7c3aed")
    static let kfAccentMid       = Color(hex: "#6366f1")

    // Status
    static let kfConnected       = Color(hex: "#22c55e")
    static let kfConnecting      = Color(hex: "#facc15")
    static let kfDisconnected    = Color(hex: "#6b7280")
    static let kfError           = Color(hex: "#ef4444")

    // Text
    static let kfTextPrimary     = Color.white
    static let kfTextSecondary   = Color(hex: "#9ca3af")
    static let kfTextMuted       = Color(hex: "#6b7280")

    // Latency tier colours (match LatencyTier.colorHex)
    static let kfLatencyExcellent = Color(hex: "#22c55e")
    static let kfLatencyGood      = Color(hex: "#86efac")
    static let kfLatencyFair      = Color(hex: "#facc15")
    static let kfLatencyPoor      = Color(hex: "#f87171")
    static let kfLatencyUnknown   = Color(hex: "#6b7280")

    // Convenience initialiser from hex string "#RRGGBB" or "#RRGGBBAA"
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned = String(cleaned.dropFirst()) }

        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)

        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((rgb >> 16) & 0xFF) / 255
            g = Double((rgb >>  8) & 0xFF) / 255
            b = Double( rgb        & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((rgb >> 24) & 0xFF) / 255
            g = Double((rgb >> 16) & 0xFF) / 255
            b = Double((rgb >>  8) & 0xFF) / 255
            a = Double( rgb        & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Gradients

extension LinearGradient {
    static let kfAccent = LinearGradient(
        colors: [.kfAccentBlue, .kfAccentMid, .kfAccentPurple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let kfConnectedRing = LinearGradient(
        colors: [Color(hex: "#22c55e"), Color(hex: "#16a34a")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let kfDisconnectedRing = LinearGradient(
        colors: [Color(hex: "#374151"), Color(hex: "#1f2937")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let kfConnectingRing = LinearGradient(
        colors: [Color(hex: "#facc15"), Color(hex: "#d97706")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension AngularGradient {
    static func kfConnectButtonRing(status: VPNStatus) -> AngularGradient {
        let colors: [Color]
        switch status {
        case .connected:
            colors = [.kfConnected, Color(hex: "#86efac"), .kfConnected]
        case .connecting, .disconnecting:
            colors = [.kfConnecting, Color(hex: "#fde68a"), .kfConnecting]
        default:
            colors = [Color(hex: "#374151"), Color(hex: "#4b5563"), Color(hex: "#374151")]
        }
        return AngularGradient(colors: colors, center: .center)
    }
}

// MARK: - Typography

enum KFFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func heading(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func caption(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Spacing

enum KFSpacing {
    static let xxs: CGFloat =  4
    static let xs:  CGFloat =  8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Corner radius

enum KFRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999
}

// MARK: - View modifiers

struct KFCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.kfSurface)
            .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous)
                    .strokeBorder(Color.kfBorder, lineWidth: 1)
            )
    }
}

extension View {
    func kfCard() -> some View {
        modifier(KFCardStyle())
    }

    func kfSafeAreaBackground() -> some View {
        background(Color.kfBackground.ignoresSafeArea())
    }
}

// MARK: - Latency colour helper

extension LatencyTier {
    var swiftUIColor: Color {
        switch self {
        case .excellent: return .kfLatencyExcellent
        case .good:      return .kfLatencyGood
        case .fair:      return .kfLatencyFair
        case .poor:      return .kfLatencyPoor
        case .unknown:   return .kfLatencyUnknown
        }
    }
}

// MARK: - VPNStatus colour

extension VPNStatus {
    var swiftUIColor: Color {
        switch self {
        case .connected:               return .kfConnected
        case .connecting, .disconnecting: return .kfConnecting
        default:                       return .kfDisconnected
        }
    }
}
