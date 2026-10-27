import CryptoKit
import Foundation

/// What one session did, as numbers.
///
/// The unit Insights keeps. A transcript is read once, in full, and reduced to
/// this — counts, times and file-free flags — and the transcript itself is
/// never copied anywhere. The one exception is a short prompt, which is kept as
/// a hash so that the same "make it pass" sent forty times can be recognised
/// as the same prompt without the prompt being written down.
struct SessionFacts: Codable, Equatable {

    /// A stretch of activity: consecutive entries no more than
    /// `FactsBuilder.spanGap` apart.
    struct Span: Codable, Equatable {
        var start: Date
        var end: Date
    }

    var tool: Tool
    /// The working directory the session ran in.
    var project: String?
    var start: Date?
    var end: Date?
    var spans: [Span] = []

    // The person.
    var prompts = 0
    /// Words per prompt, one entry each, for medians and shares.
    var promptWords: [Int] = []
    /// Prompts by local hour, 0–23.
    var promptHours = [Int](repeating: 0, count: 24)
    /// Prompts by local day, `yyyy-MM-dd`.
    var promptDays: [String: Int] = [:]
    var interrupts = 0
    /// Tool calls the person declined when the agent asked.
    var declinedTools = 0
    var pushback = 0
    var verifyAsks = 0
    var gratitude = 0
    var charged = 0
    /// `/compact` and `/clear`, typed — not the automatic compaction.
    var contextResets = 0
    /// Plan mode, a plan file, or a plan accepted into a fresh session.
    var planned = false
    var shortPrompts: [String: Int] = [:]

    // The agent.
    var toolCalls = 0
    var edits = 0
    var dispatches = 0
    var backgroundDispatches = 0
    var returnedDispatches = 0
    var commitCommands = 0
    var commitSHAs: [String] = []
    var testRuns = 0
    var failingTestRuns = 0
    /// Whether the first test run came before the first edit. Nil when the
    /// session did not do both.
    var testedBeforeEditing: Bool?
    var errors = 0
    /// Failed commands run again, unchanged, within the next few steps.
    var blindRetries = 0
    /// For each failure, how many steps it took to reach a passing test run
    /// or a commit.
    var recoverySteps: [Int] = []
    var codifyEdits = 0
    /// Agent turns per model.
    var models: [String: Int] = [:]

    // Exchanges.
    /// Replies in which the agent offered options or asked for a decision.
    var proposals = 0
    /// Of those, the ones the person answered directly.
    var answeredProposals = 0
    /// Answers that turned every offered option down.
    var counterProposals = 0

    var activeSeconds: TimeInterval {
        spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}

/// Reduces a stream of transcript events to `SessionFacts`.
///
/// The readers below know each tool's file format and nothing about habits;
/// this knows habits and nothing about formats. Most of what it works out —
/// whether a failure was retried blindly, whether a test came first — depends
/// on order, so it keeps a slim event list while it reads and settles those at
/// the end.
struct FactsBuilder {

    /// Entries further apart than this belong to separate stretches of work.
    /// Fifteen minutes: longer than any one tool call takes, shorter than a
    /// lunch break.
    static let spanGap: TimeInterval = 15 * 60

    /// How far ahead a failure's retry, or a proposal's answer, may land and
    /// still count as the reaction to it.
    static let retryWindow = 5
    static let answerWindow = 3

    private enum Event {
        case prompt(folded: String)
        case proposal(options: Bool)
        case command(String)
        case commit
        case test(passed: Int, failed: Int)
        case failure(command: String?)
        case edit(plan: Bool)
    }

    private(set) var facts: SessionFacts
    private let calendar: Calendar
    private let dayFormat: DateFormatter
    private var stamps: [Date] = []
    private var events: [Event] = []
    private var commands: [String: String] = [:]
    private var commitCalls: Set<String> = []
    private var dispatched: Set<String> = []
    private var returned: Set<String> = []
    private var countedTurns: Set<String> = []

