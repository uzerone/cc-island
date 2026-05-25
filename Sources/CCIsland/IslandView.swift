import SwiftUI
import AppKit

/// Holds the current target geometry. The AppDelegate updates this when the
/// active screen changes (e.g. lid open/close); the view observes it and
/// re-lays out automatically.
final class IslandConfig: ObservableObject {
    @Published var geometry: IslandGeometry

    init(geometry: IslandGeometry) {
        self.geometry = geometry
    }
}

/// Shared between the SwiftUI view and the `NSHostingView` subclass: tells
/// the host where the currently-visible pill is (in window coordinates) so
/// clicks outside that rect can pass through to whatever is beneath.
final class HitArea: ObservableObject {
    @Published var rect: CGRect = .zero
}

/// Geometry derived from `NSScreen` per Apple HIG. `notchHeight` is the
/// `safeAreaInsets.top` on a notched Mac, otherwise the menu-bar thickness.
/// `notchWidth` is the gap between `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea`, or 0 on non-notched displays.
struct IslandGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var screenWidth: CGFloat
    /// `nil` when the host screen has a real notch. Non-nil for external
    /// displays, where we just lay out as a top-center pill.
    var hasPhysicalNotch: Bool { notchWidth > 0 }

    /// Collapsed island width is locked to the notch width so the top row
    /// visually IS the notch.
    var collapsedWidth: CGFloat { max(notchWidth, 180) }

    /// Idle collapsed: just a pill the shape of the notch — visually
    /// indistinguishable from the camera housing.
    var idleSize: CGSize {
        CGSize(width: collapsedWidth, height: max(notchHeight, 24))
    }

    /// Active collapsed: notch row + an info row dropping down below it.
    var activeSize: CGSize {
        CGSize(width: collapsedWidth, height: max(notchHeight, 24) + dropdownHeight)
    }

    var dropdownHeight: CGFloat { 30 }

    var activeCornerRadius: CGFloat { 20 }
    var idleCornerRadius: CGFloat { idleSize.height / 2 }

    /// Expanded card: a modern rounded rectangle that grows downward from
    /// the notch line. Width is independent of the notch. When docked
    /// under the notch, we add `notchHeight` so the band hidden behind
    /// the camera housing doesn't eat into the visible card area.
    ///
    /// Height is sized to fit the Settings panel (header + Placement +
    /// Appearance + toggle + Quit row); the stats view is shorter and
    /// just runs with extra breathing room.
    func expandedSize(dockedUnderNotch: Bool) -> CGSize {
        let topBand = dockedUnderNotch ? notchHeight : 0
        return CGSize(width: 420, height: topBand + 290)
    }

    /// Convenience for the docked default — used by AppDelegate when
    /// sizing the window in notch mode.
    var expandedSize: CGSize { expandedSize(dockedUnderNotch: hasPhysicalNotch) }

    /// Corner radius for the expanded card — fixed, modern rounded-rect feel
    /// rather than a giant pill.
    var expandedCornerRadius: CGFloat { 28 }
}

