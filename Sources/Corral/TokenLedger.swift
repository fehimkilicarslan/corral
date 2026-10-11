import Foundation

/// Which agent a count belongs to: a pid, and when that process started.
///
/// The pid alone would not do. Pids are recycled, and a count is kept long
/// after the process it describes has gone — the next process to be given the
/// number must not inherit it.
struct TokenOwner: Hashable {
    let pid: pid_t
    /// Whole seconds since 1970, rounded down, so the same process makes the
    /// same key however precisely its start was read.
    let started: Int

    init(pid: pid_t, startedAt: Date) {
        self.pid = pid
        started = Int(startedAt.timeIntervalSince1970.rounded(.down))
    }

    init(_ process: AgentProcess) {
        self.init(pid: process.pid, startedAt: process.startedAt)
    }
}

/// One session's count, as far as one agent took it.
///
/// The unit the ledger keeps, and the unit a recount replaces: counting again
/// writes over the record rather than adding to it, which is what makes it
/// safe to count again after a restart. Each record covers `[since, until)` of
/// one log, and no two records for the same log overlap — so a session resumed
/// by a second agent, the same file under a new process, is counted once, half
/// under each.
struct TokenRecord: Equatable {
    let tool: Tool
    /// The session's log: a transcript, a rollout, a session file.
    let file: String
    /// Where the work was done — the session's own record of it where there is
    /// one, the agent's working directory otherwise.
    var project: String?
    let owner: TokenOwner
    let since: Date
    /// When the agent was found gone. Nil while it is still running.
    var until: Date?
    var subagents: Int
    var hours: HourlyTokens

    var isOpen: Bool { until == nil }
    var key: String { Self.key(file: file, since: since) }

    static func key(file: String, since: Date) -> String {
        "\(file)#\(Int(since.timeIntervalSince1970.rounded(.down)))"
    }
}

extension TokenRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case tool, file, project, pid, started, since, until, subagents, hours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(Tool.self, forKey: .tool)
        file = try container.decode(String.self, forKey: .file)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        owner = TokenOwner(
            pid: try container.decode(pid_t.self, forKey: .pid),
            startedAt: Date(timeIntervalSince1970: TimeInterval(
                try container.decode(Int.self, forKey: .started)
            ))
        )
        since = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .since))
        until = try container.decodeIfPresent(Double.self, forKey: .until)
            .map { Date(timeIntervalSince1970: $0) }
        subagents = try container.decodeIfPresent(Int.self, forKey: .subagents) ?? 0
        hours = try container.decodeIfPresent(HourlyTokens.self, forKey: .hours) ?? HourlyTokens()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tool, forKey: .tool)
        try container.encode(file, forKey: .file)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encode(owner.pid, forKey: .pid)
        try container.encode(owner.started, forKey: .started)
        try container.encode(since.timeIntervalSince1970, forKey: .since)
        try container.encodeIfPresent(until?.timeIntervalSince1970, forKey: .until)
        if subagents > 0 { try container.encode(subagents, forKey: .subagents) }
        try container.encode(hours, forKey: .hours)
    }
}

/// What the ledger knows, frozen for the window to read.
struct TokenSnapshot {

    /// A count with what it is a count of.
    struct Usage: Equatable {
        var hours = HourlyTokens()
        /// The earliest moment counted.
        var since = Date.distantFuture
        var sessions = 0
        var subagents = 0
        /// Kept with the hours, so a window redrawn every two seconds does not
        /// add them all up again for every row.
        var total = TokenCount()

        mutating func absorb(_ record: TokenRecord) {
            hours = hours + record.hours
            total += record.hours.total
            since = min(since, record.since)
            sessions += 1
            subagents += record.subagents
        }
    }

    let agents: [TokenOwner: Usage]
    let projects: [String: Usage]

    static let empty = TokenSnapshot(agents: [:], projects: [:])

    init(agents: [TokenOwner: Usage], projects: [String: Usage]) {
        self.agents = agents
        self.projects = projects
    }

