import Foundation

// ─ What the work went through ───────────────────────────────────────────────

/// Tokens one turn — or an hour, or a whole session — went through, split the
/// way the vendors bill them.
///
/// Four figures rather than one. On the machine this was written on, a single
/// Claude session read 563 million tokens back out of its cache, wrote 6.7
/// million into it, produced 1.1 million and took 3,400 uncached. The total is
/// worth having — it is what the model went through, and cache reads are most
/// of what a session costs — but on its own it is a number about caching, so
/// the split travels with it.
struct TokenCount: Equatable {
    /// Read at full price, with no cache involved.
    var input = 0
    /// New context written into the prompt cache.
    var cacheWrite = 0
    /// Context the model had already seen, read back out of the cache.
    var cacheRead = 0
    var output = 0
    /// What Kiro charged. It bills turns in credits and writes its token
    /// fields as zero, so for Kiro this is the only figure there is.
    var credits = 0.0
    /// What the tokens cost, counted in fresh-input tokens of the model that
    /// spent them — see `TokenPrice`. The figure that says how much of a pile
    /// of tokens cost anything: cache reads add a tenth of themselves or
    /// less, output five to eight times itself.
    var fullPrice = 0.0
    /// Tokens from turns whose model has no price in `TokenPrice`, and so no
    /// share of `fullPrice`. Counted, never guessed at.
    var unpriced = 0

    var total: Int { input + cacheWrite + cacheRead + output }
    var isEmpty: Bool { total == 0 && credits == 0 }

    /// True when credits are the only unit the source gave, which is how the
    /// figure has to be shown.
    var isCredits: Bool { total == 0 && credits > 0 }

    /// What these tokens cost as a share of what they would have cost read
    /// fresh. Nil when none of them could be priced.
    var costShare: Double? {
        let priced = total - unpriced
        guard priced > 0, fullPrice > 0 else { return nil }
        return fullPrice / Double(priced)
    }

    /// A running total that went backwards, which a log that only grows
    /// should never produce.
    var hasNegativePart: Bool {
        input < 0 || cacheWrite < 0 || cacheRead < 0 || output < 0 || credits < 0
    }

    static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(
            input: a.input + b.input,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead,
            output: a.output + b.output,
            credits: a.credits + b.credits,
            fullPrice: a.fullPrice + b.fullPrice,
            unpriced: a.unpriced + b.unpriced
        )
    }

    static func - (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(
            input: a.input - b.input,
            cacheWrite: a.cacheWrite - b.cacheWrite,
            cacheRead: a.cacheRead - b.cacheRead,
            output: a.output - b.output,
            credits: a.credits - b.credits,
            fullPrice: a.fullPrice - b.fullPrice,
            unpriced: a.unpriced - b.unpriced
        )
    }

    static func += (a: inout TokenCount, b: TokenCount) { a = a + b }
    static func -= (a: inout TokenCount, b: TokenCount) { a = a - b }
}

extension TokenCount: Codable {
    /// Written as a bare array. The ledger keeps one of these per hour per
    /// session, and a key name on every figure would make the file mostly key
    /// names. The four token figures always; then credits, the full-price
    /// figure and the unpriced count, as far as any of them is non-zero. A
    /// reader that knows fewer fields stops early and loses nothing it knew.
    init(from decoder: Decoder) throws {
        var row = try decoder.unkeyedContainer()
        input = try row.decode(Int.self)
        cacheWrite = try row.decode(Int.self)
        cacheRead = try row.decode(Int.self)
        output = try row.decode(Int.self)
        credits = row.isAtEnd ? 0 : try row.decode(Double.self)
        // A row that ends before the price was written before prices were
        // counted at all. Its tokens are unpriced — not priced at nothing,
        // which would read as free and drag every share down with it.
        let pricedWhenWritten = !row.isAtEnd
        fullPrice = row.isAtEnd ? 0 : try row.decode(Double.self)
        unpriced = row.isAtEnd ? 0 : try row.decode(Int.self)
        if !pricedWhenWritten { unpriced = total }
    }