    init(tool: Tool, calendar: Calendar = .current) {
        facts = SessionFacts(tool: tool)
        self.calendar = calendar
        dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
    }

    mutating func project(_ path: String?) {
        if facts.project == nil, let path, !path.isEmpty { facts.project = path }
    }

    mutating func stamp(_ date: Date?) {
        if let date { stamps.append(date) }
    }

    // ─ The person ───────────────────────────────────────────────────────────

    /// Something the person typed. The reader has already set aside what the
    /// tool injected — reminders, command echoes, compaction summaries.
    mutating func prompt(_ raw: String, at date: Date?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let folded = InsightPatterns.fold(String(text.prefix(20_000)))
        let words = text.split(whereSeparator: \.isWhitespace).count

        facts.prompts += 1
        facts.promptWords.append(words)
        if let date {
            facts.promptHours[calendar.component(.hour, from: date)] += 1
            facts.promptDays[dayFormat.string(from: date), default: 0] += 1
        }
        if InsightPatterns.matches(InsightPatterns.gratitude, folded) { facts.gratitude += 1 }
        if InsightPatterns.matches(InsightPatterns.pushback, folded) { facts.pushback += 1 }
        if InsightPatterns.matches(InsightPatterns.verifyAsk, folded) { facts.verifyAsks += 1 }
        if InsightPatterns.isCharged(text) { facts.charged += 1 }
        if (1...8).contains(words), let key = Self.shortPromptKey(folded) {
            facts.shortPrompts[key, default: 0] += 1
        }
        events.append(.prompt(folded: folded))
    }

    mutating func interrupted() { facts.interrupts += 1 }
    mutating func declinedTool() { facts.declinedTools += 1 }
    mutating func contextReset() { facts.contextResets += 1 }
    mutating func planned() { facts.planned = true }

