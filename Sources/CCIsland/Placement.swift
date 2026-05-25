import SwiftUI
import AppKit
import Combine

/// How the island is positioned on screen.
///
/// • `notch` — anchored under the menu bar / camera notch, top-center.
///   Square top edge so it merges visually with the menu bar.
/// • `freeMove` — floats anywhere; user drags the pill to position it.
///   Fully-rounded silhouette since it's no longer docking to anything.
enum Placement: String, CaseIterable, Identifiable {
    case notch
    case freeMove = "free_move"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notch:    return "Notch"
        case .freeMove: return "Free"
        }
    }

    var systemImage: String {
        switch self {
        case .notch:    return "rectangle.topthird.inset.filled"
        case .freeMove: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var help: String {
        switch self {
        case .notch:    return "Anchored under the menu bar / notch"
        case .freeMove: return "Drag to place anywhere on screen"
        }
    }
}

/// Stores the user's placement choice and — for free-move mode — the last
/// origin the user dragged the window to (in screen coords). AppDelegate
/// observes both: mode changes trigger a reposition; the origin is updated
/// when the user finishes dragging so it survives restarts.
final class PlacementStore: ObservableObject {
    static let shared = PlacementStore()

    private static let modeKey = "CCIsland.placement"
    private static let originXKey = "CCIsland.freeOriginX"
    private static let originYKey = "CCIsland.freeOriginY"

    @Published var mode: Placement {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Last window origin (bottom-left, screen coords) in free-move mode.
    /// `nil` until the user moves the window at least once; AppDelegate
    /// falls back to screen-center on first switch.
    @Published var freeOrigin: CGPoint? {
        didSet {
            if let p = freeOrigin {
                UserDefaults.standard.set(p.x, forKey: Self.originXKey)
                UserDefaults.standard.set(p.y, forKey: Self.originYKey)
            }
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? Placement.notch.rawValue
        self.mode = Placement(rawValue: raw) ?? .notch

        let d = UserDefaults.standard
        if d.object(forKey: Self.originXKey) != nil,
           d.object(forKey: Self.originYKey) != nil {
            self.freeOrigin = CGPoint(x: d.double(forKey: Self.originXKey),
                                      y: d.double(forKey: Self.originYKey))
        } else {
            self.freeOrigin = nil
        }
    }
}