    func encode(to encoder: Encoder) throws {
        var row = encoder.unkeyedContainer()
        try row.encode(input)
        try row.encode(cacheWrite)
        try row.encode(cacheRead)
        try row.encode(output)
        // Whole tokens: a fraction of one is precision nobody can read. But a
        // price never rounds down to nothing, or the row would read back as
        // one written before prices were counted.
        let price = fullPrice > 0 ? max(1, fullPrice.rounded()) : 0
        let trailing: [Double] = [credits, price, Double(unpriced)]
        guard let last = trailing.lastIndex(where: { $0 != 0 }) else { return }
        try row.encode(credits)
        if last >= 1 { try row.encode(price) }
        if last >= 2 { try row.encode(unpriced) }
    }
}

// ─ Hour by hour ─────────────────────────────────────────────────────────────

/// Where an hour starts, in local time.
///
/// Local rather than UTC because the chart is read against a wall clock: in a
/// time zone half an hour off UTC, "14:00" has to mean the hour that starts at
/// two o'clock there, not one that starts at half past.
enum TokenHours {

    static let length: TimeInterval = 3_600

    /// The start of the hour `date` falls in, in whole seconds since 1970.
    static func start(of date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return Int(start.timeIntervalSince1970)
    }

    /// The `count` hours that end with the one `now` falls in, oldest first.
    ///
    /// Stepped back in absolute time and then snapped to the hour, so a
    /// daylight-saving change gives one hour fewer or one more on the wall
    /// clock rather than a column that spans two.
    static func recent(_ count: Int, endingAt now: Date, calendar: Calendar = .current) -> [Int] {
        let current = TimeInterval(start(of: now, calendar: calendar))
        return (0..<count).reversed().map { back in
            start(
                of: Date(timeIntervalSince1970: current - TimeInterval(back) * length + 1),
                calendar: calendar
            )
        }
    }
}

/// A count kept hour by hour.
struct HourlyTokens: Equatable {

    private(set) var byHour: [Int: TokenCount] = [:]

    init(byHour: [Int: TokenCount] = [:]) {
        self.byHour = byHour
    }

    subscript(hour: Int) -> TokenCount? { byHour[hour] }

    var isEmpty: Bool { byHour.isEmpty }

    var total: TokenCount { byHour.values.reduce(TokenCount(), +) }

    /// Everything in the hours that start at or after `hour`.
    func total(from hour: Int) -> TokenCount {
        byHour.reduce(TokenCount()) { $1.key >= hour ? $0 + $1.value : $0 }
    }

    mutating func add(_ count: TokenCount, at date: Date) {
        byHour[TokenHours.start(of: date), default: TokenCount()] += count
    }

    /// Takes back something added earlier — a message counted from an
    /// unfinished copy, about to be counted again from the finished one.
    mutating func remove(_ count: TokenCount, at date: Date) {
        let hour = TokenHours.start(of: date)
        let left = (byHour[hour] ?? TokenCount()) - count
        byHour[hour] = left.isEmpty ? nil : left
    }

    static func + (a: HourlyTokens, b: HourlyTokens) -> HourlyTokens {
        HourlyTokens(byHour: a.byHour.merging(b.byHour, uniquingKeysWith: +))
    }

    /// Hour by hour, whichever of the two readings is larger.
    ///
    /// A recount after a restart is meant to reproduce what was counted
    /// before, and it does — unless the log has lost something in between,
    /// which happens: Claude Code deletes old transcripts on its own schedule.
    /// What was counted while the log was whole stays counted.
    func atLeast(_ floor: HourlyTokens?) -> HourlyTokens {
        guard let floor else { return self }
        var result = byHour
        for (hour, count) in floor.byHour where count.total > (result[hour]?.total ?? 0)
            || (count.total == 0 && count.credits > (result[hour]?.credits ?? 0)) {
            result[hour] = count
        }
        return HourlyTokens(byHour: result)
    }
}

