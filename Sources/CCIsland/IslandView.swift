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

    private var geometry: IslandGeometry { config.geometry }
    private var theme: Theme { Theme(resolved: appearance.resolved) }
    private var isFreeMove: Bool { placement.mode == .freeMove }

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
        expanded || monitor.snapshot.hasActivity || hasRecentBlock
    }

    private var hasRecentBlock: Bool {
        if let u = monitor.snapshot.planUsage?.fiveHour?.utilization, u > 0 { return true }
        return monitor.snapshot.blockStart != nil && monitor.snapshot.tokensBlock > 0
    }

    private var size: CGSize {
        let docked = geometry.hasPhysicalNotch && !isFreeMove
        if expanded { return geometry.expandedSize(dockedUnderNotch: docked) }
        if monitor.snapshot.hasActivity || hasRecentBlock { return geometry.activeSize }
        return geometry.idleSize
    }
    private var cornerRadius: CGFloat {
        if expanded { return geometry.expandedCornerRadius }
        return (monitor.snapshot.hasActivity || hasRecentBlock)
            ? geometry.activeCornerRadius
            : geometry.idleCornerRadius
    }

    var body: some View {
        let t = effectiveTheme
        return VStack(spacing: 0) {
            ZStack {
                // Backdrop. Glass uses NSVisualEffectView with its OWN layer
                // corner radius — SwiftUI's clipShape would force a render
                // pass that breaks `.behindWindow` blur, producing an opaque
                // gray rectangle instead of true vibrancy.
                Group {
                    if t.isGlass {
                        VisualEffectBackground(material: .hudWindow,
                                               cornerRadius: cornerRadius,
                                               roundTopCorners: isFreeMove)
                        shape.fill(t.panelTint)
                    } else {
                        shape.fill(t.panelFill)
                    }
                }
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
                .shadow(color: t.shadow, radius: 18, y: 8)

                if expanded {
                    Group {
                        if showSettings {
                            SettingsView(closeAction: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    showSettings = false
                                }
                            })
                        } else {
                            expandedContent
                        }
                    }
                    .padding(.horizontal, 20)
                    // Notched + notch placement: leave room for the notch
                    // band above. Otherwise (external display, or free-move
                    // anywhere): only breathing room from the rounded top.
                    .padding(.top, (geometry.hasPhysicalNotch && !isFreeMove)
                                   ? geometry.notchHeight + 14
                                   : 18)
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
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: visible)
            .onHover { hovering in
                // Hold expanded open while the settings panel is in use, even
                // if the cursor briefly slips outside the card.
                if !hovering && showSettings { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
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

    /// Top corner radius for the NSVisualEffectView's CALayer in glass mode.
    /// Mirrors the SwiftUI `shape` decision so the blurred backdrop matches
    /// the silhouette in both placements.
    private var topCornerRadiusForLayer: CGFloat { isFreeMove ? cornerRadius : 0 }

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

    private var notchCollapsedContent: some View {
        VStack(spacing: 0) {
            // Notch row — flush with the camera housing.
            Color.clear.frame(height: geometry.notchHeight)

            if monitor.snapshot.hasActivity || hasRecentBlock {
                HStack(spacing: 0) {
                    ModelDot(model: monitor.snapshot.currentModel,
                             traits: monitor.snapshot.currentModelTraits)
                    Spacer(minLength: 6)
                    dropdownCenter
                    Spacer(minLength: 6)
                    WorkDot(state: monitor.snapshot.workState)
                }
                .padding(.horizontal, 10)
                .frame(height: geometry.dropdownHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var externalCollapsedContent: some View {
        // Single horizontal row that fills the pill. The lights always show
        // (even when idle) — they're the entire reason the pill is visible.
        HStack(spacing: 0) {
            ModelDot(model: monitor.snapshot.currentModel,
                     traits: monitor.snapshot.currentModelTraits)
            Spacer(minLength: 6)
            if monitor.snapshot.hasActivity || hasRecentBlock {
                dropdownCenter
                Spacer(minLength: 6)
            }
            WorkDot(state: monitor.snapshot.workState)
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

    private func traitChip(_ text: String, help: String) -> some View {
        let tint = ModelDot.colorForModel(monitor.snapshot.currentModel)
        return Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.22)))
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
        if monitor.snapshot.isAwaitingDecision {
            Text("FINISH")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundColor(.green)
        } else if monitor.snapshot.isWorking {
            HStack(spacing: 6) {
                Text(workingWord)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(workingWordColor)
                separator
                Text(workingTimeString())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(t.secondaryText(0.7))
                    .monospacedDigit()
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                if let five = monitor.snapshot.planUsage?.fiveHour {
                    Text(percentString(five.utilization))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(t.primaryText)
                        .monospacedDigit()
                } else {
                    Text(formatTokens(monitor.snapshot.tokensBlock))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(t.primaryText)
                        .monospacedDigit()
                }
                separator
                HStack(spacing: 3) {
                    Text("resets")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(t.secondaryText(0.5))
                    Text(sessionResetClockString())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(t.secondaryText(0.75))
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
            .fill(effectiveTheme.secondaryText(0.25))
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
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModelDot(model: monitor.snapshot.currentModel,
                         traits: monitor.snapshot.currentModelTraits)
                Text(modelDisplayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(t.primaryText)
                ForEach(modelTraitTags, id: \.label) { tag in
                    traitChip(tag.label, help: tag.help)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 6) {
                        WorkDot(state: monitor.snapshot.workState)
                        Text(headerLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(t.secondaryText(0.85))
                        // Concurrent-session badge — only when there's more
                        // than one; for the typical single-session case the
                        // badge would just add noise.
                        if monitor.snapshot.activeSessions > 1 {
                            Text("×\(monitor.snapshot.activeSessions)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(t.secondaryText(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(t.chrome(0.10)))
                                .help("\(monitor.snapshot.activeSessions) active sessions")
                        }
                    }
                    if let last = monitor.snapshot.lastActivity {
                        Text(relativeTime(last))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(t.secondaryText(0.5))
                    }
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(t.secondaryText(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(t.chrome(0.08)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(monitor.snapshot.planUsage?.fiveHour != nil ? "Session" : "5-hour block")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(t.secondaryText(0.5))
                    Spacer()
                    Text("resets \(sessionResetClockString())")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(t.secondaryText(0.5))
                }
                if let five = monitor.snapshot.planUsage?.fiveHour {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(percentString(five.utilization))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(t.primaryText)
                            .monospacedDigit()
                        Text("used")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.secondaryText(0.5))
                        Spacer()
                        Text("\(formatTokens(monitor.snapshot.tokensBlock)) · \(String(format: "$%.2f", monitor.snapshot.costBlock))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.secondaryText(0.55))
                            .monospacedDigit()
                    }
                    ProgressTrack(progress: max(0, min(1, five.utilization)))
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(formatTokens(monitor.snapshot.tokensBlock))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(t.primaryText)
                        Text("tokens")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(t.secondaryText(0.5))
                        Spacer()
                        Text(String(format: "$%.2f", monitor.snapshot.costBlock))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(t.secondaryText(0.85))
                            .monospacedDigit()
                    }
                    ProgressTrack(progress: blockProgress())
                }
                if monitor.snapshot.planUsage?.fiveHour == nil,
                   let err = monitor.snapshot.planUsageError {
                    Text("plan: \(PlanUsageFetcher.hint(for: err))")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(t.secondaryText(0.4))
                }
                if let seven = monitor.snapshot.planUsage?.sevenDay {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Weekly")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundColor(t.secondaryText(0.45))
                        Text(percentString(seven.utilization))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(t.secondaryText(0.85))
                            .monospacedDigit()
                        ProgressTrack(progress: max(0, min(1, seven.utilization)))
                            .frame(maxWidth: 120)
                        Spacer()
                        if let reset = seven.resetsAt {
                            Text("resets \(Self.weekdayFormatter.string(from: reset))")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(t.secondaryText(0.4))
                        }
                    }
                }
            }

            // Two equal panels at the bottom — no third metric squeezed in.
            // Sessions count moved to the header (small badge); the split
            // bar below shows model usage when there's something to compare.
            HStack(spacing: 14) {
                miniStat(icon: "sun.max.fill",
                         label: "Today",
                         value: formatTokens(monitor.snapshot.tokensToday),
                         sub: String(format: "$%.2f", monitor.snapshot.costToday))
                Divider().frame(height: 28).background(t.chrome(0.08))
                miniStat(icon: "speedometer",
                         label: "Burn",
                         value: burnTokensValue,
                         sub: burnCostValue)
                    .help("Average burn rate across the current 5h block")
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

    /// Tokens-per-minute portion of the burn miniStat. "—" while no block.
    private var burnTokensValue: String {
        guard let tpm = monitor.snapshot.burnRateTokensPerMin, tpm > 0 else { return "—" }
        return "\(formatTokens(Int(tpm)))/min"
    }
    /// $-per-hour portion of the burn miniStat.
    private var burnCostValue: String {
        guard let cph = monitor.snapshot.burnRateCostPerHour, cph > 0 else { return "—" }
        return String(format: "$%.0f/h", cph)
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
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(t.secondaryText(0.65))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(t.chrome(0.08))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundColor(t.secondaryText(0.45))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(t.primaryText)
                        .monospacedDigit()
                    Text(sub)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(t.secondaryText(0.5))
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(theme.secondaryText(0.45))
                Spacer()
                // Inline legend: dot + name + percent + cost per segment.
                ForEach(segments) { seg in
                    HStack(spacing: 4) {
                        Circle().fill(seg.color).frame(width: 6, height: 6)
                        Text("\(seg.label) \(Int((seg.fraction * 100).rounded()))%")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.secondaryText(0.85))
                            .monospacedDigit()
                        if seg.cost > 0 {
                            Text(String(format: "$%.2f", seg.cost))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(theme.secondaryText(0.5))
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

struct ProgressTrack: View {
    let progress: Double
    @Environment(\.ccTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.progressTrack)
                Capsule()
                    .fill(
                        LinearGradient(colors: [theme.accentStart, theme.accentEnd],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 4)
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
        if m.contains("opus") { return Color(red: 0.78, green: 0.55, blue: 1.0) }
        if m.contains("haiku") { return Color.white }
        if m.contains("sonnet") { return Color(red: 0.45, green: 0.85, blue: 1.0) }
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
