// Inline port of KatafractStyle v0.1.1 — migrate to SPM when xcodeproj is modernized.

import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color palette

extension Color {

    // MARK: Primary palette

    /// Deep cobalt background. #0F2652
    static let kataNavy = Color(red: 0.059, green: 0.149, blue: 0.322)

    /// Near-black accent for gradient bottoms. #020610
    static let kataMidnight = Color(red: 0.008, green: 0.024, blue: 0.063)

    /// Sapphire-blue CTA accent. #1F5FAE
    static let kataSapphire = Color(red: 0.122, green: 0.373, blue: 0.682)

    /// Pale sky-blue highlight. #B8DFFF
    static let kataIce = Color(red: 0.722, green: 0.875, blue: 1.000)

    // MARK: Accent (premium)

    /// Warm champagne gold. #C69838
    static let kataGold = Color(red: 0.776, green: 0.596, blue: 0.220)

    /// Bright champagne highlight. #FFE89A
    static let kataChampagne = Color(red: 1.000, green: 0.910, blue: 0.604)

    /// Deep bronze shadow. #6E4E15
    static let kataBronze = Color(red: 0.431, green: 0.306, blue: 0.082)

    // MARK: Semantic aliases

    static let kataSurface  = Color.kataNavy
    static let kataAction   = Color.kataSapphire
    static let kataPremium  = Color.kataGold
}

// MARK: - Typography

extension Font {

    /// Serif hero/display font. 40pt default.
    static func kataDisplay(_ size: CGFloat = 40, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Mid-tier headline. 24pt default.
    static func kataHeadline(_ size: CGFloat = 24, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Body copy. 16pt default.
    static func kataBody(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Small caption. 12pt default.
    static func kataCaption(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospace for keys, pings, technical content. 14pt default.
    static func kataMono(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Haptics

/// Semantic haptic vocabulary for Katafract apps.
/// Never call UIImpactFeedbackGenerator directly — use this enum.
enum KataHaptic {
    /// Vault unlocked, biometric passed, sub activated.
    case unlocked
    /// Action committed — save, submit, upload complete.
    case saved
    /// Panel revealed — modal presented.
    case revealed
    /// User error — wrong input, denied permission.
    case denied
    /// Subtle tap — selection moved, toggle flipped.
    case tap
    /// Destructive confirmation — delete, logout, wipe.
    case destructive

    @MainActor
    func fire() {
        #if canImport(UIKit)
        switch self {
        case .unlocked:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.success)
        case .saved:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare(); g.impactOccurred()
        case .revealed:
            let g = UIImpactFeedbackGenerator(style: .rigid)
            g.prepare(); g.impactOccurred()
        case .denied:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.error)
        case .tap:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare(); g.impactOccurred()
        case .destructive:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.warning)
        }
        #endif
    }
}
