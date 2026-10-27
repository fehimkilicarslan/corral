import Foundation

// ─ Git ──────────────────────────────────────────────────────────────────────

/// One commit, as `git log --numstat` describes it.
struct CommitFact: Codable, Equatable {
    var sha: String
    var at: Date
    var email: String
    var subject: String
    var added: Int
    var deleted: Int
    var files: Int
}

/// The commits made in the repositories the sessions ran in.
///
/// A transcript records the `git commit` an agent ran, but not reliably what
/// came of it: a hook that compresses git's output — common enough that it is
/// on the machine this was written on — leaves no hash to match. So the
/// repository is asked directly, and a commit belongs to a session when it was
/// made in that session's repository while the session was at work.
enum GitHistory {

    /// A git that runs without side effects.
    ///
    /// Not `/usr/bin/git`: on a Mac without developer tools that is a shim
    /// that opens an "install the command line tools" dialog, which is not
    /// something a background scan gets to do. The real binaries are looked
    /// for where Homebrew, the command line tools and Xcode put them; with
    /// none of them, Insights goes without commits.
    static let executable: URL? = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    static func root(of directory: String) -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let out = run(["-C", directory, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }

    static func userEmail(in root: String) -> String? {
        let out = run(["-C", root, "config", "user.email"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out?.lowercased() : nil
    }

    static func commits(in root: String, since: Date) -> [CommitFact] {
        let iso = ISO8601DateFormatter().string(from: since)
        guard let out = run([
            "-C", root, "log", "--since=\(iso)", "--no-merges",
            "--format=%x1e%H%x1f%aI%x1f%ae%x1f%s", "--numstat",
        ]) else { return [] }
        return parse(log: out)
    }

    /// Records split on the record separator `%x1e`, fields on the unit
    /// separator `%x1f` — characters no subject line contains — and each
    /// header followed by its numstat lines. A binary file's `-` counts as 0.
    static func parse(log: String) -> [CommitFact] {
        let iso = ISO8601DateFormatter()
        return log.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 4, let at = iso.date(from: String(fields[1])) else { return nil }
            var commit = CommitFact(
                sha: String(fields[0]), at: at, email: String(fields[2]).lowercased(),
                subject: fields[3...].joined(separator: " "), added: 0, deleted: 0, files: 0
            )
            for line in lines.dropFirst() {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                commit.added += Int(parts[0]) ?? 0
                commit.deleted += Int(parts[1]) ?? 0
                commit.files += 1
            }
            return commit
        }
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 30) -> String? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Reading only; never take the index lock from under an agent that is
        // committing in the same repository.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// ─ Store ────────────────────────────────────────────────────────────────────

/// Everything Insights has read, and what it found.
///
/// Reading three months of transcripts is a gigabyte on a busy machine, and
/// almost none of it changes between one look and the next. So each file's
/// facts are kept against its size and modification time, and a refresh reads
/// only the files that have grown. The cache lives next to the token ledger in
/// Application Support and, like the ledger, holds numbers and paths: the facts
/// above, never a line anyone wrote.
final class InsightStore {

    struct Scan {
        var facts: [SessionFacts]
        /// Your commits, by repository root.
        var commits: [String: [CommitFact]]
        /// The repository root each session's working directory is in.
        var roots: [String: String]
    }

    static let version = 1

    /// The longest range the window offers. Files untouched for longer are
    /// not read, and fall out of the cache.
    static let horizon: TimeInterval = 90 * 86_400

    static var defaultStore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corral/insights.json")
    }

    static var defaultClaudeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    private struct Entry: Codable {
        var size: UInt64
        var modified: Date
        var facts: SessionFacts?
    }

    /// Hours and days are local, so facts read in one time zone are not
    /// facts in another; a change of zone reads everything again.
    private struct CacheFile: Codable {
        var version: Int
        var timeZone: String
        var entries: [String: Entry]
    }

    private let store: URL?
    private let claudeRoot: URL
    private let codexRoot: URL
    private let readsGit: Bool

    init(
        store: URL? = InsightStore.defaultStore,
        claudeRoot: URL = InsightStore.defaultClaudeRoot,
        codexRoot: URL = CodexRollouts.defaultRoot,
        readsGit: Bool = true
    ) {
        self.store = store
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.readsGit = readsGit
    }

    /// Reads what changed and returns everything within the horizon.
    func scan(now: Date = Date(), calendar: Calendar = .current) -> Scan {
        let since = now.addingTimeInterval(-Self.horizon)
        let sources = Self.sources(claude: claudeRoot, codex: codexRoot, since: since)

        let zone = calendar.timeZone.identifier
        var cached = load()
        if cached?.version != Self.version || cached?.timeZone != zone { cached = nil }
        let previous = cached?.entries ?? [:]

        var entries: [String: Entry] = [:]
        var stale: [(URL, Tool, size: UInt64, modified: Date)] = []
        for (url, tool) in sources {
            guard let stamp = FileStamp.of(url) else { continue }
            if let hit = previous[url.path], hit.size == stamp.size, hit.modified == stamp.modified {
                entries[url.path] = hit
            } else {
                stale.append((url, tool, stamp.size, stamp.modified))
            }
        }

        // Each transcript is read on its own, so the slow part spreads across
        // every core rather than queueing behind the largest file.
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: stale.count) { i in
            let (url, tool, size, modified) = stale[i]
            let facts = tool == .codex
                ? CodexRollout.read(url, calendar: calendar)
                : ClaudeTranscript.read(url, calendar: calendar)
            lock.lock()
            entries[url.path] = Entry(size: size, modified: modified, facts: facts)
            lock.unlock()
        }
        if !stale.isEmpty || entries.count != previous.count {
            save(CacheFile(version: Self.version, timeZone: zone, entries: entries))
        }

        let facts = entries.values.compactMap(\.facts)
        guard readsGit else { return Scan(facts: facts, commits: [:], roots: [:]) }
        return Scan(facts: facts, commits: [:], roots: [:]).withCommits(since: since)
    }

    /// Main Claude transcripts sit directly in each project's folder; the
    /// folders beside them hold that session's subagents and tool output.
    static func sources(claude: URL, codex: URL, since: Date) -> [(URL, Tool)] {
        let manager = FileManager.default
        var found: [(URL, Tool)] = []
        let fresh: (URL) -> Bool = { url in
            guard let modified = FileStamp.of(url)?.modified else { return false }
            return modified >= since
        }
        for project in (try? manager.contentsOfDirectory(
            at: claude, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? [] {
            for file in (try? manager.contentsOfDirectory(
                at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? [] where file.pathExtension == "jsonl" && fresh(file) {
                found.append((file, .claudeCode))
            }
        }
        if let walker = manager.enumerator(at: codex, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let file as URL in walker
            where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") && fresh(file) {
                found.append((file, .codex))
            }
        }
        return found
    }

    private func load() -> CacheFile? {
        guard let store, let data = try? Data(contentsOf: store) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CacheFile.self, from: data)
    }

    private func save(_ file: CacheFile) {
        guard let store else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: store, options: .atomic)
    }
}

extension InsightStore.Scan {

    /// The same scan, with the commits of every repository a session ran in.
    ///
    /// Only your own commits: those under the repository's configured email,
    /// plus any whose hash a session's transcript recorded. Agents running
    /// locally commit under your name, so this is your work with them and not
    /// a teammate's that you pulled.
    func withCommits(since: Date) -> InsightStore.Scan {
        var roots: [String: String] = [:]
        let lock = NSLock()
        let projects = Array(Set(facts.compactMap(\.project)))
        DispatchQueue.concurrentPerform(iterations: projects.count) { i in
            guard let root = GitHistory.root(of: projects[i]) else { return }
            lock.lock()
            roots[projects[i]] = root
            lock.unlock()
        }

        let recorded = Set(facts.flatMap(\.commitSHAs))
        var commits: [String: [CommitFact]] = [:]
        let unique = Array(Set(roots.values))
        DispatchQueue.concurrentPerform(iterations: unique.count) { i in
            let root = unique[i]
            let email = GitHistory.userEmail(in: root)
            let mine = GitHistory.commits(in: root, since: since).filter { commit in
                commit.email == email || recorded.contains(String(commit.sha.prefix(7)))
            }
            lock.lock()
            commits[root] = mine
            lock.unlock()
        }
        return InsightStore.Scan(facts: facts, commits: commits, roots: roots)
    }
}