extension HourlyTokens: Codable {
    /// An object keyed by the hour's start, which reads back as what it is.
    init(from decoder: Decoder) throws {
        let raw = try [String: TokenCount](from: decoder)
        var hours: [Int: TokenCount] = [:]
        for (key, count) in raw {
            guard let hour = Int(key) else { continue }
            hours[hour] = count
        }
        byHour = hours
    }

    func encode(to encoder: Encoder) throws {
        let raw = Dictionary(uniqueKeysWithValues: byHour.map { (String($0.key), $0.value) })
        try raw.encode(to: encoder)
    }
}

// ─ Reading it out of each tool's logs ───────────────────────────────────────

/// Keeps one session's count current as its log grows.
///
/// One per session the ledger is following, made when an agent is first
/// matched to a log and dropped once that agent has gone. Stateful, because
/// that is the point: after the first read, a pass costs whatever the agent
/// has written since the last one.
protocol TokenCounter: AnyObject {
    /// Read whatever the log has gained. True when the count moved.
    func advance() -> Bool
    /// Everything counted so far, from the agent's start onwards.
    var hours: HourlyTokens { get }
    /// The same, cut off at a moment: a session whose agent has gone keeps
    /// what was written while it ran.
    func hours(before cutoff: Date) -> HourlyTokens
    /// Whether the log was there to read. A session whose file has gone keeps
    /// the count it had rather than dropping to nothing.
    var found: Bool { get }
    /// Subagent logs that added to the count. Only Claude Code keeps them
    /// apart.
    var subagents: Int { get }
    /// The working directory the session itself records, where it records one.
    var project: String? { get }
}

/// A file's size and modification date, read fresh every time.
///
/// Not `URL.resourceValues`: that caches what it read on the URL it was asked
/// through, and a counter asks through the same URL on every pass — off the
/// main thread, where nothing clears the cache — so a log that had grown went
/// on reporting the size it had the first time.
enum FileStamp {
    static func of(_ url: URL) -> (size: UInt64, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (size, modified)
    }
}

extension FileTail {

    /// Where the last complete line of a file ends.
    ///
    /// The position to carry on from after reading a file that is still being
    /// written: whatever follows is a line the agent has not finished, and
    /// starting the next read anywhere inside it would turn its second half
    /// into a line of its own that parses as nothing.
    static func endOfLastLine(of url: URL, chunk: Int = 64 * 1024) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard var upper = try? handle.seekToEnd() else { return 0 }
        while upper > 0 {
            let lower = upper > UInt64(chunk) ? upper - UInt64(chunk) : 0
            guard (try? handle.seek(toOffset: lower)) != nil,
                  let data = try? handle.read(upToCount: Int(upper - lower))
            else { return 0 }
            if let newline = data.lastIndex(of: 0x0A) {
                return lower + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
            }
            upper = lower
        }
        return 0
    }
}

// ─ Claude Code ──────────────────────────────────────────────────────────────

enum ClaudeTokens {

    struct Turn {
        let id: String
        let at: Date
        let count: TokenCount
    }

    /// See `ClaudeModelTally.usageMarker`: most lines are not worth decoding,
    /// and this decides on bytes.
    private static let usageMarker = Data("\"usage\"".utf8)

    /// One assistant record's usage, with the message id that ties its copies
    /// together. A `<synthetic>` record carries a usage block of zeros and is
    /// dropped by the emptiness test with everything else that did no work.
    static func turn(_ line: Data) -> Turn? {
        guard line.range(of: usageMarker) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any],
              let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        else { return nil }

