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
    /// the notch line. Width is independent of the notch.
    var expandedSize: CGSize {
        CGSize(width: 420, height: notchHeight + 200)
    }

    /// Corner radius for the expanded card — fixed, modern rounded-rect feel
    /// rather than a giant pill.
    var expandedCornerRadius: CGFloat { 28 }
}

struct IslandView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var config: IslandConfig
    @ObservedObject var hitArea: HitArea

    @State private var expanded = false
    @State private var showSettings = false

    private var geometry: IslandGeometry { config.geometry }

    /// True when the island is rendered at all. We stay visible while there
    /// is *any* recent 5-hour block — even if Claude isn't actively writing —
    /// so the dropdown can show live block tokens + reset countdown. Only
    /// truly empty state (no recent CC use at all) hides the island.
    private var visible: Bool {
        expanded || monitor.snapshot.hasActivity || hasRecentBlock
    }

    private var hasRecentBlock: Bool {
        monitor.snapshot.blockStart != nil && monitor.snapshot.tokensBlock > 0
    }

    private var size: CGSize {
        if expanded { return geometry.expandedSize }
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
        VStack(spacing: 0) {
            ZStack {
                shape
                    .fill(Color.black)
                    .overlay(
                        // Subtle top highlight + hairline border for depth.
                        shape
                            .strokeBorder(
                                LinearGradient(colors: [
                                    .white.opacity(0.12),
                                    .white.opacity(0.02)
                                ], startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)

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
                    .padding(.top, geometry.notchHeight + 14)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Collapsed: working-light on the left safe zone, block-reset countdown
    /// on the right safe zone. The notch sits in the negative space between.
    private var collapsedContent: some View {
        VStack(spacing: 0) {
            // Notch row: visually flush with the camera housing — nothing on it.
            Color.clear.frame(height: geometry.notchHeight)

            // Dropdown info row — only when Claude is actively working.
            // Lights flank the info text on both sides.
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

    /// Variant tags to chip alongside the model name.
    private var modelTraitTags: [String] {
        var tags: [String] = []
        let t = monitor.snapshot.currentModelTraits
        if t.oneMillionContext { tags.append("1M") }
        if t.thinking { tags.append("THINKING") }
        if t.fastMode { tags.append("FAST") }
        if t.oneHourCache { tags.append("1H CACHE") }
        return tags
    }

    private func traitChip(_ text: String) -> some View {
        let tint = ModelDot.colorForModel(monitor.snapshot.currentModel)
        return Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.22)))
            .foregroundColor(tint)
    }

    private var headerLabel: String {
        switch monitor.snapshot.workState {
        case .working:
            let n = monitor.snapshot.activeSessions
            return "\(n) active session\(n == 1 ? "" : "s")"
        case .awaitingDecision: return "Waiting on you"
        case .idle: return "Idle"
        }
    }

    /// Center text inside the dropdown. State-driven:
    /// - working + thinking → "THINKING · 1h 23m"
    /// - working            → "WORKING · 1h 23m"
    /// - awaitingDecision   → "FINISH"
    /// - idle (block live)  → "14.3k · resets 8:23 AM"
    @ViewBuilder
    private var dropdownCenter: some View {
        if monitor.snapshot.isAwaitingDecision {
            Text("FINISH")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.25))
        } else if monitor.snapshot.isWorking {
            HStack(spacing: 6) {
                Text(workingWord)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(workingWordColor)
                separator
                Text(workingTimeString())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .monospacedDigit()
            }
            .lineLimit(1)
        } else {
            // Idle but a 5h block is alive: show live tokens + the actual
            // clock time at which the block resets.
            HStack(spacing: 6) {
                Text(formatTokens(monitor.snapshot.tokensBlock))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                separator
                HStack(spacing: 3) {
                    Text("resets")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    Text(blockResetClockString())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
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
            : .white
    }

    private var separator: some View {
        Circle()
            .fill(Color.white.opacity(0.25))
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
        VStack(alignment: .leading, spacing: 14) {
            // Header: model badge on the left, status pill on the right.
            HStack(spacing: 10) {
                ModelDot(model: monitor.snapshot.currentModel,
                         traits: monitor.snapshot.currentModelTraits)
                Text(modelDisplayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                ForEach(modelTraitTags, id: \.self) { tag in
                    traitChip(tag)
                }
                Spacer()
                HStack(spacing: 6) {
                    WorkDot(state: monitor.snapshot.workState)
                    Text(headerLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Hero: 5h block usage with progress bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("5-hour block")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text("resets \(blockResetClockString())")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(formatTokens(monitor.snapshot.tokensBlock))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("tokens")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text(String(format: "$%.2f", monitor.snapshot.costBlock))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .monospacedDigit()
                }
                ProgressTrack(progress: blockProgress())
            }

            // Secondary: today
            HStack(spacing: 14) {
                miniStat(icon: "sun.max.fill",
                         label: "Today",
                         value: formatTokens(monitor.snapshot.tokensToday),
                         sub: String(format: "$%.2f", monitor.snapshot.costToday))
                Divider().frame(height: 28).background(Color.white.opacity(0.08))
                miniStat(icon: "bolt.fill",
                         label: "Sessions",
                         value: "\(monitor.snapshot.activeSessions)",
                         sub: monitor.snapshot.isWorking ? "live" : "—")
            }
        }
    }

    private func miniStat(icon: String, label: String, value: String, sub: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.white.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundColor(.white.opacity(0.45))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text(sub)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
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

struct ProgressTrack: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(colors: [
                            Color(red: 0.55, green: 0.85, blue: 1.0),
                            Color(red: 0.45, green: 0.55, blue: 1.0)
                        ], startPoint: .leading, endPoint: .trailing)
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
        case .working: return Color.green
        case .awaitingDecision: return Color(red: 1.0, green: 0.55, blue: 0.15)
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