    /// A short prompt reduced to a stable key: folded, punctuation gone,
    /// hashed. Two characters or fewer is not a phrase.
    static func shortPromptKey(_ folded: String) -> String? {
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let normal = String(words).split(separator: " ").joined(separator: " ")
        guard normal.count > 2 else { return nil }
        let digest = SHA256.hash(data: Data(normal.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // ─ The agent ────────────────────────────────────────────────────────────

    mutating func model(_ name: String?, turn: String?) {
        guard let name, !name.isEmpty, name != "<synthetic>" else { return }
        if let turn {
            guard countedTurns.insert(turn).inserted else { return }
        }
        facts.models[name, default: 0] += 1
    }

    /// Prose from the agent. Only what it asks matters here.
    mutating func reply(_ text: String) {
        let folded = InsightPatterns.fold(String(text.suffix(4_000)))
        if InsightPatterns.matches(InsightPatterns.agentOptions, folded) {
            events.append(.proposal(options: true))
        } else if InsightPatterns.matches(InsightPatterns.agentQuestion, folded) {
            events.append(.proposal(options: false))
        }
    }

    mutating func command(id: String?, _ text: String) {
        facts.toolCalls += 1
        if InsightPatterns.matches(InsightPatterns.commitCommand, text) {
            facts.commitCommands += 1
            if let id { commitCalls.insert(id) }
            events.append(.commit)
        } else {
            events.append(.command(text))
        }
        if let id { commands[id] = text }
    }

    mutating func edit(paths: [String]) {
        facts.toolCalls += 1
        facts.edits += 1
        let plan = !paths.isEmpty && paths.allSatisfy(InsightPatterns.isPlanFile)
        if plan { facts.planned = true }
        if paths.contains(where: InsightPatterns.isAgentInstructions) { facts.codifyEdits += 1 }
        events.append(.edit(plan: plan))
    }

    mutating func dispatch(id: String?, background: Bool) {
        facts.toolCalls += 1
        facts.dispatches += 1
        if background { facts.backgroundDispatches += 1 }
        if let id { dispatched.insert(id) }
    }

    mutating func otherTool() { facts.toolCalls += 1 }

    /// What came back from a tool call.
    mutating func result(for id: String?, output: String, failed: Bool) {
        if let id, dispatched.contains(id), returned.insert(id).inserted {
            facts.returnedDispatches += 1
        }
        guard let id, let command = commands[id] else {
            if failed { record(failure: nil) }
            return
        }
        if commitCalls.contains(id),
           let sha = InsightPatterns.capture(InsightPatterns.commitOutput, String(output.prefix(2_000))) {
            facts.commitSHAs.append(String(sha.prefix(7)))
        }
        if let run = InsightPatterns.testRun(in: output) {
            facts.testRuns += 1
            if run.failed > 0 { facts.failingTestRuns += 1 }
            events.append(.test(passed: run.passed, failed: run.failed))
        } else if failed {
            record(failure: command)
        }
    }

    private mutating func record(failure command: String?) {
        facts.errors += 1
        events.append(.failure(command: command))
    }

    // ─ Settling ─────────────────────────────────────────────────────────────

    func finish() -> SessionFacts {
        var facts = self.facts
        let sorted = stamps.sorted()
        facts.start = sorted.first
        facts.end = sorted.last
        facts.spans = Self.spans(sorted)

        var firstTest: Int?, firstEdit: Int?
        for (i, event) in events.enumerated() {
            switch event {
            case .test: if firstTest == nil { firstTest = i }
            case .edit(let plan): if !plan, firstEdit == nil { firstEdit = i }
            default: break
            }
        }
        if let firstTest, let firstEdit { facts.testedBeforeEditing = firstTest < firstEdit }

        for (i, event) in events.enumerated() {
            switch event {
            case .failure(let command):
                let ahead = events[(i + 1)...]
                if let fixed = ahead.firstIndex(where: {
                    if case .commit = $0 { return true }
                    if case .test(let passed, let failed) = $0 { return passed > 0 && failed == 0 }
                    return false
                }) {
                    facts.recoverySteps.append(fixed - i)
                }
                if let command, ahead.prefix(Self.retryWindow).contains(where: {
                    if case .command(let again) = $0 { return again == command }
                    return false
                }) {
                    facts.blindRetries += 1
                }

            case .proposal(let options):
                facts.proposals += 1
                for next in events[(i + 1)...].prefix(Self.answerWindow) {
                    if case .proposal = next { break }
                    if case .prompt(let folded) = next {
                        facts.answeredProposals += 1
                        if options,
                           InsightPatterns.matches(InsightPatterns.pushback, folded),
                           !InsightPatterns.matches(InsightPatterns.optionReference, folded) {
                            facts.counterProposals += 1
                        }
                        break
                    }
                }

            default:
                break
            }
        }
        return facts
    }

    static func spans(_ sorted: [Date]) -> [SessionFacts.Span] {
        guard var start = sorted.first else { return [] }
        var spans: [SessionFacts.Span] = []
        var previous = start
        for date in sorted.dropFirst() {
            if date.timeIntervalSince(previous) > spanGap {
                spans.append(.init(start: start, end: previous))
                start = date
            }
            previous = date
        }
        spans.append(.init(start: start, end: previous))
        return spans
    }
}

// ─ Claude Code ──────────────────────────────────────────────────────────────

/// Reads a Claude Code transcript, `~/.claude/projects/<project>/<session>.jsonl`.
///
/// Main transcripts only. A subagent's own log is the agent talking to itself;
/// what matters about it — that it was started, and whether it came back — is
/// in the main transcript, as a Task call and its result.
enum ClaudeTranscript {

    static func read(_ url: URL, calendar: Calendar = .current) -> SessionFacts? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var builder = FactsBuilder(tool: .claudeCode, calendar: calendar)
        for line in FileTail.split(data) where !line.isEmpty {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            absorb(record, into: &builder)
        }
        let facts = builder.finish()
        return facts.start == nil ? nil : facts
    }

    /// What Claude Code puts in the user's turn that the user did not type.
    private static let injected = [
        "<system-reminder", "<system_instruction", "<local-command-caveat", "<local-command-stdout",
        "<local-command-stderr", "<command-name", "<command-message", "<command-args", "<bash-input",
        "<bash-stdout", "<bash-stderr", "<task-notification", "<user-memory-input",
        "Caveat: The messages below", "Base directory for this skill:", "<!-- AUTO-GENERATED",
        "This session is being continued",
    ]
    private static let slashCommand = try? NSRegularExpression(pattern: "<command-name>(/[\\w:-]+)</command-name>")

    static func absorb(_ record: [String: Any], into builder: inout FactsBuilder) {
        let kind = record["type"] as? String
        guard kind == "user" || kind == "assistant",
              record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any]
        else { return }
        let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        builder.stamp(at)
        builder.project(record["cwd"] as? String)
        if record["permissionMode"] as? String == "plan" { builder.planned() }

        if kind == "assistant" {
            builder.model(message["model"] as? String, turn: message["id"] as? String)
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text": builder.reply(block["text"] as? String ?? "")
                case "tool_use": tool(block, into: &builder)
                default: break
                }
            }
            return
        }