struct IslandView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var config: IslandConfig
    @ObservedObject var hitArea: HitArea
    @ObservedObject var appearance: AppearanceStore = .shared
    @ObservedObject var placement: PlacementStore = .shared

    @State private var expanded = false
    @State private var showSettings = false
    @State private var finishVisibleUntil: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long FINISH stays visible in notch mode before auto-dismissing
    /// back to the resets-countdown view. On external display / free-move
    /// the banner persists as long as the real state holds.
    private static let finishAutoDismissSeconds: TimeInterval = 4

    private var geometry: IslandGeometry { config.geometry }
    private var theme: Theme { Theme(resolved: appearance.resolved) }
    private var isFreeMove: Bool { placement.mode == .freeMove }

    /// Apple HIG-aligned animation curves. One spring for UI interaction
    /// (hover/expand/settings), one slightly slower for the drop-in/out from
    /// the notch. Reduce Motion downgrades both to a brief fade.
    private var uiSpring: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.4, dampingFraction: 0.86)
    }
    private var dropSpring: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.22)
            : .spring(response: 0.55, dampingFraction: 0.82)
    }

    /// On a real notched MacBook display in notch placement, the collapsed
    /// pill must remain black so it visually merges with the camera
    /// housing. In free-move mode the pill isn't docked to the notch, so
    /// the user's theme always applies.
    private var effectiveTheme: Theme {
        if !isFreeMove && geometry.hasPhysicalNotch && !expanded {
            return Theme(resolved: .dark)
        }
        return theme
    }

    /// True when the island is rendered at all. We stay visible while there
    /// is *any* recent 5-hour block — even if Claude isn't actively writing —
    /// so the dropdown can show live block tokens + reset countdown. Only
    /// truly empty state (no recent CC use at all) hides the island.
    private var visible: Bool {
        expanded || hasDropdownState
    }

    private var hasRecentBlock: Bool {
        if let u = monitor.snapshot.planUsage?.fiveHour?.utilization, u > 0 { return true }
        return monitor.snapshot.blockStart != nil && monitor.snapshot.tokensBlock > 0
    }

    /// The dropdown row is meaningful in three cases: actively WORKING
    /// (pulsing dots), waiting on a decision (FINISH checkmark), or
    /// between turns with a live 5h block (tokens + resets clock). Outside
    /// these, the pill stays as the bare idle silhouette.
    private var hasDropdownState: Bool {
        monitor.snapshot.isWorking
            || displayedIsAwaitingDecision
            || hasRecentBlock
    }

    /// Real `isAwaitingDecision` filtered through the notch-mode
    /// auto-dismiss timer. In notch placement the FINISH banner shows for
    /// `finishAutoDismissSeconds`, then collapses to the resets view so
    /// it doesn't squat under the camera housing for the rest of the
    /// session. Elsewhere (external / free-move) the banner persists.
    private var displayedIsAwaitingDecision: Bool {
        guard monitor.snapshot.isAwaitingDecision else { return false }
        let inNotchMode = geometry.hasPhysicalNotch && !isFreeMove
        guard inNotchMode else { return true }
        if let until = finishVisibleUntil, Date() < until { return true }
        return false
    }

    private var size: CGSize {
        let docked = geometry.hasPhysicalNotch && !isFreeMove
        if expanded { return geometry.expandedSize(dockedUnderNotch: docked) }
        if hasDropdownState { return geometry.activeSize }
        return geometry.idleSize
    }
    private var cornerRadius: CGFloat {
        if expanded { return geometry.expandedCornerRadius }
        return (hasDropdownState)
            ? geometry.activeCornerRadius
            : geometry.idleCornerRadius
    }

    var body: some View {
        let t = effectiveTheme
        return VStack(spacing: 0) {
            ZStack {
                shape
                    .fill(t.panelFill)
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(colors: [
                                t.borderTopHighlight,
                                t.borderBottomShade
                            ], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5
                        )
                )
                // Layered shadows simulate `backgroundExtensionEffect` —
                // a tight contact shadow plus a wider ambient halo so the
                // card reads as floating above the desktop, with its
                // presence extending past the visible silhouette.
                .shadow(color: t.shadow.opacity(0.7), radius: 6, y: 2)
                .shadow(color: t.shadow.opacity(0.45), radius: 24, y: 14)

                if expanded {
                    Group {
                        if showSettings {
                            SettingsView(closeAction: {
                                withAnimation(uiSpring) {
                                    showSettings = false
                                }
                            })
                        } else {
                            expandedContent
                        }
                    }
                    .padding(.horizontal, 20)
                    // Symmetric vertical insets: same visible margin top
                    // and bottom. In notch placement, the top inset adds
                    // `notchHeight` so the visible 16pt margin starts
                    // below the camera housing, matching the 16pt below.
                    .padding(.top, (geometry.hasPhysicalNotch && !isFreeMove)
                                   ? geometry.notchHeight + 16
                                   : 16)
                    .padding(.bottom, 16)
                    // Top-align so an overflowing SettingsView never gets
                    // vertically centered — that was clipping the header
                    // ("Settings" + back button) above the visible card.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            // `mask` instead of `clipShape`: keeps the rounded silhouette
            // without forcing the offscreen render pass that breaks the
            // NSVisualEffectView blur in glass mode.
            .mask(shape)
            .contentShape(shape)
            // "Drops down" from the notch: vertical scale 0 → 1 anchored at
            // the top edge makes the pill extrude downward. Opacity fades in
            // slightly later so the motion reads as growth, not a pop.
            .scaleEffect(x: 1, y: visible ? 1 : 0.02, anchor: .top)
            .opacity(visible ? 1 : 0)
            .animation(dropSpring, value: visible)
            .onHover { hovering in
                // Hold expanded open while the settings panel is in use, even
                // if the cursor briefly slips outside the card.
                if !hovering && showSettings { return }
                withAnimation(uiSpring) {
                    expanded = hovering
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.ccTheme, t)
        .onAppear { updateHitArea() }
        .onChange(of: visible) { _ in updateHitArea() }
        .onChange(of: expanded) { _ in updateHitArea() }
        .onChange(of: monitor.snapshot.hasActivity) { _ in updateHitArea() }
        .onChange(of: size.width) { _ in updateHitArea() }
        .onChange(of: size.height) { _ in updateHitArea() }
        .onChange(of: geometry.expandedSize.width) { _ in updateHitArea() }
        .onChange(of: geometry.expandedSize.height) { _ in updateHitArea() }
        // Arm the FINISH auto-dismiss timer the moment `isAwaitingDecision`
        // flips true. Schedule a delayed re-render so the dropdown
        // collapses cleanly when the window passes — without needing
        // UsageMonitor to tick at exactly the right moment.
        .onChange(of: monitor.snapshot.isAwaitingDecision) { isAwait in
            if isAwait {
                let until = Date().addingTimeInterval(Self.finishAutoDismissSeconds)
                finishVisibleUntil = until
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishAutoDismissSeconds + 0.05) {
                    if finishVisibleUntil == until { finishVisibleUntil = nil }
                }
            } else {
                finishVisibleUntil = nil
            }
        }
        // Smart animation — every state change in the snapshot interpolates
        // through the same spring as hover/expand. Chips appearing, lights
        // hiding when work starts, model swaps mid-session, dropdown text
        // switching between WORKING / FINISH / resets — all coherent.
        .animation(uiSpring, value: monitor.snapshot.workState)
        .animation(uiSpring, value: monitor.snapshot.currentModel)
        .animation(uiSpring, value: monitor.snapshot.currentModelTraits.thinking)
        .animation(uiSpring, value: monitor.snapshot.currentModelTraits.oneMillionContext)
        .animation(uiSpring, value: monitor.snapshot.currentModelTraits.fastMode)
        .animation(uiSpring, value: monitor.snapshot.activeSessions)
        .animation(uiSpring, value: hideLightsForActiveState)
    }

    /// Publishes the visible pill rect in NSHostingView coordinates so the
    /// host can mask off clicks outside it. When the island is hidden
    /// (idle + not expanded), the rect is empty so every click falls through.
    private func updateHitArea() {
        guard visible else { hitArea.rect = .zero; return }
        let pill = size
        let outer = geometry.expandedSize
        hitArea.rect = CGRect(
            x: (outer.width - pill.width) / 2,
            y: outer.height - pill.height,
            width: pill.width,
            height: pill.height
        )
    }

    /// The pill silhouette.
    ///
    /// • Notch placement: flat top edge so it hangs from the menu bar /
    ///   notch like a true dropdown tab — only bottom corners are rounded.
    /// • Free-move placement: fully rounded since the pill isn't docked
    ///   to any edge.
    private var shape: UnevenRoundedRectangle {
        let top: CGFloat = isFreeMove ? cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: top,
            style: .continuous
        )
    }

/// Collapsed pill. Layout depends on whether the pill is currently
    /// docked under a physical notch.
    ///
    /// • Notched + notch placement: top row is empty (merges with the
    ///   camera housing); lights/info live in a dropdown row below it.
    ///
    /// • External display OR free-move placement: no camera to dodge, so
    ///   the top row IS the pill — lights sit directly on it, flanking
    ///   the info text.
    private var collapsedContent: some View {
        let dockedUnderNotch = geometry.hasPhysicalNotch && !isFreeMove
        if dockedUnderNotch {
            return AnyView(notchCollapsedContent)
        } else {
            return AnyView(externalCollapsedContent)
        }
    }

    /// When the user is actively in WORKING or FINISH state, the dropdown
    /// IS the status indicator (pulsing dots / green checkmark) — side
    /// lights become redundant noise. Hide them so the active state reads
    /// like a clean iOS Dynamic Island moment.
    /// True when the dropdown is in idle-with-block "reset clock only"
    /// mode — model + tokens fall away, leaving a minimal clock chip.
    /// Hover for full details (the expanded card has model + tokens).
    private var isResetOnlyDropdown: Bool {
        hasRecentBlock
            && !monitor.snapshot.isWorking
            && !displayedIsAwaitingDecision
    }

    private var hideLightsForActiveState: Bool {
        monitor.snapshot.isWorking
            || displayedIsAwaitingDecision
            || isResetOnlyDropdown
    }

    /// The idle-state WorkDot is just a static gray dot — it conveys
    /// nothing the absence of animation doesn't already. Skip it.
    private var showWorkDot: Bool {
        !hideLightsForActiveState && monitor.snapshot.workState != .idle
    }

    private var notchCollapsedContent: some View {
        VStack(spacing: 0) {
            // Notch row — flush with the camera housing.
            Color.clear.frame(height: geometry.notchHeight)

            if hasDropdownState {
                HStack(spacing: 0) {
                    if !hideLightsForActiveState {
                        ModelDot(model: monitor.snapshot.currentModel,
                                 traits: monitor.snapshot.currentModelTraits)
                        Spacer(minLength: 6)
                    } else {
                        Spacer(minLength: 0)
                    }
                    dropdownCenter
                    if showWorkDot {
                        Spacer(minLength: 6)
                        WorkDot(state: monitor.snapshot.workState)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: geometry.dropdownHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var externalCollapsedContent: some View {
        // Single horizontal row that fills the pill. Lights only show in
        // idle / between-turns state; during WORKING and FINISH the
        // dropdown content carries the status indicator itself.
        HStack(spacing: 0) {
            if !hideLightsForActiveState {
                ModelDot(model: monitor.snapshot.currentModel,
                         traits: monitor.snapshot.currentModelTraits)
                Spacer(minLength: 6)
            } else {
                Spacer(minLength: 0)
            }
            if hasDropdownState {
                dropdownCenter
                if showWorkDot {
                    Spacer(minLength: 6)
                }
            }
            if showWorkDot {
                WorkDot(state: monitor.snapshot.workState)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    /// Pretty display name: "Opus 4.7", "Sonnet 4.6", "Haiku 4.5", etc.
    private var modelDisplayName: String {
        guard let m = monitor.snapshot.currentModel else { return "—" }
        let parts = m.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        // e.g. ["opus", "4", "7"] → "Opus 4.7"
        guard let family = parts.first.map(String.init) else { return m }
        let nameCap = family.prefix(1).uppercased() + family.dropFirst()
        if parts.count >= 3 { return "\(nameCap) \(parts[1]).\(parts[2])" }
        if parts.count == 2 { return "\(nameCap) \(parts[1])" }
        return nameCap
    }

    /// Variant tags to chip alongside the model name, each with a tooltip
    /// explaining what it means — most users won't recognize "1M" or "FAST"
    /// without one.
    private var modelTraitTags: [(label: String, help: String)] {
        var tags: [(String, String)] = []
        let t = monitor.snapshot.currentModelTraits
        if t.oneMillionContext {
            tags.append(("1M", "1M-context variant — bigger context window, higher per-token cost"))
        }
        if t.thinking {
            tags.append(("THINKING", "Extended thinking is on — slower, deeper reasoning"))
        }
        if t.fastMode {
            tags.append(("FAST", "/fast mode is toggled — Opus 4.6 at faster output speed"))
        }
        return tags
    }

    /// Activity-badge style trait chip, inspired by Apple's Landmarks
    /// sample. Background is a subtle gradient (tint top → tint-faded
    /// bottom) with a hairline stroke for material depth — the same
    /// look the new SwiftUI `.glassEffect()` produces on macOS 26+.
    private func traitChip(_ text: String, help: String) -> some View {
        let tint = ModelDot.colorForModel(monitor.snapshot.currentModel)
        return Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.16)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
            )
            .foregroundColor(tint)
            .help(help)
    }

    /// Short one-word status — avoids line-wraps in the header. The active
    /// session count is shown separately as a small badge when > 1.
    private var headerLabel: String {
        switch monitor.snapshot.workState {
        case .working:          return "Working"
        case .awaitingDecision: return "Waiting"
        case .idle:             return "Idle"
        }
    }

    /// Center text inside the dropdown. State-driven:
    /// - working + thinking → "THINKING · 1h 23m"
    /// - working            → "WORKING · 1h 23m"
    /// - awaitingDecision   → "FINISH"
    /// - idle (block live)  → "14.3k · resets 8:23 AM"
    @ViewBuilder
    private var dropdownCenter: some View {
        // The collapsed pill on a notched display always uses the dark
        // theme (notch illusion), so use effectiveTheme — not the global one.
        let t = effectiveTheme
        if displayedIsAwaitingDecision {
            HStack(spacing: 5) {
                PulsingCheckmark()
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6).combined(with: .opacity),
                        removal: .opacity
                    ))
                Text("FINISH")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundColor(.green)
            }
            .lineLimit(1)
        } else if monitor.snapshot.isWorking {
            HStack(spacing: 6) {
                PulsingDots(color: workingWordColor)
                Text(workingWord)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(workingWordColor)
                separator
                Text(workingTimeString())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(t.text(.secondary))
                    .monospacedDigit()
            }
            .lineLimit(1)
        } else {
            // Idle-with-block — utilization % and reset clock, side by
            // side. Lights hide so the dropdown reads as a clean status
            // chip; model + tokens live in the expanded card.
            HStack(spacing: 6) {
                if let five = monitor.snapshot.planUsage?.fiveHour {
                    Text(percentString(five.utilization))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.primary))
                        .monospacedDigit()
                } else {
                    Text(formatTokens(monitor.snapshot.tokensBlock))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.primary))
                        .monospacedDigit()
                }
                separator
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(t.text(.tertiary))
                    Text(sessionResetClockString())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.secondary))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
        }
    }

    /// Whether Claude is currently in an extended-thinking phase. We treat
    /// the last assistant turn having a `thinking` block as a signal that
    /// the in-flight turn is also a reasoning one.
    private var workingWord: String {
        monitor.snapshot.currentModelTraits.thinking ? "THINKING" : "WORKING"
    }

    private var workingWordColor: Color {
        monitor.snapshot.currentModelTraits.thinking
            ? Color(red: 0.78, green: 0.55, blue: 1.0)   // purple, matches thinking vibe
            : effectiveTheme.primaryText
    }

    private var separator: some View {
        Circle()
            .fill(effectiveTheme.text(.quaternary))
            .frame(width: 2, height: 2)
    }

    /// Color encoding for the right-side dot based on 5h block progress.
    /// gray (no block) → cyan (early) → indigo (mid) → orange (almost spent).
    private func blockDotColor() -> Color {
        guard monitor.snapshot.blockStart != nil else { return .gray.opacity(0.5) }
        let p = blockProgress()
        if p < 0.5 { return Color(red: 0.55, green: 0.85, blue: 1.0) }       // cyan
        if p < 0.8 { return Color(red: 0.55, green: 0.55, blue: 1.0) }       // indigo
        return Color(red: 1.0, green: 0.6, blue: 0.25)                       // orange
    }

    private var expandedContent: some View {
        let t = theme
        // Outer rhythm follows an 8pt grid: 16 between sections, 8 within.
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ModelDot(model: monitor.snapshot.currentModel,
                         traits: monitor.snapshot.currentModelTraits)
                Text(modelDisplayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(t.text(.primary))
                ForEach(modelTraitTags, id: \.label) { tag in
                    traitChip(tag.label, help: tag.help)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // Status only shown when there's something active to
                    // communicate. Idle = no row — the model name +
                    // metrics already tell you everything.
                    if monitor.snapshot.workState != .idle {
                        HStack(spacing: 6) {
                            WorkDot(state: monitor.snapshot.workState)
                            Text(headerLabel)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(t.text(.secondary))
                            if monitor.snapshot.activeSessions > 1 {
                                Text("×\(monitor.snapshot.activeSessions)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(t.text(.secondary))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(t.chrome(0.10)))
                                    .help("\(monitor.snapshot.activeSessions) active sessions")
                            }
                        }
                        if let last = monitor.snapshot.lastActivity {
                            Text(relativeTime(last))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(t.text(.tertiary))
                        }
                    }
                }
                Button {
                    withAnimation(uiSpring) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(t.text(.tertiary))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(t.chrome(0.08)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(monitor.snapshot.planUsage?.fiveHour != nil ? "Session" : "5-hour block")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(t.text(.tertiary))
                    Spacer()
                    Text("resets \(sessionResetClockString())")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.tertiary))
                }
                if let five = monitor.snapshot.planUsage?.fiveHour {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(percentString(five.utilization))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(t.text(.primary))
                            .monospacedDigit()
                        Text("used")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.text(.tertiary))
                        Spacer()
                        Text("\(formatTokens(monitor.snapshot.tokensBlock)) · \(String(format: "$%.2f", monitor.snapshot.costBlock))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.text(.tertiary))
                            .monospacedDigit()
                    }
                    ProgressTrack(progress: max(0, min(1, five.utilization)))
                } else {
                    // Dual-hero treatment: tokens on the left, dollars on
                    // the right — both at the same display size so neither
                    // visually outranks the other.
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(formatTokens(monitor.snapshot.tokensBlock))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(t.text(.primary))
                            .monospacedDigit()
                        Text("tokens")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.text(.tertiary))
                        Spacer()
                        Text(String(format: "$%.2f", monitor.snapshot.costBlock))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(t.text(.primary))
                            .monospacedDigit()
                    }
                    ProgressTrack(progress: blockProgress())
                }
                if let seven = monitor.snapshot.planUsage?.sevenDay {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Weekly")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundColor(t.text(.tertiary))
                        Text(percentString(seven.utilization))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(t.text(.secondary))
                            .monospacedDigit()
                        ProgressTrack(progress: max(0, min(1, seven.utilization)))
                            .frame(maxWidth: 120)
                        Spacer()
                        if let reset = seven.resetsAt {
                            Text("resets \(Self.weekdayFormatter.string(from: reset))")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(t.text(.quaternary))
                        }
                    }
                }
            }

            // Today summary — single hero line. Editorial layout: the
            // dollar amount is the visual anchor on the left; the token
            // count is the secondary metric, right-aligned. No icons or
            // chrome — the typography hierarchy carries the design.
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(t.text(.tertiary))
                    Text(String(format: "$%.2f", monitor.snapshot.costToday))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(t.text(.primary))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOKENS")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(t.text(.tertiary))
                    Text(formatTokens(monitor.snapshot.tokensToday))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.secondary))
                        .monospacedDigit()
                }
            }

            // Per-model split for the *current 5h session block* — shows
            // which models are eating your plan quota right now. Always
            // visible when there's block usage; single-model case confirms
            // you're 100% on the chosen one.
            if !modelSplitSegments.isEmpty {
                ModelSplitBar(title: "Session by model", segments: modelSplitSegments)
                    .help("Current session's usage split by model")
            }
        }
    }

