import Foundation
import Combine

/// Per-million-token rates. `cacheWrite5m` and `cacheWrite1h` are billed
/// differently — the 1h variant is 2x base input vs 1.25x for 5m. Cache
/// reads are the same regardless of TTL.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    /// `bigContext` triggers Sonnet's >200k-token tier (2x rates). Opus and
    /// Haiku don't have a 1M-context tier change — they keep the same rates.
    static func forModel(_ model: String, bigContext: Bool) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("opus") {
            return .init(input: 15, output: 75,
                         cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50)
        }
        if m.contains("haiku") {
            return .init(input: 1, output: 5,
                         cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10)
        }
        // Sonnet — 1M tier doubles every rate.
        if bigContext {
            return .init(input: 6, output: 22.5,
                         cacheWrite5m: 7.5, cacheWrite1h: 12, cacheRead: 0.60)
        }
        return .init(input: 3, output: 15,
                     cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)
    }
}

enum WorkState {
    case idle
    case working
    case awaitingDecision
}

struct ModelTraits {
    var thinking: Bool = false
    var oneMillionContext: Bool = false
    var fastMode: Bool = false
    var oneHourCache: Bool = false
}

struct UsageSnapshot {
    var tokensToday: Int = 0
    var costToday: Double = 0
    var tokensBlock: Int = 0
    var costBlock: Double = 0
    var blockStart: Date?
    var activeSessions: Int = 0
    var workState: WorkState = .idle
    var lastActivity: Date?
    var currentModel: String?
    var currentModelTraits: ModelTraits = .init()

    /// Tokens consumed today, broken down by raw model id. Used to render
    /// the per-model split (Opus / Sonnet / Haiku share) in the card.
    var tokensByModelToday: [String: Int] = [:]
    /// Same split but scoped to the *current 5h session block* — the
    /// window that's actively consuming the user's plan quota. More
    /// actionable than today's totals for a per-session percentage.
    var tokensByModelBlock: [String: Int] = [:]
    var costByModelBlock: [String: Double] = [:]

    /// Authoritative plan-budget figures from Anthropic's `/api/oauth/usage`
    /// endpoint — the same data Claude Code's `/usage` slash command and
    /// claude.ai's "Plan usage" panel display. `nil` while the first fetch
    /// hasn't completed or when no OAuth token is available locally.
    var planUsage: PlanUsage?
    /// Reason the last plan fetch failed, if any — used to surface
    /// "log in with `/login`" hints in the UI.
    var planUsageError: PlanUsageFetcher.FetchError?

    var isWorking: Bool { workState == .working }
    var isAwaitingDecision: Bool { workState == .awaitingDecision }
    var hasActivity: Bool { workState != .idle }
}

/// Per-message usage entry kept in memory so we can re-window the 5h block
/// and dedupe retries without re-reading the file.
///
/// Claude Code re-emits the same assistant message on session
/// resume/edit/branch — empirically up to ~17x for a single (message.id,
/// requestId) pair. Aggregating raw entries inflates tokens and cost ~2x,
/// so every consumer must dedupe by `dedupKey`.
private struct UsageEntry {
    let ts: Date
    let totalTokens: Int
    let cost: Double
    /// `"\(message.id)|\(requestId)"`, or nil when either is missing.
    let dedupKey: String?
    /// Raw model id (`claude-opus-4-7`, `claude-sonnet-4-6`, …). Kept so the
    /// expanded card can show today's per-model split without re-parsing.
    let model: String?
}

/// Cached per-file state. Invalidated when (mtime, size) changes.
/// Holds all entries newer than `min(startOfToday, now - 10h)` so we can
/// compute both today's totals and the rolling 5h block from a single list.
private struct FileCache {
    var mtime: Date
    var size: UInt64
    var parsedToOffset: Int       // bytes already parsed from the start
    var entries: [UsageEntry]     // chronological by `ts`
}

final class UsageMonitor: ObservableObject {
    @Published var snapshot = UsageSnapshot()

    private let projectsURL: URL
    private var timer: Timer?
    private var planTimer: Timer?
    private let planFetcher = PlanUsageFetcher()
    private var planTask: Task<Void, Never>?
    private var fileCache: [URL: FileCache] = [:]
    /// Cached result of `lastAssistantInfo` per file. Keyed on (size, mtime)
    /// so we re-scan the 64KB tail only when the file actually grew.
    private var tailCache: [URL: (size: UInt64, mtime: Date, info: LastAssistantInfo)] = [:]
    /// Serial queue prevents two `computeSnapshot` calls from racing on
    /// `fileCache` if a refresh runs long.
    private let refreshQueue = DispatchQueue(label: "CCIsland.refresh", qos: .utility)