        var count = TokenCount(
            input: JSONNumber.int(usage["input_tokens"]) ?? 0,
            cacheWrite: JSONNumber.int(usage["cache_creation_input_tokens"]) ?? 0,
            cacheRead: JSONNumber.int(usage["cache_read_input_tokens"]) ?? 0,
            output: JSONNumber.int(usage["output_tokens"]) ?? 0
        )
        guard !count.isEmpty else { return nil }
        price(&count, model: message["model"] as? String, usage: usage)
        return Turn(id: id, at: at, count: count)
    }

    /// Prices a turn by the model that took it and how long its cache writes
    /// were kept. Claude Code keeps the main conversation an hour and
    /// subagents five minutes, and the hour costs 2× input where five minutes
    /// costs 1.25×, so the split is read rather than assumed. A write with no
    /// breakdown — older logs — is the five-minute default.
    static func price(_ count: inout TokenCount, model: String?, usage: [String: Any]) {
        guard let model, let price = TokenPrice.of(model) else {
            count.unpriced = count.total
            return
        }
        let split = usage["cache_creation"] as? [String: Any]
        let hour = min(count.cacheWrite, JSONNumber.int(split?["ephemeral_1h_input_tokens"]) ?? 0)
        count.fullPrice = price.fullPrice(
            input: count.input,
            write5m: count.cacheWrite - hour,
            write1h: hour,
            cacheRead: count.cacheRead,
            output: count.output
        )
    }
}

/// A Claude Code session: its transcript, and the transcript of every
/// subagent it started.
///
/// The subagents are where much of the work goes. Each one — a Task call, an
/// Explore pass, a teammate in an agent team, a subagent's own subagent —
/// keeps its own log in `<session>/subagents/`, flat whatever its depth, and
/// none of its turns are repeated in the main transcript: on the session this
/// was checked against, 10,965 subagent responses and 2,216 main-thread ones,
/// with no identifier in both. The subagents had read 3.9 billion tokens of
/// cache to the main thread's 563 million, so a count of the main transcript
/// alone would have been a small part of the truth.
final class ClaudeTokenCounter: TokenCounter {

    private let main: URL
    private let since: Date
    private var cursors: [String: UInt64] = [:]

    /// The largest copy of each message, kept for the reason
    /// `ClaudeModelTally.byId` gives: one assistant message is written many
    /// times, its output count growing, and only the last copy is whole.
    private var messages: [String: (at: Date, count: TokenCount)] = [:]
    private var contributors: Set<String> = []

    private(set) var hours = HourlyTokens()
    private(set) var found = false
    let project: String? = nil

    init(transcript: URL, since: Date) {
        main = transcript
        self.since = since
    }

    var subagents: Int { contributors.subtracting([main.path]).count }

    private var subagentFolder: URL {
        main.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    }

    func advance() -> Bool {
        var changed = read(main)
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: subagentFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for log in logs where log.pathExtension == "jsonl" {
            if read(log) { changed = true }
        }
        return changed
    }

    func hours(before cutoff: Date) -> HourlyTokens {
        var result = HourlyTokens()
        for message in messages.values where message.at < cutoff {
            result.add(message.count, at: message.at)
        }
        return result
    }

    private func read(_ file: URL) -> Bool {
        guard let stamp = FileStamp.of(file) else { return false }
        if file == main { found = true }
        let path = file.path
        let length = stamp.size

        if let cursor = cursors[path], length >= cursor {
            guard length > cursor else { return false }
            let appended = FileTail.appendedLines(to: file, after: cursor)
            cursors[path] = appended.next
            var changed = false
            for line in appended.lines {
                if let turn = ClaudeTokens.turn(line), keep(turn, from: path) { changed = true }
            }
            return changed
        }

        // First sight — or a file that got shorter, which a log never should,
        // and which is read again rather than trusted. The position is taken
        // before reading, so a line finished during the read is seen twice,
        // which the message ids make harmless, and never not at all.
        cursors[path] = FileTail.endOfLastLine(of: file)

        // A subagent log last written before the agent started belongs to an
        // earlier run of a resumed session, and cannot hold a turn of this one.
        if stamp.modified < since { return false }

        // Backwards from the end, as `ClaudeModelTally` reads, and stopping on
        // the same evidence: a run of turns older than the agent, not one.
        var changed = false
        var consecutivelyOld = 0
        FileTail.backwards(of: file) { line in
            guard let turn = ClaudeTokens.turn(line) else { return false }
            if turn.at < since {
                consecutivelyOld += 1
                return consecutivelyOld >= 25
            }
            consecutivelyOld = 0
            if keep(turn, from: path) { changed = true }
            return false
        }
        return changed
    }