    init<Records: Sequence>(records: Records) where Records.Element == TokenRecord {
        var agents: [TokenOwner: Usage] = [:]
        var projects: [String: Usage] = [:]
        for record in records {
            agents[record.owner, default: Usage()].absorb(record)
            if let project = record.project {
                projects[project, default: Usage()].absorb(record)
            }
        }
        self.init(agents: agents, projects: projects)
    }
}

/// What every agent Corral has seen has spent, counted from the tools' own
/// logs and kept.
///
/// CPU time comes from the kernel, which keeps it per process for as long as
/// the process lives. Nothing keeps tokens that way, but every tool that
/// spends them writes them down turn by turn — Claude Code in its
/// transcripts, Codex in its rollouts, Kiro in its session files — so this is
/// the same idea built from those: each agent's spend since it started,
/// subagents included, hour by hour.
///
/// Three properties make it trustworthy rather than merely plausible:
///
///  - **Counted once.** Each tool repeats itself in its own way — Claude
///    writes one message many times, Codex repeats a reading — and each
///    counter undoes that. Across agents, a log has one owner at a time.
///  - **Safe to count again.** A record is replaced by its recount, never
///    added to, so a restart, a crash or a second copy of Corral cannot inflate
///    anything.
///  - **Nothing missed while Corral sleeps.** The hours come from the logs'
///    own timestamps, not from when Corral happened to look. A Mac that slept,
///    an app that was quit, or a timer slowed down in the background only
///    delays the count; on the next pass the turns land in the hours they were
///    taken in.
///
/// It runs wherever the inventory runs, and the inventory runs while the
/// window is closed — Corral in the menu bar is Corral counting. Nothing is
/// sent anywhere and nothing of what was said is kept: numbers, log paths and
/// project paths, in Application Support.
final class TokenLedger {

    /// An agent as the inventory saw it on one pass.
    struct Claim {
        let owner: TokenOwner
        /// The exact start, where `owner` keeps it rounded.
        let startedAt: Date
        let tool: Tool
        let project: String?
        /// Every pid in the group, for the tool that names its sessions by pid.
        let pids: Set<pid_t>
        /// The log the session reader matched to this agent.
        let source: String?
    }

    /// The tools whose logs record what was spent.
    ///
    /// Cursor writes a context figure and nothing cumulative; Antigravity's
    /// conversations are encrypted; Windsurf and Copilot write nothing Corral
    /// can read. Their rows have no token figure rather than a zero.
    static let counted: Set<Tool> = [.claudeCode, .codex, .kiroCLI, .kiroCrew]

    static let version = 1

    /// Long enough to answer "what did this project cost me this quarter",
    /// short enough that the file stays small. Only closed records age out.
    static let retention: TimeInterval = 180 * 86_400