        // The user's side carries what they typed and what every tool returned.
        var typed: [String] = []
        if let text = message["content"] as? String {
            typed.append(text)
        } else {
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    typed.append(block["text"] as? String ?? "")
                case "tool_result":
                    let output = text(of: block["content"])
                    // A call the person turned down comes back as an error,
                    // but nothing failed: it is steering, and counted as such.
                    let declined = output.hasPrefix("The user doesn't want to")
                    if declined { builder.declinedTool() }
                    builder.result(
                        for: block["tool_use_id"] as? String,
                        output: output,
                        failed: block["is_error"] as? Bool == true && !declined
                    )
                default:
                    break
                }
            }
        }
        guard record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true else { return }
        for text in typed {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = slashCommand,
               let name = InsightPatterns.capture(slash, trimmed),
               name == "/compact" || name == "/clear" {
                builder.contextReset()
            }
            if trimmed.hasPrefix("[Request interrupted by user") {
                builder.interrupted()
            } else if injected.contains(where: trimmed.hasPrefix) {
                continue
            } else {
                // A plan accepted into a clean context arrives as a prompt.
                if trimmed.hasPrefix("Implement the following plan") { builder.planned() }
                builder.prompt(trimmed, at: at)
            }
        }
    }

    private static func tool(_ block: [String: Any], into builder: inout FactsBuilder) {
        let id = block["id"] as? String
        let input = block["input"] as? [String: Any] ?? [:]
        switch block["name"] as? String ?? "" {
        case "Bash":
            builder.command(id: id, input["command"] as? String ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] ?? input["notebook_path"]) as? String
            builder.edit(paths: path.map { [$0] } ?? [])
        case "Task", "Agent":
            builder.dispatch(id: id, background: input["run_in_background"] as? Bool == true)
        case "EnterPlanMode", "ExitPlanMode":
            builder.planned()
            builder.otherTool()
        default:
            builder.otherTool()
        }
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

// ─ Codex ────────────────────────────────────────────────────────────────────

/// Reads a Codex rollout, `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl`.
///
/// Codex has changed its record shapes more than once, and its newest one runs
/// commands from a small script (`tools.exec_command({cmd: …})`) rather than
/// naming them, so this reads the parts that hold still — what the person
/// typed, what the agent asked, which commands ran and whether they failed —
/// and leaves the rest. A session Codex ran on behalf of another agent is
/// skipped: its prompts were written by that agent.
enum CodexRollout {

