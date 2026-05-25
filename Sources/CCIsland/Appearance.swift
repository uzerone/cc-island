import SwiftUI
import AppKit
import Combine

/// User-selectable appearance. `system` defers to macOS Dark/Light. The two
/// glass variants share a backdrop blur but differ in tint — `clear` shows
/// pure material, `tinted` adds a soft overlay for legibility on busy
/// wallpapers.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    case glassClear  = "glass_clear"
    case glassTinted = "glass_tinted"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:      return "Auto"
        case .dark:        return "Dark"
        case .light:       return "Light"
        case .glassClear:  return "Glass"
        case .glassTinted: return "Tinted"
        }
    }

    var systemImage: String {
        switch self {
        case .system:      return "circle.lefthalf.filled"
        case .dark:        return "moon.fill"
        case .light:       return "sun.max.fill"
        case .glassClear:  return "drop"
        case .glassTinted: return "drop.fill"
        }
    }

    var help: String {
        switch self {
        case .system:      return "Follow macOS Dark/Light"
        case .dark:        return "Dark pill"
        case .light:       return "Light pill"
        case .glassClear:  return "Translucent — pure material"
        case .glassTinted: return "Translucent with soft tint"
        }
    }
}

/// Resolved "concrete" appearance — what gets actually rendered. `system`
/// gets resolved to one of these before producing theme tokens.
enum ResolvedAppearance {
    case dark
    case light
    case glassClear
    case glassTinted
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
        case .system:      return systemIsDark ? .dark : .light
        case .dark:        return .dark
        case .light:       return .light
        case .glassClear:  return .glassClear
        case .glassTinted: return .glassTinted
        }
    }
}

/// Color tokens. Every surface in the island reads from here so a single
/// appearance change re-paints everything coherently. On glass variants the
/// backdrop is provided by `NSVisualEffectView`; `panelFill` is transparent.
struct Theme {
    let resolved: ResolvedAppearance

    var isGlass: Bool {
        switch resolved {
        case .glassClear, .glassTinted: return true
        default: return false
        }
    }

    /// True when the resolved palette is light — drives text color picks.
    var isLight: Bool { resolved == .light }

    var panelFill: Color {
        switch resolved {
        case .dark:        return .black
        case .light:       return Color(white: 0.97)
        case .glassClear,
             .glassTinted: return .clear
        }
    }

    /// Tint laid over the glass backdrop. `clear` gets none — pure material;
    /// `tinted` gets a soft white wash to lift contrast.
    var panelTint: Color {
        switch resolved {
        case .glassTinted: return Color.white.opacity(0.08)
        default:           return .clear
        }
    }

    var borderTopHighlight: Color {
        switch resolved {
        case .dark:         return .white.opacity(0.12)
        case .light:        return .black.opacity(0.10)
        case .glassClear:   return .white.opacity(0.22)
        case .glassTinted:  return .white.opacity(0.30)
        }
    }
    var borderBottomShade: Color {
        switch resolved {
        case .dark:         return .white.opacity(0.02)
        case .light:        return .black.opacity(0.02)
        case .glassClear:   return .white.opacity(0.04)
        case .glassTinted:  return .white.opacity(0.05)
        }
    }

    var shadow: Color {
        switch resolved {
        case .dark:         return .black.opacity(0.45)
        case .light:        return .black.opacity(0.18)
        case .glassClear,
             .glassTinted:  return .black.opacity(0.30)
        }
    }

    var primaryText: Color {
        isLight ? Color(white: 0.08) : .white
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

/// Wraps `NSVisualEffectView` so we can drop a vibrant blur behind the pill
/// for the glass appearances. Material/state match Apple's HUD windows so it
/// looks at home in the menu-bar area.
///
/// The corner radius is applied to the view's own layer, not via SwiftUI's
/// `clipShape`. SwiftUI clipping forces an offscreen render pass that breaks
/// the `.behindWindow` blur — you'd get an opaque gray rectangle instead of
/// a true vibrant background.
///
/// Mask configuration drives which corners the NSVisualEffectView's layer
/// rounds. We always round the bottom; the top is rounded only in free-move
/// placement where the pill isn't docked to the menu bar.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0
    var roundTopCorners: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        v.wantsLayer = true
        configureLayer(of: v)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        configureLayer(of: nsView)
    }

    private func configureLayer(of view: NSVisualEffectView) {
        guard let layer = view.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        // NSView's backing layer is NOT geometry-flipped — origin is at the
        // bottom-left. So "bottom" corners are the MinY pair, "top" is MaxY.
        var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if roundTopCorners {
            corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        layer.maskedCorners = corners
        layer.masksToBounds = true
    }
}