    static var defaultStore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corral/token-ledger.json")
    }

    private let store: URL?
    private let kiroRoot: URL
    private let ttl: TimeInterval
    private let saveInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.popy.corral.tokens", qos: .utility)
    private let lock = NSLock()

    // Touched only on `queue`, or by a test driving `pass` directly.
    private var records: [String: TokenRecord] = [:] {
        didSet { snapshotIsStale = true }
    }
    /// The snapshot is a fold over every record, months of closed ones
    /// included, so it is rebuilt when a record changes rather than on every
    /// pass — most passes change nothing.
    private var snapshotIsStale = true
    private var latest = TokenSnapshot.empty
    private var counters: [String: TokenCounter] = [:]
    /// What a record held when it was read back from disk, still open. See
    /// `HourlyTokens.atLeast`.
    private var floors: [String: HourlyTokens] = [:]
    private var loaded = false
    /// False when the file on disk was written by a newer Corral, which this
    /// one must not write over.
    private var writable = true
    private var dirty = false
    private var savedAt = Date.distantPast
    /// When the file was last written by this copy of Corral, to notice
    /// another copy writing in between.
    private var stamp: Date?

    // Behind `lock`.
    private var current = TokenSnapshot.empty
    private var computedAt = Date.distantPast
    private var working = false

    /// `store` nil keeps everything in memory — for tests, which must not
    /// read or write the ledger the app keeps.
    init(
        store: URL? = TokenLedger.defaultStore,
        kiroRoot: URL = KiroSessions.defaultRoot,
        ttl: TimeInterval = 5,
        saveInterval: TimeInterval = 30
    ) {
        self.store = store
        self.kiroRoot = kiroRoot
        self.ttl = ttl
        self.saveInterval = saveInterval
    }

    // ─ Driving it ───────────────────────────────────────────────────────────

    /// Hand over what the inventory saw. The counting happens on a queue of
    /// its own: the first pass after launch reads each running agent's log
    /// back to its start, which for a long session is tens of megabytes, and
    /// the inventory's two-second tick runs on the main thread.
    func refresh(_ claims: [Claim], alive: Set<TokenOwner>, now: Date = Date()) {
        lock.lock()
        let due = !working && now.timeIntervalSince(computedAt) >= ttl
        if due { working = true }
        lock.unlock()
        guard due else { return }

        queue.async { [self] in
            let snapshot = pass(claims, alive: alive, now: now)
            lock.lock()
            current = snapshot
            computedAt = Date()
            working = false
            lock.unlock()
        }
    }

    func snapshot() -> TokenSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Write what has not been written. For quitting, when the next timed
    /// save will never come.
    func flush() {
        queue.sync { if dirty { save(now: Date()) } }
    }

    /// One whole pass, synchronously.
    func pass(_ claims: [Claim], alive: Set<TokenOwner>, now: Date) -> TokenSnapshot {
        if !loaded {
            load()
            loaded = true
        }

        // The logs each running agent has now. The first claim on a log wins:
        // two agents should never be handed the same one, and counting it
        // under both would be counting it twice.
        var wanted: [(claim: Claim, file: String)] = []
        var claimant: [String: Claim] = [:]
        for claim in claims where Self.counted.contains(claim.tool) {
            for file in sources(for: claim) where claimant[file] == nil {
                claimant[file] = claim
                wanted.append((claim, file))
            }
        }

        // Agents that have gone. What they wrote before going is still in the
        // log, so it is read before the record is closed. A log another agent
        // has since taken up — a session resumed while Corral was not running
        // — ends where that agent began rather than now, so the two never
        // cover the same stretch.
        for record in records.values where record.isOpen && !alive.contains(record.owner) {
            var until = now
            if let next = claimant[record.file], next.owner != record.owner {
                until = min(until, next.startedAt)
            }
            close(record.key, until: max(until, record.since))
        }

        var openByFile: [String: TokenOwner] = [:]
        var lastEnd: [String: Date] = [:]
        for record in records.values {
            if record.isOpen {
                openByFile[record.file] = record.owner
            } else if let until = record.until {
                lastEnd[record.file] = max(lastEnd[record.file] ?? .distantPast, until)
            }
        }

        // Sessions not seen before. A log already open is already counted —
        // by this agent, or by another that is still running and got to it
        // first. Either way, once.
        for (claim, file) in wanted where openByFile[file] == nil {
            let since = max(claim.startedAt, lastEnd[file] ?? .distantPast)
            let key = TokenRecord.key(file: file, since: since)
            guard records[key] == nil else { continue }
            records[key] = TokenRecord(
                tool: claim.tool, file: file, project: claim.project, owner: claim.owner,
                since: since, until: nil, subagents: 0, hours: HourlyTokens()
            )
            openByFile[file] = claim.owner
            dirty = true
        }

        for key in Array(records.keys) {
            guard let record = records[key], record.isOpen else { continue }
            count(key, record)
        }

        if dirty, now.timeIntervalSince(savedAt) >= saveInterval { save(now: now) }
        if snapshotIsStale {
            latest = TokenSnapshot(records: records.values)
            snapshotIsStale = false
        }
        return latest
    }

    // ─ Counting ─────────────────────────────────────────────────────────────

    private func count(_ key: String, _ record: TokenRecord) {
        let counter = counters[key] ?? makeCounter(for: record)
        counters[key] = counter
        let moved = counter.advance()
        // A record read back from disk is recounted from its log on its first
        // pass, whether or not the log has moved since.
        guard counter.found, moved || floors[key] != nil else { return }

        var updated = record
        updated.hours = counter.hours.atLeast(floors[key])
        updated.subagents = max(record.subagents, counter.subagents)
        if let project = counter.project { updated.project = project }
        if updated != record {
            records[key] = updated
            dirty = true
        }
    }

    private func close(_ key: String, until: Date) {
        guard var record = records[key] else { return }
        let counter = counters[key] ?? makeCounter(for: record)
        _ = counter.advance()
        // A log that has gone keeps the count it had.
        if counter.found {
            record.hours = counter.hours(before: until).atLeast(floors[key])
            record.subagents = max(record.subagents, counter.subagents)
            if let project = counter.project { record.project = project }
        }
        record.until = until
        records[key] = record
        counters[key] = nil
        floors[key] = nil
        dirty = true
    }

    private func makeCounter(for record: TokenRecord) -> TokenCounter {
        let url = URL(fileURLWithPath: record.file)
        switch record.tool {
        case .codex:
            return CodexTokenCounter(rollout: url, since: record.since)
        case .kiroCLI, .kiroCrew:
            return KiroTokenCounter(session: url, since: record.since)
        default:
            return ClaudeTokenCounter(transcript: url, since: record.since)
        }
    }

    /// The logs that belong to one agent.
    private func sources(for claim: Claim) -> [String] {
        var files = claim.source.map { [$0] } ?? []
        if claim.tool == .kiroCLI || claim.tool == .kiroCrew {
            // Kiro Crew runs several sessions at once, an engine each, and the
            // activity line can only describe one of them. The locks name them
            // all, and each is this agent's work.
            for url in KiroSessions.sessions(
                lockedBy: claim.pids, since: claim.startedAt, under: kiroRoot
            ) where !files.contains(url.path) {
                files.append(url.path)
            }
        }
        return files
    }

    // ─ Keeping it ───────────────────────────────────────────────────────────

    private struct LedgerFile: Codable {
        var version: Int
        var records: [TokenRecord]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store) else { return }
        if let header = try? JSONDecoder().decode(VersionOnly.self, from: data),
           header.version > Self.version {
            // Written by a newer Corral, in a shape this one may not fully
            // understand. It is the only copy of what was counted, so it is
            // left exactly as it is and this run keeps its count in memory.
            writable = false
            return
        }
        guard let file = try? JSONDecoder().decode(LedgerFile.self, from: data) else {
            // Not a ledger this version can read at all. Moved aside rather
            // than written over, so whatever it held can still be looked at.
            let aside = store.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: store, to: aside)
            return
        }
        absorb(file.records)
        stamp = modified(store)
    }

    /// Records read from disk, alongside whatever is already known.
    private func absorb(_ incoming: [TokenRecord]) {
        for record in incoming where records[record.key] == nil {
            records[record.key] = record
            if record.isOpen { floors[record.key] = record.hours }
        }
    }

    private func save(now: Date) {
        guard let store, writable else { return }

        // Another copy of Corral — a development build next to the installed
        // one — may have written since. Both count from the same logs and
        // arrive at the same records, so what it knows that this one does not
        // is added rather than written over.
        if let onDisk = modified(store), onDisk != stamp,
           let data = try? Data(contentsOf: store),
           let file = try? JSONDecoder().decode(LedgerFile.self, from: data),
           file.version <= Self.version {
            absorb(file.records)
        }

        let cutoff = now.addingTimeInterval(-Self.retention)
        records = records.filter { _, record in
            guard let until = record.until else { return true }
            return until >= cutoff
        }

        let file = LedgerFile(
            version: Self.version,
            records: records.values.sorted { ($0.since, $0.file) < ($1.since, $1.file) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard (try? data.write(to: store, options: .atomic)) != nil else { return }
        stamp = modified(store)
        savedAt = now
        dirty = false
    }

    private func modified(_ url: URL) -> Date? { FileStamp.of(url)?.modified }
}