/// Color-coded segments scoped to the current 5h session block. Token
    /// totals drive the bar widths; cost is carried so the legend can show
    /// "$X" per model. Variants of one family (opus-4-6, opus-4-7, etc.)
    /// collapse into one segment with the shared family color.
    private var modelSplitSegments: [ModelSplitBar.Segment] {
        let totalTokens = monitor.snapshot.tokensByModelBlock.values.reduce(0, +)
        guard totalTokens > 0 else { return [] }
        var tokensByFamily: [String: Int] = [:]
        var costByFamily: [String: Double] = [:]
        for (model, tokens) in monitor.snapshot.tokensByModelBlock {
            tokensByFamily[familyLabel(for: model), default: 0] += tokens
        }
        for (model, cost) in monitor.snapshot.costByModelBlock {
            costByFamily[familyLabel(for: model), default: 0] += cost
        }
        return tokensByFamily
            .sorted { $0.value > $1.value }
            .map { (family, tokens) in
                ModelSplitBar.Segment(
                    label: family,
                    fraction: Double(tokens) / Double(totalTokens),
                    cost: costByFamily[family] ?? 0,
                    color: ModelDot.colorForModel(modelIdForFamily(family))
                )
            }
    }

    private func familyLabel(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        return "Other"
    }

    /// Reverse of `familyLabel` — gives `ModelDot.colorForModel` a string it
    /// recognizes so the segment color matches the model dot.
    private func modelIdForFamily(_ family: String) -> String {
        switch family {
        case "Opus":   return "claude-opus"
        case "Sonnet": return "claude-sonnet"
        case "Haiku":  return "claude-haiku"
        default:       return "claude-other"
        }
    }


    private func miniStat(icon: String, label: String, value: String, sub: String) -> some View {
        let t = theme
        return HStack(spacing: 10) {
            // Activity-badge styled icon — gradient fill + hairline stroke
            // produces a sense of material depth without leaning on
            // macOS-26-only `.glassEffect()`.
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(t.text(.secondary))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [t.chrome(0.14), t.chrome(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    Circle().strokeBorder(t.chrome(0.10), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(t.text(.tertiary))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(t.text(.primary))
                        .monospacedDigit()
                    Text(sub)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(t.text(.tertiary))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fraction of the 5h block elapsed. Used for the progress bar.
    private func blockProgress() -> Double {
        guard let start = monitor.snapshot.blockStart else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, min(1, elapsed / (5 * 3600)))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func blockEndsString() -> String {
        return blockResetClockString()
    }

    /// Actual clock time when the current 5h block resets (e.g. "8:23 AM",
    /// or "20:23" in 24-hour locales). "—" when no block is active.
    private func blockResetClockString() -> String {
        guard let start = monitor.snapshot.blockStart else { return "—" }
        let end = start.addingTimeInterval(5 * 3600)
        return Self.clockFormatter.string(from: end)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "Sun 5:00 PM" — weekday + short time, for weekly resets.
    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E h:mm a"
        return f
    }()

    private func percentString(_ u: Double) -> String {
        let v = max(0, min(100, u * 100))
        // Match Anthropic's display — whole-number percent.
        return "\(Int(v.rounded()))%"
    }

    /// Reset clock string, preferring the authoritative Anthropic-reported
    /// time when we have it, otherwise the locally-derived block end.
    private func sessionResetClockString() -> String {
        if let r = monitor.snapshot.planUsage?.fiveHour?.resetsAt {
            return Self.clockFormatter.string(from: r)
        }
        return blockResetClockString()
    }

    /// Estimated working time = elapsed time since the current 5h block began.
    /// Reflects how long Claude has been actively engaged this session.
    private func workingTimeString() -> String {
        guard let start = monitor.snapshot.blockStart else { return "—" }
        let elapsed = max(0, Date().timeIntervalSince(start))
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm", m)
    }
}

/// Horizontal stacked bar showing per-model usage. Each segment is
/// colored by its `ModelDot` family color; the legend shows name +
/// percentage + dollar cost so users can tell at a glance which model
/// is doing the work AND which is doing the spending (Opus ≈ 5× Sonnet).
struct ModelSplitBar: View {
    struct Segment: Identifiable {
        let label: String
        let fraction: Double
        let cost: Double
        let color: Color
        var id: String { label }
    }
    let title: String
    let segments: [Segment]

    @Environment(\.ccTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(theme.text(.tertiary))
                Spacer()
                // Inline legend: dot + name + percent + cost per segment.
                ForEach(segments) { seg in
                    HStack(spacing: 4) {
                        Circle().fill(seg.color).frame(width: 6, height: 6)
                        Text("\(seg.label) \(Int((seg.fraction * 100).rounded()))%")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.text(.secondary))
                            .monospacedDigit()
                        if seg.cost > 0 {
                            Text(String(format: "$%.2f", seg.cost))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(theme.text(.tertiary))
                                .monospacedDigit()
                        }
                    }
                }
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments) { seg in
                        Capsule()
                            .fill(seg.color)
                            .frame(width: max(2, geo.size.width * seg.fraction))
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

/// HIG-aligned linear progress indicator with gauge-style semantic
/// coloring: the fill shifts from the cool accent gradient to a warm
/// amber as utilization climbs past 80% — same rule the iOS Battery
/// gauge follows. Below 80% reads as "you have headroom", above signals
/// "approaching limit".
struct ProgressTrack: View {
    let progress: Double
    @Environment(\.ccTheme) private var theme

    private var fillColors: [Color] {
        if progress >= 0.95 {
            // Critical — saturated coral. Same vibe as system red without
            // shouting.
            return [Color(red: 1.0, green: 0.45, blue: 0.40),
                    Color(red: 1.0, green: 0.30, blue: 0.30)]
        } else if progress >= 0.8 {
            // Caution — amber gradient. Reads as warm but not alarming.
            return [Color(red: 1.0, green: 0.75, blue: 0.35),
                    Color(red: 1.0, green: 0.55, blue: 0.25)]
        }
        return [theme.accentStart, theme.accentEnd]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track with a faint inner-shadow look via stacked fills —
                // gives the bar depth without an actual `.shadow` (which
                // would bleed outside the capsule on light themes).
                Capsule()
                    .fill(theme.progressTrack)
                Capsule()
                    .fill(
                        LinearGradient(colors: fillColors,
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(4, geo.size.width * progress))
                    .animation(.easeInOut(duration: 0.35), value: progress)
            }
        }
        .frame(height: 5)
    }
}

/// Left light: identifies which Claude model is active. Color = family,
/// secondary cues encode variants:
///   • a soft halo ring → 1M-context variant
///   • a faint inner sparkle pulse → extended-thinking enabled
struct ModelDot: View {
    let model: String?
    let traits: ModelTraits
    @State private var blink = false

    var body: some View {
        ZStack {
            // Halo for 1M-context variant.
            if traits.oneMillionContext {
                Circle()
                    .strokeBorder(color.opacity(0.55), lineWidth: 1)
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
                // When extended-thinking is active, blink sharply so the user
                // can see Claude is in a slow-burn reasoning phase.
                .opacity(traits.thinking ? (blink ? 0.15 : 1.0) : 1.0)
                .animation(traits.thinking
                           ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                           : .default,
                           value: blink)
        }
        .frame(width: 14, height: 14)
        .onAppear { blink = true }
    }

    private var color: Color {
        ModelDot.colorForModel(model)
    }

    static func colorForModel(_ model: String?) -> Color {
        guard let m = model?.lowercased() else { return Color.gray.opacity(0.55) }
        // Opus — electric royal purple. Bright and saturated so it reads
        // crisp at the 8pt dot scale, but still distinctively "Opus" in
        // the purple family.
        if m.contains("opus")   { return Color(red: 0.72, green: 0.42, blue: 1.00) }
        // Sonnet — modern blue. Confident contemporary indigo-blue,
        // balanced between cool and neutral. The kind of blue you see in
        // well-designed productivity apps.
        if m.contains("sonnet") { return Color(red: 0.28, green: 0.58, blue: 1.00) }
        // Haiku — energetic mint-green. Light and alive, mirroring Haiku's
        // speed-and-lightness positioning. Distinct from both the regal
        // purple and the cool blue.
        if m.contains("haiku")  { return Color(red: 0.28, green: 0.88, blue: 0.65) }
        return Color.gray.opacity(0.55)
    }
}

/// Right light: working status. Color = state, animation = liveness.
///   • green slow pulse → actively writing
///   • orange fast blink → waiting on the user
///   • gray steady → idle
struct WorkDot: View {
    let state: WorkState
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .idle: return Color.gray.opacity(0.55)
        // Orange = active work in progress (matches "in the middle of
        // something — do not interrupt"). Green = ready/awaiting your
        // decision (the run-light convention: green means go).
        case .working: return Color(red: 1.0, green: 0.55, blue: 0.15)
        case .awaitingDecision: return Color.green
        }
    }

    private var period: Double? {
        switch state {
        case .idle: return nil
        case .working: return 0.9
        case .awaitingDecision: return 0.45
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 4)
            .scaleEffect(period != nil && pulse ? 1.35 : 1.0)
            .opacity(period != nil && pulse
                     ? (state == .awaitingDecision ? 0.3 : 0.6)
                     : 1.0)
            .animation(period.map { .easeInOut(duration: $0).repeatForever(autoreverses: true) }
                       ?? .default,
                       value: pulse)
            .onAppear { pulse = true }
    }
}

/// FINISH state checkmark with a soft breathing pulse. The work dot
/// (which used to convey "waiting on you" via a fast blink) is hidden
/// in the awaiting state, so this carries that signal — gentler than
/// the dot's old fast strobe but persistent enough to draw the eye.
struct PulsingCheckmark: View {
    @State private var pulse = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.green)
            .shadow(color: Color.green.opacity(0.55), radius: pulse ? 4 : 1.5)
            .scaleEffect(pulse ? 1.12 : 1.0)
            .opacity(pulse ? 0.88 : 1.0)
            .animation(
                .easeInOut(duration: 0.95).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

/// Three small dots that pulse in sequence — the canonical "loading"
/// indicator from iOS Dynamic Island. Each dot fades on a staggered
/// delay so the row reads as a left-to-right wave.
struct PulsingDots: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(animating ? 1.0 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
