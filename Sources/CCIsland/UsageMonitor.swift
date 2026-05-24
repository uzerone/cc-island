import Foundation
import Combine

struct ModelPricing {
    let input: Double      // $ / 1M tokens
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    static func forModel(_ model: String) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("opus") {
            return .init(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50)
        }
        if m.contains("haiku") {
            return .init(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10)
        }
        return .init(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30)
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

    var isWorking: Bool { workState == .working }
    var isAwaitingDecision: Bool { workState == .awaitingDecision }
    var hasActivity: Bool { workState != .idle }
}

/// Per-message usage entry kept in memory so we can re-window the 5h block
/// without re-reading the file.
private struct UsageEntry {
    let ts: Date
    let totalTokens: Int
    let cost: Double
}

/// Cached per-file state. Invalidated when (mtime, size) changes or when
/// the day boundary moves.
private struct FileCache {
    var mtime: Date
    var size: UInt64
    var parsedToOffset: Int       // bytes already parsed from the start
    var dayCaptured: Date         // start-of-day used for today's totals
    var todayTokens: Int
    var todayCost: Double
    var recentEntries: [UsageEntry]   // all entries newer than (now - 6h) at last parse
}

final class UsageMonitor: ObservableObject {
    @Published var snapshot = UsageSnapshot()

    private let projectsURL: URL
    private var timer: Timer?
    private var fileCache: [URL: FileCache] = [:]
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
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.computeSnapshot()
            DispatchQueue.main.async { self.snapshot = snap }
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
        // Keep entries from the last 10h so a fixed 5h window starting up to
        // ~5h ago still has its tokens accounted for.
        let pruneCutoff = now.addingTimeInterval(-10 * 3600)

        var sawPaths = Set<URL>()
        var mostRecent: (URL, Date)?
        var allEntries: [UsageEntry] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = UInt64(vals?.fileSize ?? 0)

            // Files older than the entire day-or-block window can be dropped
            // from the cache entirely.
            if mtime < startOfToday && mtime < pruneCutoff {
                fileCache.removeValue(forKey: url)
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
               cached.mtime == mtime,
               cached.dayCaptured == startOfToday {
                snap.tokensToday += cached.todayTokens
                snap.costToday += cached.todayCost
                allEntries.append(contentsOf: cached.recentEntries)
                continue
            }

            // Otherwise parse — incrementally if the file just grew, fully if
            // it shrank/rotated or the day rolled over.
            let dayRolled = (fileCache[url]?.dayCaptured ?? .distantPast) != startOfToday
            let prev = fileCache[url]
            let startOffset: Int
            var entry = prev ?? FileCache(mtime: mtime, size: size,
                                          parsedToOffset: 0,
                                          dayCaptured: startOfToday,
                                          todayTokens: 0, todayCost: 0,
                                          recentEntries: [])
            if dayRolled || (prev != nil && size < prev!.size) {
                // Reset: re-parse from start.
                startOffset = 0
                entry.todayTokens = 0
                entry.todayCost = 0
                entry.recentEntries.removeAll(keepingCapacity: true)
            } else {
                startOffset = entry.parsedToOffset
            }

            // Prune in-memory entries older than the 6h window before
            // appending new ones — bounds memory.
            entry.recentEntries.removeAll { $0.ts < pruneCutoff }

            parseAppended(url: url, from: startOffset, into: &entry,
                          startOfToday: startOfToday, pruneCutoff: pruneCutoff)

            entry.mtime = mtime
            entry.size = size
            entry.dayCaptured = startOfToday
            fileCache[url] = entry

            snap.tokensToday += entry.todayTokens
            snap.costToday += entry.todayCost
            allEntries.append(contentsOf: entry.recentEntries)
        }

        // Drop cache entries for files no longer present.
        if fileCache.count != sawPaths.count {
            for key in fileCache.keys where !sawPaths.contains(key) {
                fileCache.removeValue(forKey: key)
            }
        }

        // Determine the *current* fixed 5-hour window — matching Claude
        // Code's billing: the window starts at the first message after the
        // previous window expired, then runs for exactly 5 hours.
        if let (windowStart, windowTokens, windowCost) = currentFixedBlock(entries: allEntries, now: now) {
            snap.blockStart = windowStart
            snap.tokensBlock = windowTokens
            snap.costBlock = windowCost
        }

        // State + current model from the most-recently-modified file's tail.
        if let (mostRecentURL, mostRecentMtime) = mostRecent {
            let sinceMod = now.timeIntervalSince(mostRecentMtime)
            let lastInfo = lastAssistantInfo(at: mostRecentURL)
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
        -> (start: Date, tokens: Int, cost: Double)? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.ts < $1.ts }
        let windowLen: TimeInterval = 5 * 3600

        var windowStart = sorted[0].ts
        var tokens = 0
        var cost: Double = 0

        for e in sorted {
            if e.ts >= windowStart.addingTimeInterval(windowLen) {
                // Previous window closed — start a fresh one anchored here.
                windowStart = e.ts
                tokens = 0
                cost = 0
            }
            tokens += e.totalTokens
            cost += e.cost
        }

        // If `now` is already past the current window, treat it as elapsed.
        if now >= windowStart.addingTimeInterval(windowLen) { return nil }
        return (windowStart, tokens, cost)
    }

    // MARK: - Parsing

    /// Parses the file from `offset` to EOF, line-by-line, appending entries
    /// to `cache`. Lines that don't contain the literal bytes `"type":"assistant"`
    /// are skipped without JSON-decoding — that's the cheap path for the
    /// dominant non-assistant events (queue ops, user messages, etc.).
    private func parseAppended(url: URL,
                               from offset: Int,
                               into cache: inout FileCache,
                               startOfToday: Date,
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
                            ingest(line: lineData, into: &cache,
                                   startOfToday: startOfToday, pruneCutoff: pruneCutoff)
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
                        startOfToday: Date,
                        pruneCutoff: Date) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String else { return }
        let ts = iso.date(from: tsStr) ?? isoFallback.date(from: tsStr) ?? .distantPast

        let model = (message["model"] as? String) ?? "sonnet"
        let pricing = ModelPricing.forModel(model)
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let total = input + output + cacheCreate + cacheRead
        let cost = Double(input) / 1_000_000 * pricing.input
                 + Double(output) / 1_000_000 * pricing.output
                 + Double(cacheCreate) / 1_000_000 * pricing.cacheWrite
                 + Double(cacheRead) / 1_000_000 * pricing.cacheRead

        if ts >= startOfToday {
            cache.todayTokens += total
            cache.todayCost += cost
        }
        if ts >= pruneCutoff {
            cache.recentEntries.append(UsageEntry(ts: ts, totalTokens: total, cost: cost))
        }
    }

    /// Reads the last ~64KB of `url` for state/model detection.
    private func lastAssistantInfo(at url: URL)
        -> (stopReason: String?, model: String?, traits: ModelTraits)?
    {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset: UInt64 = size > 65536 ? size - 65536 : 0
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
                if let m = model?.lowercased() {
                    traits.fastMode = m == "claude-opus-4-6"
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
                }
                return (stop, model, traits)
            }
        }
        return nil
    }
}