    private func keep(_ turn: ClaudeTokens.Turn, from path: String) -> Bool {
        guard turn.at >= since else { return false }
        if let seen = messages[turn.id] {
            guard turn.count.output > seen.count.output else { return false }
            hours.remove(seen.count, at: seen.at)
        }
        messages[turn.id] = (turn.at, turn.count)
        hours.add(turn.count, at: turn.at)
        contributors.insert(path)
        return true
    }
}

// ─ Codex ────────────────────────────────────────────────────────────────────

enum CodexTokens {

    struct Reading {
        let at: Date
        /// The session's running total as of this event.
        let total: TokenCount
        /// The turn this event reports on.
        let last: TokenCount
    }

    private static let marker = Data("\"token_count\"".utf8)
    private static let contextMarker = Data("\"turn_context\"".utf8)

    /// The model a turn ran on. Codex writes it per turn, in `turn_context`,
    /// and `/model` changes it mid-session.
    static func model(_ line: Data) -> String? {
        guard line.range(of: contextMarker) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "turn_context",
              let payload = record["payload"] as? [String: Any],
              let model = payload["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// One turn's figures, priced by the model it ran on.
    static func priced(_ count: TokenCount, model: String?) -> TokenCount {
        var priced = count
        guard let model, let price = TokenPrice.of(model) else {
            priced.unpriced = count.total
            return priced
        }
        priced.fullPrice = price.fullPrice(
            input: count.input, write5m: count.cacheWrite, write1h: 0,
            cacheRead: count.cacheRead, output: count.output
        )
        return priced
    }

    static func reading(_ line: Data) -> Reading? {
        guard line.range(of: marker) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        else { return nil }
        return Reading(at: at, total: count(total), last: count(last))
    }

    /// Codex's `input_tokens` already includes the cached part — see
    /// `CodexModelTally.scan` — so the uncached figure is what is left after
    /// taking the cache out, and the four parts add up to Codex's own
    /// `total_tokens`. Reasoning is inside `output_tokens` for the same reason.
    static func count(_ usage: [String: Any]) -> TokenCount {
        let input = JSONNumber.int(usage["input_tokens"]) ?? 0
        let cached = JSONNumber.int(usage["cached_input_tokens"]) ?? 0
        let written = JSONNumber.int(usage["cache_write_input_tokens"]) ?? 0
        return TokenCount(
            input: max(0, input - cached - written),
            cacheWrite: written,
            cacheRead: cached,
            output: JSONNumber.int(usage["output_tokens"]) ?? 0
        )
    }
}

/// A Codex session, from its rollout.
///
/// Counted from the running total rather than by adding up each turn. Codex
/// writes a `token_count` event after every turn, and sometimes writes the
/// same one twice: on the machine this was written on, one rollout repeated a
/// reading two times, and adding up `last_token_usage` would have counted
/// those turns twice. The difference between successive totals cannot do
/// that — a repeated reading is a difference of nothing — and it reproduces
/// Codex's own figure for every rollout on the machine, to the token.
final class CodexTokenCounter: TokenCounter {

    private let rollout: URL
    private let since: Date
    private var cursor: UInt64 = 0
    /// The running total as of the last event read, including events from
    /// before the agent started: that is the baseline its first turn is
    /// measured from.
    private var previous: TokenCount?
    /// The model named by the latest `turn_context`, which the turns after
    /// it ran on.
    private var model: String?
    private var turns: [(at: Date, count: TokenCount)] = []

    private(set) var hours = HourlyTokens()
    private(set) var found = false
    let subagents = 0
    let project: String? = nil

    init(rollout: URL, since: Date) {
        self.rollout = rollout
        self.since = since
    }

    func advance() -> Bool {
        guard let length = FileStamp.of(rollout)?.size else { return false }
        found = true
        if length < cursor {
            // Rewritten rather than appended to. Counted again from the top.
            cursor = 0
            previous = nil
            model = nil
            turns = []
            hours = HourlyTokens()
        }
        guard length > cursor else { return false }

        let appended = FileTail.appendedLines(to: rollout, after: cursor)
        cursor = appended.next
        var changed = false
        for line in appended.lines {
            if let named = CodexTokens.model(line) {
                model = named
            } else if let reading = CodexTokens.reading(line), absorb(reading) {
                changed = true
            }
        }
        return changed
    }

    /// One event. The first one seen has no total before it to be measured
    /// against, so its own turn is what it adds — which is also right for a
    /// rollout that starts partway through a session's running total.
    private func absorb(_ reading: CodexTokens.Reading) -> Bool {
        let delta: TokenCount
        if let previous {
            guard reading.total != previous else { return false }
            let difference = reading.total - previous
            delta = difference.hasNegativePart ? reading.last : difference
        } else {
            delta = reading.last
        }
        previous = reading.total
        guard reading.at >= since, !delta.isEmpty else { return false }
        let turn = CodexTokens.priced(delta, model: model)
        turns.append((reading.at, turn))
        hours.add(turn, at: reading.at)
        return true
    }

    func hours(before cutoff: Date) -> HourlyTokens {
        var result = HourlyTokens()
        for turn in turns where turn.at < cutoff { result.add(turn.count, at: turn.at) }
        return result
    }
}

// ─ Kiro ─────────────────────────────────────────────────────────────────────

/// A Kiro CLI session, from its session file.
///
/// The file is rewritten whole after every turn, so it is read whole, and
/// every turn ever seen in it is remembered: a file rewritten without some of
/// its early turns — after a compaction, say — must not take back credits
/// that were spent.
final class KiroTokenCounter: TokenCounter {

    private let session: URL
    private let since: Date
    private var stamp: (size: UInt64, modified: Date)?
    private var seen: [String: (at: Date, count: TokenCount)] = [:]

    private(set) var hours = HourlyTokens()
    private(set) var found = false
    private(set) var project: String?
    let subagents = 0

    init(session: URL, since: Date) {
        self.session = session
        self.since = since
    }

    func advance() -> Bool {
        guard let current = FileStamp.of(session) else { return false }
        found = true
        if let stamp, stamp.size == current.size, stamp.modified == current.modified {
            return false
        }
        guard let file = KiroSessionFile.read(session) else { return false }
        stamp = current
        project = file.cwd ?? project

        var changed = false
        for turn in file.turns where turn.at >= since {
            let key = "\(turn.at.timeIntervalSince1970)|\(turn.model)"
            guard seen[key] == nil else { continue }
            // Credits are the price. Any tokens Kiro ever writes alongside
            // them are counted but not priced a second time.
            let count = TokenCount(
                input: turn.inputTokens,
                output: turn.outputTokens,
                credits: turn.credits,
                unpriced: turn.inputTokens + turn.outputTokens
            )
            seen[key] = (turn.at, count)
            hours.add(count, at: turn.at)
            changed = true
        }
        return changed
    }

    func hours(before cutoff: Date) -> HourlyTokens {
        var result = HourlyTokens()
        for turn in seen.values where turn.at < cutoff { result.add(turn.count, at: turn.at) }
        return result
    }
}