    static func read(_ url: URL, calendar: Calendar = .current) -> SessionFacts? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var builder = FactsBuilder(tool: .codex, calendar: calendar)
        var lastPrompt: String?
        for line in FileTail.split(data) where !line.isEmpty {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if !absorb(record, into: &builder, lastPrompt: &lastPrompt) { return nil }
        }
        let facts = builder.finish()
        return facts.start == nil ? nil : facts
    }

    /// What Codex adds to the user's turn on its own.
    private static let injected = ["<", "# AGENTS.md", "You are Codex"]
    private static let scriptCommand = try? NSRegularExpression(
        pattern: #"\b(?:cmd|command)"?\s*:\s*"((?:[^"\\]|\\.)*)""#
    )
    private static let patchFile = try? NSRegularExpression(
        pattern: #"\*\*\* (?:Add|Update|Delete) File: ([^\n\\"]+)"#
    )

    /// The command line a tool call ran, from whichever shape it came in:
    /// JSON arguments (`cmd`, or `command` as a string or an argv), a local
    /// shell action, or the `cmd:` of a script.
    static func command(in body: String, payload: [String: Any]) -> String? {
        if body.hasPrefix("{"),
           let args = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            if let cmd = args["cmd"] as? String { return cmd }
            if let cmd = args["command"] as? String { return cmd }
            if let argv = args["command"] as? [String] { return argv.joined(separator: " ") }
        }
        if let action = payload["action"] as? [String: Any], let argv = action["command"] as? [String] {
            return argv.joined(separator: " ")
        }
        if let script = scriptCommand, let cmd = InsightPatterns.capture(script, body) {
            return cmd.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    /// False when the rollout turns out not to be the person's own session.
    static func absorb(
        _ record: [String: Any],
        into builder: inout FactsBuilder,
        lastPrompt: inout String?
    ) -> Bool {
        let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        let payload = record["payload"] as? [String: Any] ?? [:]

        switch record["type"] as? String {
        case "session_meta":
            let origin = (payload["originator"] as? String ?? "").lowercased()
            if origin.contains("claude") || origin.contains("cursor") { return false }
            builder.project(payload["cwd"] as? String)
            return true
        case "turn_context":
            builder.project(payload["cwd"] as? String)
            builder.model(payload["model"] as? String, turn: payload["turn_id"] as? String)
            if let mode = payload["collaboration_mode"] as? [String: Any],
               (mode["mode"] as? String)?.lowercased() == "plan" {
                builder.planned()
            }
            return true
        case "event_msg":
            if payload["type"] as? String == "turn_aborted" { builder.interrupted() }
            return true
        case "response_item":
            break
        default:
            return true
        }

        builder.stamp(at)
        switch payload["type"] as? String {
        case "message":
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            switch payload["role"] as? String {
            case "user":
                for text in texts {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !injected.contains(where: trimmed.hasPrefix),
                          trimmed != lastPrompt
                    else { continue }
                    lastPrompt = trimmed
                    builder.prompt(trimmed, at: at)
                }
            case "assistant":
                texts.forEach { builder.reply($0) }
            default:
                break
            }

        case "function_call", "custom_tool_call", "local_shell_call":
            let id = payload["call_id"] as? String
            let body = (payload["arguments"] ?? payload["input"]) as? String ?? ""
            if let patch = patchFile {
                let paths = patch.matches(in: body, range: NSRange(body.startIndex..., in: body))
                    .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
                if !paths.isEmpty {
                    builder.edit(paths: paths)
                    return true
                }
            }
            if let line = Self.command(in: body, payload: payload) {
                builder.command(id: id, line)
            } else {
                builder.otherTool()
            }

        case "function_call_output", "custom_tool_call_output":
            let output: String
            if let text = payload["output"] as? String {
                output = text
            } else {
                output = ClaudeTranscript.text(of: payload["output"])
            }
            let failed = InsightPatterns.matches(InsightPatterns.codexFailure, String(output.prefix(4_000)))
            builder.result(for: payload["call_id"] as? String, output: output, failed: failed)

        default:
            break
        }
        return true
    }
}