    // Pre-allocated parsers — creating these per-line is expensive.
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsURL = home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func start() {
        refresh()
        // 5s is a good cadence for the lights; the cache makes most ticks
        // near-free, so we don't gain much by going slower.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Plan-% rarely moves fast and the endpoint is rate-sensitive — 60s
        // is plenty and matches what the web UI seems to poll at.
        refreshPlanUsage()
        planTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshPlanUsage()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        planTimer?.invalidate(); planTimer = nil
        planTask?.cancel(); planTask = nil
    }

    private func refreshPlanUsage() {
        planTask?.cancel()
        planTask = Task { [weak self] in
            guard let self else { return }
            do {
                let usage = try await self.planFetcher.fetch()
                await MainActor.run {
                    self.snapshot.planUsage = usage
                    self.snapshot.planUsageError = nil
                }
            } catch let err as PlanUsageFetcher.FetchError {
                await MainActor.run {
                    self.snapshot.planUsageError = err
                    // Stale data is more useful than nothing — only clear on
                    // explicit auth failure.
                    if case .unauthorized = err { self.snapshot.planUsage = nil }
                }
            } catch {
                await MainActor.run {
                    self.snapshot.planUsageError = .transport(error)
                }
            }
        }
    }

    private func refresh() {
        refreshQueue.async { [weak self] in
            guard let self else { return }
            var snap = self.computeSnapshot()
            DispatchQueue.main.async {
                // Preserve plan-% fields — they're populated by a separate
                // (slower) timer; the file-derived snapshot would otherwise
                // overwrite them with nil every 5s.
                snap.planUsage = self.snapshot.planUsage
                snap.planUsageError = self.snapshot.planUsageError
                self.snapshot = snap
            }
        }
    }

    private func computeSnapshot() -> UsageSnapshot {
        var snap = UsageSnapshot()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: projectsURL,
                                             includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else {
            return snap
        }

        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let activeThreshold: TimeInterval = 30
        let awaitingThreshold: TimeInterval = 300
        // Keep entries from the earlier of (start of today, 10h ago) so a
        // 5h block that opened up to 5h ago is still fully accounted for and
        // today's totals always cover the full calendar day.
        let pruneCutoff = min(startOfToday, now.addingTimeInterval(-10 * 3600))

        var sawPaths = Set<URL>()
        var mostRecent: (URL, Date)?
        var allEntries: [UsageEntry] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = UInt64(vals?.fileSize ?? 0)

            // Files whose latest write is older than our retention window
            // can't contribute to today or the active block — drop them.
            if mtime < pruneCutoff {
                fileCache.removeValue(forKey: url)
                tailCache.removeValue(forKey: url)
                continue
            }
            sawPaths.insert(url)

            if mostRecent == nil || mtime > mostRecent!.1 {
                mostRecent = (url, mtime)
            }
            if now.timeIntervalSince(mtime) < activeThreshold {
                snap.activeSessions += 1
                if snap.lastActivity == nil || mtime > snap.lastActivity! {
                    snap.lastActivity = mtime
                }
            }

            // Cache hit: file unchanged since last poll.
            if let cached = fileCache[url],
               cached.size == size,
               cached.mtime == mtime {
                allEntries.append(contentsOf: cached.entries)
                continue
            }

            // Parse — incrementally if the file just grew, fully if it
            // shrank/rotated.
            let prev = fileCache[url]
            let startOffset: Int
            var entry = prev ?? FileCache(mtime: mtime, size: size,
                                          parsedToOffset: 0, entries: [])
            if let prev, size < prev.size {
                // File rotated/truncated — re-parse from scratch.
                startOffset = 0
                entry.entries.removeAll(keepingCapacity: true)
            } else {
                startOffset = entry.parsedToOffset
            }

            // Drop entries that have aged out of the retention window.
            entry.entries.removeAll { $0.ts < pruneCutoff }

            parseAppended(url: url, from: startOffset, into: &entry,
                          pruneCutoff: pruneCutoff)

            entry.mtime = mtime
            entry.size = size
            fileCache[url] = entry

            allEntries.append(contentsOf: entry.entries)
        }

        // Drop cache entries for files no longer present.
        if fileCache.count != sawPaths.count {
            for key in fileCache.keys where !sawPaths.contains(key) {
                fileCache.removeValue(forKey: key)
                tailCache.removeValue(forKey: key)
            }
        }

        // Aggregate today's totals with global dedup. Same (msg.id, requestId)
        // can appear up to ~17x across files (session resume/edit/branch);
        // without dedup, totals and cost roughly double.
        var seenToday = Set<String>()
        for e in allEntries where e.ts >= startOfToday {
            if let k = e.dedupKey {
                if !seenToday.insert(k).inserted { continue }
            }
            snap.tokensToday += e.totalTokens
            snap.costToday += e.cost
            if let m = e.model {
                snap.tokensByModelToday[m, default: 0] += e.totalTokens
            }
        }

