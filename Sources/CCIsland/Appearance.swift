import SwiftUI
import AppKit
import Combine

/// User-selectable appearance. `system` defers to macOS Dark/Light.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark:   return "moon.fill"
        case .light:  return "sun.max.fill"
        }
    }

    var help: String {
        switch self {
        case .system: return "Follow macOS Dark/Light"
        case .dark:   return "Dark pill"
        case .light:  return "Light pill"
        }
    }
}

/// Resolved "concrete" appearance — what gets actually rendered. `system`
/// gets resolved to one of these before producing theme tokens.
enum ResolvedAppearance {
    case dark
    case light
}

/// Global appearance store. Owns the user's choice and tracks the system's
/// effective appearance so `system` can resolve correctly without each view
/// having to listen to AppKit notifications individually.
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    private static let key = "CCIsland.appearance"

    /// User's pick (may be `.system`).
    @Published var current: Appearance {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
        }
    }

    /// True when macOS is currently in Dark Mode. Updated by KVO on
    /// `NSApp.effectiveAppearance`. Only consulted when `current == .system`.
    @Published private(set) var systemIsDark: Bool = true

    private var observation: NSKeyValueObservation?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? Appearance.dark.rawValue
        self.current = Appearance(rawValue: raw) ?? .dark

        // NSApp may not be fully initialized at static-init time; defer the
        // first read + KVO setup to the next main-loop tick.
        DispatchQueue.main.async { [weak self] in
            self?.refreshSystemAppearance()
            self?.observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshSystemAppearance() }
            }
        }
    }

    private func refreshSystemAppearance() {
        let appearance = NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        let isDark = (match == .darkAqua || match == .vibrantDark)
        if isDark != systemIsDark { systemIsDark = isDark }
    }

    var resolved: ResolvedAppearance {
        switch current {
        case .system: return systemIsDark ? .dark : .light
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

/// Color tokens. Every surface in the island reads from here so a single
/// appearance change re-paints everything coherently.
struct Theme {
    let resolved: ResolvedAppearance

    /// True when the resolved palette is light — drives text color picks.
    var isLight: Bool { resolved == .light }

    var panelFill: Color {
        isLight ? Color(white: 0.97) : .black
    }

    var borderTopHighlight: Color {
        isLight ? .black.opacity(0.10) : .white.opacity(0.12)
    }
    var borderBottomShade: Color {
        isLight ? .black.opacity(0.02) : .white.opacity(0.02)
    }

    var shadow: Color {
        isLight ? .black.opacity(0.18) : .black.opacity(0.45)
    }

    var primaryText: Color {
        isLight ? Color(white: 0.08) : .white
    }

    /// Apple HIG-style named opacity tiers. Mirrors `NSColor.labelColor`,
    /// `secondaryLabelColor`, etc. — primary 100%, secondary ~78%, tertiary
    /// ~52%, quaternary ~32%. Replaces ad-hoc opacity values across the UI
    /// so the hierarchy reads consistently.
    enum TextTier { case primary, secondary, tertiary, quaternary }
    func text(_ tier: TextTier) -> Color {
        let alpha: Double
        switch tier {
        case .primary:    alpha = 1.0
        case .secondary:  alpha = 0.78
        case .tertiary:   alpha = 0.52
        case .quaternary: alpha = 0.32
        }
        return isLight ? Color(white: 0.08).opacity(alpha) : .white.opacity(alpha)
    }

    func secondaryText(_ alpha: Double = 0.65) -> Color {
        isLight ? Color(white: 0.08).opacity(alpha) : .white.opacity(alpha)
    }

    func chrome(_ alpha: Double = 0.08) -> Color {
        isLight ? .black.opacity(alpha) : .white.opacity(alpha)
    }

    var progressTrack: Color { chrome(0.08) }

    var accentStart: Color {
        isLight
            ? Color(red: 0.20, green: 0.55, blue: 0.95)
            : Color(red: 0.55, green: 0.85, blue: 1.0)
    }
    var accentEnd: Color {
        isLight
            ? Color(red: 0.35, green: 0.35, blue: 0.95)
            : Color(red: 0.45, green: 0.55, blue: 1.0)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(resolved: .dark)
}

extension EnvironmentValues {
    var ccTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
