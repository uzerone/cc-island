import AppKit
import SwiftUI
import CoreGraphics
import Combine

extension NSScreen {
    /// Underlying CG display ID, or `nil` if unavailable.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    /// Whether this is the Mac's built-in (laptop) display.
    var isBuiltIn: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
    /// Stable identifier that survives reconnects (display ID can change).
    var persistentID: String {
        "\(localizedName)|\(Int(frame.width))x\(Int(frame.height))"
    }
}

/// Hosting view that only accepts mouse events inside the visible pill rect
/// (driven by `HitArea`). Everywhere else, clicks fall through to whatever
/// is beneath the window.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    let hitArea: HitArea

    init(rootView: Content, hitArea: HitArea) {
        self.hitArea = hitArea
        super.init(rootView: rootView)
    }
    required init(rootView: Content) { fatalError("use init(rootView:hitArea:)") }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in superview coordinates. For the window's contentView
        // that's the window content rect (origin bottom-left).
        if hitArea.rect.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }
}

final class IslandWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // Start click-through; AppDelegate's global mouse monitor flips this
        // to `false` only while the cursor is actually inside the pill rect.
        self.ignoresMouseEvents = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: IslandWindow?
    var chooserWindow: NSPanel?
    let monitor = UsageMonitor()
    let config = IslandConfig(geometry: IslandGeometry(notchWidth: 0, notchHeight: 24, screenWidth: 1440))
    let hitArea = HitArea()
    private var mouseMonitor: Any?
    private var lastCursorInside = false

    private let externalScreenPrefKey = "CCIsland.preferredExternalScreen"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor.start()

        // Window is sized to the largest state (expanded) and never resized
        // for state transitions — SwiftUI animates the pill inside. This
        // keeps the cursor inside the window during expand/collapse so hover
        // detection is stable.
        let win = IslandWindow(contentRect: NSRect(origin: .zero, size: config.geometry.expandedSize))
        let view = IslandView(monitor: monitor, config: config, hitArea: hitArea)
        let host = IslandHostingView(rootView: view, hitArea: hitArea)
        host.autoresizingMask = [.width, .height]
        win.contentView = host
        self.window = win

        rebindToCurrentScreen(initial: true)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebindToCurrentScreen(initial: false)
        }

        // Global cursor monitor: only let the window receive events when the
        // cursor is actually inside the visible pill. Everywhere else the
        // window is click-through so apps below get menu/tab clicks.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            self?.updateClickThrough()
        }
        // Also re-evaluate when our SwiftUI view republishes the hit rect
        // (e.g. CC starts working and the dropdown appears under the cursor).
        hitArea.$rect.sink { [weak self] _ in self?.updateClickThrough() }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    private func updateClickThrough() {
        guard let win = window else { return }
        let cursor = NSEvent.mouseLocation                // global screen coords
        let frame = win.frame                             // global screen coords
        let local = NSPoint(x: cursor.x - frame.origin.x,
                            y: cursor.y - frame.origin.y) // window content coords
        let inside = hitArea.rect.contains(local) && !hitArea.rect.isEmpty
        if inside != lastCursorInside {
            lastCursorInside = inside
            win.ignoresMouseEvents = !inside
        }
    }

    /// Picks the target screen per the user's rule:
    ///   1. Built-in display present → always use it (lid is open).
    ///   2. Built-in absent, saved external preference is still present → use it.
    ///   3. Built-in absent, no saved preference (or saved is gone) → prompt.
    private func rebindToCurrentScreen(initial: Bool) {
        let screens = NSScreen.screens
        if let builtIn = screens.first(where: { $0.isBuiltIn }) {
            dismissChooser()
            anchor(to: builtIn)
            return
        }
        // Lid closed (or no built-in at all).
        let savedID = UserDefaults.standard.string(forKey: externalScreenPrefKey)
        if let savedID, let match = screens.first(where: { $0.persistentID == savedID }) {
            dismissChooser()
            anchor(to: match)
            return
        }
        // Need user input.
        if screens.count == 1 {
            // Only one screen available; just use it and remember.
            UserDefaults.standard.set(screens[0].persistentID, forKey: externalScreenPrefKey)
            anchor(to: screens[0])
            return
        }
        presentChooser(screens: screens)
    }

    private func anchor(to screen: NSScreen) {
        let geo = geometry(for: screen)
        config.geometry = geo
        // Window size is fixed to the expanded geometry; only its top-center
        // anchor moves when switching screens.
        positionTopCenter(on: screen, size: geo.expandedSize, animated: false)
        window?.orderFrontRegardless()
    }

    private func geometry(for screen: NSScreen) -> IslandGeometry {
        let safeTop = screen.safeAreaInsets.top
        let menuBarH = NSStatusBar.system.thickness
        let notchH = safeTop > 0 ? safeTop : menuBarH
        var notchW: CGFloat = 0
        if let auxL = screen.auxiliaryTopLeftArea, let auxR = screen.auxiliaryTopRightArea {
            notchW = max(0, screen.frame.width - auxL.width - auxR.width)
        }
        return IslandGeometry(notchWidth: notchW,
                              notchHeight: notchH,
                              screenWidth: screen.frame.width)
    }

    private func currentTargetScreen() -> NSScreen? {
        if let builtIn = NSScreen.screens.first(where: { $0.isBuiltIn }) { return builtIn }
        let savedID = UserDefaults.standard.string(forKey: externalScreenPrefKey)
        if let savedID, let s = NSScreen.screens.first(where: { $0.persistentID == savedID }) {
            return s
        }
        return NSScreen.screens.first
    }

    private func positionTopCenter(on screen: NSScreen, size: NSSize, animated: Bool) {
        guard let window = window else { return }
        let f = screen.frame
        let x = f.midX - size.width / 2
        let y = f.maxY - size.height
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
    }

    // MARK: - Screen chooser (shown when lid is closed and no saved choice)

    private func presentChooser(screens: [NSScreen]) {
        dismissChooser()
        let size = NSSize(width: 320, height: 100 + CGFloat(screens.count) * 38)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Pick a display for CC Island"
        panel.level = .floating
        panel.isFloatingPanel = true
        let chooser = ScreenChooserView(screens: screens) { [weak self] picked in
            guard let self else { return }
            UserDefaults.standard.set(picked.persistentID, forKey: self.externalScreenPrefKey)
            self.dismissChooser()
            self.anchor(to: picked)
        }
        panel.contentView = NSHostingView(rootView: chooser)
        // Center on the largest screen we know about.
        if let largest = screens.max(by: { $0.frame.size.area < $1.frame.size.area }) {
            let f = largest.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                         y: f.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.chooserWindow = panel
    }

    private func dismissChooser() {
        chooserWindow?.orderOut(nil)
        chooserWindow = nil
    }
}

private extension CGSize {
    var area: CGFloat { width * height }
}

struct ScreenChooserView: View {
    let screens: [NSScreen]
    let onPick: (NSScreen) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your MacBook's display isn't available.")
                .font(.system(size: 13, weight: .semibold))
            Text("Pick a display to host CC Island. It'll move back to the MacBook automatically when you open the lid.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(screens, id: \.persistentID) { s in
                Button {
                    onPick(s)
                } label: {
                    HStack {
                        Image(systemName: "display")
                        Text(s.localizedName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(Int(s.frame.width))×\(Int(s.frame.height))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