        // Determine the *current* fixed 5-hour window — matching Claude
        // Code's billing: the window starts at the first message after the
        // previous window expired, then runs for exactly 5 hours. Deduped.
        if let block = currentFixedBlock(entries: allEntries, now: now) {
            snap.blockStart = block.start
            snap.tokensBlock = block.tokens
            snap.costBlock = block.cost
            snap.tokensByModelBlock = block.tokensByModel
            snap.costByModelBlock = block.costByModel

        }

        // State + current model from the most-recently-modified file's tail.
        if let (mostRecentURL, mostRecentMtime) = mostRecent {
            let sinceMod = now.timeIntervalSince(mostRecentMtime)
            let lastInfo = lastAssistantInfo(at: mostRecentURL, mtime: mostRecentMtime,
                                             size: UInt64((try? mostRecentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            snap.currentModel = lastInfo?.model
            snap.currentModelTraits = lastInfo?.traits ?? ModelTraits()
            if sinceMod < 3 {
                snap.workState = .working
            } else if sinceMod < awaitingThreshold,
                      let stop = lastInfo?.stopReason,
                      stop == "end_turn" || stop == "tool_use" {
                snap.workState = .awaitingDecision
            } else {
                snap.workState = .idle
            }
        }

        return snap
    }

    /// Computes the current fixed 5-hour window from sorted entries:
    /// the window starts at the first entry after the previous window
    /// expired; we walk forward, opening a fresh window whenever an entry
    /// falls past `start + 5h`. Returns `nil` if the latest window has
    /// already elapsed (no active window — next message starts a new one).
    private func currentFixedBlock(entries: [UsageEntry], now: Date)
        -> (start: Date, tokens: Int, cost: Double,
            tokensByModel: [String: Int], costByModel: [String: Double])? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.ts < $1.ts }
        let windowLen: TimeInterval = 5 * 3600

        var windowStart = sorted[0].ts
        var tokens = 0
        var cost: Double = 0
        var tokensByModel: [String: Int] = [:]
        var costByModel: [String: Double] = [:]
        var seen = Set<String>()

        for e in sorted {
            if e.ts >= windowStart.addingTimeInterval(windowLen) {
                // Previous window closed — start a fresh one anchored here.
                windowStart = e.ts
                tokens = 0
                cost = 0
                tokensByModel.removeAll(keepingCapacity: true)
                costByModel.removeAll(keepingCapacity: true)
                seen.removeAll(keepingCapacity: true)
            }
            if let k = e.dedupKey {
                if !seen.insert(k).inserted { continue }
            }
            tokens += e.totalTokens
            cost += e.cost
            if let m = e.model {
                tokensByModel[m, default: 0] += e.totalTokens
                costByModel[m, default: 0] += e.cost
            }
        }

        // If `now` is already past the current window, treat it as elapsed.
        if now >= windowStart.addingTimeInterval(windowLen) { return nil }
        return (windowStart, tokens, cost, tokensByModel, costByModel)
    }

    // MARK: - Parsing

    /// Parses the file from `offset` to EOF, line-by-line, appending entries
    /// to `cache`. Lines that don't contain the literal bytes `"type":"assistant"`
    /// are skipped without JSON-decoding — that's the cheap path for the
    /// dominant non-assistant events (queue ops, user messages, etc.).
    private func parseAppended(url: URL,
                               from offset: Int,
                               into cache: inout FileCache,
                               pruneCutoff: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            cache.parsedToOffset = Int(cache.size)
            return
        }
        defer { try? handle.close() }
        if offset > 0 {
            do { try handle.seek(toOffset: UInt64(offset)) }
            catch {
                cache.parsedToOffset = Int(cache.size)
                return
            }
        }
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else {
            cache.parsedToOffset = Int(cache.size)
            return
        }

        let assistantMarker: [UInt8] = Array("\"type\":\"assistant\"".utf8)
        var consumed = 0
        var i = 0
        tail.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let buf = UnsafeBufferPointer(start: base, count: tail.count)
            var lineStart = 0
            for idx in 0..<buf.count {
                if buf[idx] == 0x0A {
                    if idx > lineStart {
                        if containsMarker(buf, lineStart: lineStart, lineEnd: idx, marker: assistantMarker) {
                            let lineData = Data(bytes: buf.baseAddress!.advanced(by: lineStart),
                                                count: idx - lineStart)
                            ingest(line: lineData, into: &cache, pruneCutoff: pruneCutoff)
                        }
                    }
                    lineStart = idx + 1
                    consumed = lineStart
                }
                i = idx
            }
            // Leftover unterminated last line — defer until newline arrives.
            _ = i
        }
        cache.parsedToOffset = offset + consumed
    }

    private func containsMarker(_ buf: UnsafeBufferPointer<UInt8>,
                                lineStart: Int, lineEnd: Int,
                                marker: [UInt8]) -> Bool {
        let lineLen = lineEnd - lineStart
        guard lineLen >= marker.count else { return false }
        let limit = lineEnd - marker.count
        var i = lineStart
        while i <= limit {
            if buf[i] == marker[0] {
                var match = true
                for j in 1..<marker.count {
                    if buf[i + j] != marker[j] { match = false; break }
                }
                if match { return true }
            }
            i += 1
        }
        return false
    }

    private func ingest(line: Data,
                        into cache: inout FileCache,
                        pruneCutoff: Date) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String else { return }
        let ts = iso.date(from: tsStr) ?? isoFallback.date(from: tsStr) ?? .distantPast
        guard ts >= pruneCutoff else { return }

        let model = (message["model"] as? String) ?? "sonnet"
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        // Split the cache-create bucket into 5m vs 1h — they're billed at
        // 1.25x vs 2x base input rate. Falls back to all-5m when the
        // breakdown is missing.
        var cw1h = 0, cw5m = 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            cw1h = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
            cw5m = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
        }
        if cw1h + cw5m == 0 { cw5m = cacheCreate }

        let bigContext = (input + cacheRead + cacheCreate) > 200_000
        let pricing = ModelPricing.forModel(model, bigContext: bigContext)
        let total = input + output + cacheCreate + cacheRead
        let cost = Double(input) / 1_000_000 * pricing.input
                 + Double(output) / 1_000_000 * pricing.output
                 + Double(cw5m) / 1_000_000 * pricing.cacheWrite5m
                 + Double(cw1h) / 1_000_000 * pricing.cacheWrite1h
                 + Double(cacheRead) / 1_000_000 * pricing.cacheRead

        // (message.id, requestId) uniquely identifies a billed assistant
        // turn. The same turn shows up in the JSONL multiple times after
        // resume/edit/branch; we count it once.
        let mid = message["id"] as? String
        let rid = obj["requestId"] as? String
        let key: String? = (mid != nil && rid != nil) ? "\(mid!)|\(rid!)" : nil

        cache.entries.append(UsageEntry(ts: ts, totalTokens: total, cost: cost, dedupKey: key, model: model))
    }

    typealias LastAssistantInfo = (stopReason: String?, model: String?, traits: ModelTraits)

    /// Reads the last ~64KB of `url` for state/model detection. Cached by
    /// (size, mtime) — re-scanned only when the file actually changed.
    private func lastAssistantInfo(at url: URL, mtime: Date, size: UInt64) -> LastAssistantInfo? {
        if let c = tailCache[url], c.size == size, c.mtime == mtime {
            return c.info
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        let offset: UInt64 = endOffset > 65536 ? endOffset - 65536 : 0
        try? handle.seek(toOffset: offset)
        guard let tail = try? handle.readToEnd() else { return nil }

        var lines: [Data] = []
        var lineEnd = tail.count
        for i in stride(from: tail.count - 1, through: 0, by: -1) {
            if tail[i] == 0x0A {
                if i + 1 < lineEnd {
                    lines.append(tail.subdata(in: (i + 1)..<lineEnd))
                }
                lineEnd = i
            }
        }
        if lineEnd > 0 { lines.append(tail.subdata(in: 0..<lineEnd)) }

        var userCameLast = false
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "user" {
                userCameLast = true
                continue
            }
            if type == "assistant",
               let message = obj["message"] as? [String: Any] {
                let model = message["model"] as? String
                let stop = userCameLast ? nil : message["stop_reason"] as? String

                var traits = ModelTraits()
                if let content = message["content"] as? [[String: Any]] {
                    traits.thinking = content.contains { ($0["type"] as? String) == "thinking" }
                }
                if let usage = message["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    traits.oneMillionContext = (input + cacheRead + cacheCreate) > 200_000
                    if let cc = usage["cache_creation"] as? [String: Any] {
                        let h1 = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
                        traits.oneHourCache = h1 > 0
                    }
                    // Claude Code's `/fast` toggle surfaces in the usage
                    // payload as `speed: "fast"` (default is `"standard"`).
                    traits.fastMode = (usage["speed"] as? String) == "fast"
                }
                let info: LastAssistantInfo = (stop, model, traits)
                tailCache[url] = (size, mtime, info)
                return info
            }
        }
        return nil
    }
}
