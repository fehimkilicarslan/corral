import XCTest
@testable import Corral

final class InsightsTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ minute: Int, day: Int = 20) -> String {
        String(format: "2026-10-%02dT%02d:%02d:00.000Z", day, 10 + minute / 60, minute % 60)
    }

    private func date(_ minute: Int, day: Int = 20) -> Date {
        ISO8601DateFormatter().date(from: String(at(minute, day: day).dropLast(5)) + "Z")!
    }

    // ─ Patterns ─────────────────────────────────────────────────────────────

    /// Turkish is typed with and without its letters; both must read alike.
    func testFoldingMakesTurkishLettersPlainASCII() {
        XCTAssertEqual(InsightPatterns.fold("TEŞEKKÜRLER"), "tesekkurler")
        XCTAssertEqual(InsightPatterns.fold("Işık"), "isik")
        XCTAssertEqual(InsightPatterns.fold("İyi çalışıyor"), "iyi calisiyor")
    }

    func testGratitudeInBothLanguages() {
        let thanks = ["Thanks!", "thank you, that works", "Teşekkürler", "tesekkur ederim", "sağol", "eyvallah"]
        for text in thanks {
            XCTAssertTrue(InsightPatterns.matches(InsightPatterns.gratitude, InsightPatterns.fold(text)), text)
        }
        XCTAssertFalse(InsightPatterns.matches(InsightPatterns.gratitude, "thanks to the cache this is fast"))
        XCTAssertFalse(InsightPatterns.matches(InsightPatterns.gratitude, "please fix the build"))
    }

    /// The short words count only at the start; "no" in the middle of a
    /// sentence, or "dur" inside "durum", is not steering.
    func testPushbackIsAnchoredForShortWords() {
        let yes = ["No, use the existing helper", "hayır öyle değil", "Dur, önce testleri çalıştır",
                   "wait — that deletes data", "bunun yerine cache kullan", "that's not what I asked"]
        for text in yes {
            XCTAssertTrue(InsightPatterns.matches(InsightPatterns.pushback, InsightPatterns.fold(text)), text)
        }
        let no = ["I have no idea why this fails", "durum nedir", "add a stop button"]
        for text in no {
            XCTAssertFalse(InsightPatterns.matches(InsightPatterns.pushback, InsightPatterns.fold(text)), text)
        }
    }

    func testChargedNeedsShoutingNotAcronyms() {
        XCTAssertTrue(InsightPatterns.isCharged("NEDEN HALA ÇALIŞMIYOR"))
        XCTAssertTrue(InsightPatterns.isCharged("stop touching that file!!"))
        XCTAssertTrue(InsightPatterns.isCharged("of ya yine mi"))
        XCTAssertFalse(InsightPatterns.isCharged("Fix the API so the JSON matches the UI"))
        XCTAssertFalse(InsightPatterns.isCharged(String(repeating: "WHY ", count: 100)))
    }

    func testTestSummariesFromEachRunner() {
        func run(_ text: String) -> [Int]? {
            InsightPatterns.testRun(in: text).map { [$0.passed, $0.failed] }
        }
        XCTAssertEqual(run("Executed 129 tests, with 2 failures (0 unexpected) in 1.2 (1.3) seconds"), [127, 2])
        XCTAssertEqual(run("✔ Test run with 45 tests in 7 suites passed after 0.3 seconds."), [45, 0])
        XCTAssertEqual(run("✘ Test run with 45 tests in 7 suites failed after 0.4 seconds with 3 issues."), [42, 3])
        XCTAssertEqual(run("===== 3 failed, 10 passed in 0.52s ====="), [10, 3])
        XCTAssertEqual(run("00:05 +129: All tests passed!"), [129, 0])
        XCTAssertEqual(run("Tests:       2 failed, 10 passed, 12 total"), [10, 2])
        XCTAssertEqual(run("test result: ok. 8 passed; 0 failed; 0 ignored"), [8, 0])
        XCTAssertNil(run("Build complete! (3.21s)"))
    }

    func testInstructionFilesAndPlans() {
        XCTAssertTrue(InsightPatterns.isAgentInstructions("/r/CLAUDE.md"))
        XCTAssertTrue(InsightPatterns.isAgentInstructions("/r/sub/AGENTS.md"))
        XCTAssertTrue(InsightPatterns.isAgentInstructions("/Users/a/.claude/skills/deploy/SKILL.md"))
        XCTAssertFalse(InsightPatterns.isAgentInstructions("/r/README.md"))
        XCTAssertTrue(InsightPatterns.isPlanFile("/r/plans/insights.md"))
        XCTAssertTrue(InsightPatterns.isPlanFile("/r/docs/migration-plan.md"))
        XCTAssertFalse(InsightPatterns.isPlanFile("/r/.claude/skills/plan/plan.md"))
    }

    func testShortPromptKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            FactsBuilder.shortPromptKey(InsightPatterns.fold("Devam et!")),
            FactsBuilder.shortPromptKey(InsightPatterns.fold("devam et"))
        )
        XCTAssertNil(FactsBuilder.shortPromptKey("ok"))
    }

    // ─ Claude Code ──────────────────────────────────────────────────────────

    private func user(_ text: Any, at minute: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var record: [String: Any] = [
            "type": "user", "timestamp": at(minute), "cwd": "/r",
            "message": ["role": "user", "content": text],
        ]
        record.merge(extra) { $1 }
        return record
    }

    private func result(_ id: String, _ text: String, error: Bool = false, at minute: Int) -> [String: Any] {
        user([["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]], at: minute)
    }

    private func assistant(_ blocks: [[String: Any]], at minute: Int, id: String = UUID().uuidString) -> [String: Any] {
        [
            "type": "assistant", "timestamp": at(minute),
            "message": ["id": id, "model": "claude-opus-5", "content": blocks],
        ]
    }

    private func bash(_ id: String, _ command: String) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]
    }

    private func claudeSession() -> SessionFacts {
        let records: [[String: Any]] = [
            user("Önce bir plan çıkaralım", at: 0, extra: ["permissionMode": "plan"]),
            assistant([["type": "text", "text": "İki seçenek var:\n1. **Cache**\n2. **Index**\nHangisini istersin?"]], at: 1, id: "m1"),
            assistant([["type": "text", "text": "(continued)"]], at: 1, id: "m1"),
            user("hayır, bunun yerine sorguyu düzeltelim", at: 2),
            assistant([bash("t1", "swift test")], at: 3),
            result("t1", "Executed 3 tests, with 0 failures (0 unexpected)", at: 4),
            assistant([["type": "tool_use", "id": "e1", "name": "Edit", "input": ["file_path": "/r/CLAUDE.md"]]], at: 5),
            assistant([bash("t2", "swift build")], at: 6),
            result("t2", "error: cannot find 'x' in scope", error: true, at: 7),
            assistant([bash("t3", "swift build")], at: 8),
            result("t3", "Build complete!", at: 9),
            assistant([bash("t4", "git commit -m \"fix query\"")], at: 10),
            result("t4", "[main abc1234] fix query\n 1 file changed", at: 11),
            assistant([["type": "tool_use", "id": "t5", "name": "Task", "input": ["run_in_background": true]]], at: 12),
            result("t5", "done", at: 13),
            user("[Request interrupted by user]", at: 14),
            user("<command-message>compact</command-message>\n<command-name>/compact</command-name>", at: 15),
            user("injected context", at: 16, extra: ["isMeta": true]),
            assistant([bash("t6", "rm -rf build")], at: 17),
            result("t6", "The user doesn't want to proceed with this tool use.", error: true, at: 18),
        ]
        var builder = FactsBuilder(tool: .claudeCode, calendar: utc)
        for record in records { ClaudeTranscript.absorb(record, into: &builder) }
        return builder.finish()
    }

    func testClaudeTranscriptCountsThePerson() {
        let facts = claudeSession()
        XCTAssertEqual(facts.project, "/r")
        XCTAssertEqual(facts.prompts, 2, "interrupts, slash commands and meta entries are not prompts")
        XCTAssertTrue(facts.planned)
        XCTAssertEqual(facts.interrupts, 1)
        XCTAssertEqual(facts.contextResets, 1)
        XCTAssertEqual(facts.declinedTools, 1)
        XCTAssertEqual(facts.pushback, 1)
        XCTAssertEqual(facts.promptHours[10], 2)
        XCTAssertEqual(facts.promptDays["2026-10-20"], 2)
    }

    func testClaudeTranscriptCountsTheAgent() {
        let facts = claudeSession()
        XCTAssertEqual(facts.models, ["claude-opus-5": 8], "one turn per message id")
        XCTAssertEqual(facts.proposals, 1)
        XCTAssertEqual(facts.answeredProposals, 1)
        XCTAssertEqual(facts.counterProposals, 1)
        XCTAssertEqual(facts.testRuns, 1)
        XCTAssertEqual(facts.testedBeforeEditing, true)
        XCTAssertEqual(facts.codifyEdits, 1)
        XCTAssertEqual(facts.errors, 1, "a declined call is not a failure")
        XCTAssertEqual(facts.blindRetries, 1)
        XCTAssertEqual(facts.recoverySteps.count, 1)
        XCTAssertEqual(facts.commitCommands, 1)
        XCTAssertEqual(facts.commitSHAs, ["abc1234"])
        XCTAssertEqual(facts.dispatches, 1)
        XCTAssertEqual(facts.backgroundDispatches, 1)
        XCTAssertEqual(facts.returnedDispatches, 1)
        XCTAssertEqual(facts.spans.count, 1)
        XCTAssertEqual(facts.activeSeconds, 18 * 60)
    }

    /// Picking one of the offered options is a decision, not pushback.
    func testChoosingAnOptionIsNotACounterProposal() {
        var builder = FactsBuilder(tool: .claudeCode, calendar: utc)
        for record in [
            assistant([["type": "text", "text": "Option A: rewrite. Option B: patch. Which option?"]], at: 0),
            user("no wait, option B", at: 1),
        ] { ClaudeTranscript.absorb(record, into: &builder) }
        let facts = builder.finish()
        XCTAssertEqual(facts.answeredProposals, 1)
        XCTAssertEqual(facts.counterProposals, 0)
    }

    func testSidechainEntriesAreNotTheMainSession() {
        var builder = FactsBuilder(tool: .claudeCode, calendar: utc)
        ClaudeTranscript.absorb(user("subagent prompt", at: 0, extra: ["isSidechain": true]), into: &builder)
        XCTAssertNil(builder.finish().start)
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    private func codex(_ type: String, _ payload: [String: Any], at minute: Int) -> [String: Any] {
        ["type": type, "timestamp": at(minute), "payload": payload]
    }

    func testCodexRolloutReadsPromptsCommandsAndAborts() {
        let records: [[String: Any]] = [
            codex("session_meta", ["originator": "codex_cli_rs", "cwd": "/c"], at: 0),
            codex("turn_context", ["model": "gpt-5.6", "turn_id": "u1", "cwd": "/c"], at: 0),
            codex("response_item", ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "<environment_context>cwd</environment_context>"],
                ["type": "input_text", "text": "testleri çalıştır lütfen"],
            ]], at: 1),
            codex("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "c1",
                                    "input": #"const r = await tools.exec_command({cmd:"git commit -m \"x\""})"#], at: 2),
            codex("response_item", ["type": "custom_tool_call_output", "call_id": "c1",
                                    "output": "Script completed\nOutput:\n[main 1234abc] x"], at: 3),
            codex("response_item", ["type": "function_call", "name": "shell", "call_id": "c2",
                                    "arguments": #"{"command":["bash","-lc","pytest -q"]}"#], at: 4),
            codex("response_item", ["type": "function_call_output", "call_id": "c2", "output": "5 passed in 0.1s"], at: 5),
            codex("response_item", ["type": "function_call", "name": "shell", "call_id": "c3",
                                    "arguments": #"{"cmd":"make"}"#], at: 6),
            codex("response_item", ["type": "function_call_output", "call_id": "c3",
                                    "output": #"{"output":"boom","metadata":{"exit_code":2}}"#], at: 7),
            codex("event_msg", ["type": "turn_aborted"], at: 8),
        ]
        var builder = FactsBuilder(tool: .codex, calendar: utc)
        var last: String?
        for record in records { XCTAssertTrue(CodexRollout.absorb(record, into: &builder, lastPrompt: &last)) }
        let facts = builder.finish()
        XCTAssertEqual(facts.project, "/c")
        XCTAssertEqual(facts.prompts, 1)
        XCTAssertEqual(facts.verifyAsks, 1)
        XCTAssertEqual(facts.commitCommands, 1)
        XCTAssertEqual(facts.commitSHAs, ["1234abc"])
        XCTAssertEqual(facts.testRuns, 1)
        XCTAssertEqual(facts.errors, 1)
        XCTAssertEqual(facts.interrupts, 1)
        XCTAssertEqual(facts.models, ["gpt-5.6": 1])
    }

    /// A Codex session another agent started is that agent's work.
    func testCodexRunByClaudeIsSkipped() {
        var builder = FactsBuilder(tool: .codex, calendar: utc)
        var last: String?
        XCTAssertFalse(CodexRollout.absorb(
            codex("session_meta", ["originator": "Claude Code"], at: 0), into: &builder, lastPrompt: &last
        ))
    }

    // ─ Report ───────────────────────────────────────────────────────────────

    func testOverlapAndTouchingSpans() {
        let spans = [
            SessionFacts.Span(start: date(0), end: date(10)),
            SessionFacts.Span(start: date(5), end: date(15)),
            SessionFacts.Span(start: date(15), end: date(30)),
        ]
        XCTAssertEqual(InsightReport.peakOverlap(spans), 2)
        XCTAssertEqual(InsightReport.peakOverlap([spans[0], spans[2]]), 1)
    }

    func testStreaksCountTodayOrYesterday() {
        let format = DateFormatter()
        format.calendar = utc
        format.timeZone = utc.timeZone
        format.dateFormat = "yyyy-MM-dd"
        let days: Set<String> = ["2026-10-20", "2026-10-21", "2026-10-22", "2026-10-25", "2026-10-26"]
        let streaks = InsightReport.streaks(days, today: date(0, day: 27), format: format, calendar: utc)
        XCTAssertEqual(streaks.longest, 3)
        XCTAssertEqual(streaks.current, 2, "a streak survives a day that is not over yet")
    }

    func testCommitsBelongToTheSessionAtWork() {
        var facts = SessionFacts(tool: .claudeCode)
        facts.project = "/r/app"
        facts.start = date(0)
        facts.end = date(60)
        facts.spans = [.init(start: date(0), end: date(60))]
        facts.commitSHAs = ["eeeeeee"]
        facts.promptWords = [4]
        func commit(_ sha: String, _ minute: Int, _ subject: String) -> CommitFact {
            CommitFact(sha: sha + "000", at: date(minute), email: "me@x", subject: subject, added: 10, deleted: 2, files: 1)
        }
        let scan = InsightStore.Scan(
            facts: [facts],
            commits: ["/r": [
                commit("aaaaaaa", 30, "feat: during"),
                commit("bbbbbbb", 65, "fix: just after"),
                commit("ccccccc", 200, "later, alone"),
                commit("eeeeeee", 300, "recorded by hash"),
            ]],
            roots: ["/r/app": "/r"]
        )
        let report = InsightReport.build(scan, days: 30, now: date(400), calendar: utc)
        XCTAssertEqual(report.commits, 4)
        XCTAssertEqual(report.assistedCommits, 3)
        XCTAssertEqual(report.linesAdded, 40)
        XCTAssertEqual(report.conventionalShare, 0.5)
        XCTAssertTrue(report.gitAvailable)
    }

    func testGitLogParsing() {
        let log = "\u{1e}abc\u{1f}2026-10-20T10:00:00+03:00\u{1f}Me@X.com\u{1f}feat: one\n\n3\t1\ta.swift\n-\t-\tlogo.png\n"
            + "\u{1e}def\u{1f}2026-10-21T10:00:00+03:00\u{1f}me@x.com\u{1f}chore\n"
        let commits = GitHistory.parse(log: log)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].email, "me@x.com")
        XCTAssertEqual(commits[0].added, 3)
        XCTAssertEqual(commits[0].files, 2)
        XCTAssertEqual(commits[1].subject, "chore")
    }

    // ─ Badges ───────────────────────────────────────────────────────────────

    private func report(_ edit: (inout InsightReport) -> Void) -> InsightReport {
        var report = InsightReport(days: 30, since: date(0))
        edit(&report)
        return report
    }

    func testTiersAndLowerIsBetter() {
        let badges = BadgeCatalog.evaluate(report {
            $0.sessions = 10
            $0.plannedShare = 0.4
            $0.errors = 30
            $0.blindRetryShare = 0.05
        })
        let plan = badges.first { $0.id == "plan" }!
        XCTAssertEqual(plan.tier, .silver)
        XCTAssertEqual(plan.next, "Gold at 60%")
        let calm = badges.first { $0.id == "calm" }!
        XCTAssertEqual(calm.tier, .silver)
    }

    /// Too little to judge is not the same as zero.
    func testTooLittleDataStaysLockedWithoutAValue() {
        let badges = BadgeCatalog.evaluate(report { $0.sessions = 2; $0.plannedShare = 1 })
        let plan = badges.first { $0.id == "plan" }!
        XCTAssertEqual(plan.tier, .locked)
        XCTAssertNil(plan.value)
        XCTAssertFalse(plan.hasData)
    }

    func testArchetypeFollowsTheStrongestGroup() {
        let architect = BadgeCatalog.evaluate(report {
            $0.sessions = 20
            $0.plannedShare = 0.7
            $0.codifySessions = 12
            $0.testedSessions = 10
            $0.testFirstShare = 0.5
        })
        XCTAssertEqual(ArchetypeCatalog.pick(architect).title, "The Architect")
        XCTAssertEqual(ArchetypeCatalog.pick(BadgeCatalog.evaluate(report { _ in })), ArchetypeCatalog.explorer)
    }

    func testEarnedIsBestFirst() {
        let badges = BadgeCatalog.evaluate(report {
            $0.sessions = 20
            $0.plannedShare = 0.2
            $0.peakParallel = 6
        })
        let earned = BadgeCatalog.earned(badges)
        XCTAssertEqual(earned.first?.id, "conductor")
        XCTAssertTrue(earned.contains { $0.id == "plan" })
    }

    // ─ Sharing ──────────────────────────────────────────────────────────────

    func testPostFitsInATweet() {
        let full = report {
            $0.sessions = 120
            $0.activeHours = 431
            $0.gitAvailable = true
            $0.assistedCommits = 870
            $0.plannedShare = 0.7
            $0.peakParallel = 6
            $0.dispatches = 400
        }
        let badges = BadgeCatalog.evaluate(full)
        let text = ShareText.post(report: full, archetype: ArchetypeCatalog.pick(badges), badges: badges)
        XCTAssertLessThanOrEqual(text.count, 280)
        XCTAssertFalse(text.contains("/r"), "no paths on anything that leaves the Mac")
        XCTAssertNotNil(ShareText.xIntent(text))
    }

    func testReadmeBadgeEscapesItsText() {
        let svg = ShareText.readmeBadge(
            archetype: Archetype(title: "Q&A <Lead>", symbol: "x", line: ""), earned: 1
        )
        XCTAssertTrue(svg.contains("Q&amp;A &lt;Lead&gt; · 1 badge<"))
        XCTAssertFalse(svg.contains("<Lead>"))
    }

    // ─ Store ────────────────────────────────────────────────────────────────

    /// Main transcripts are read; a subagent's own log is not, and a second
    /// scan of unchanged files comes from the cache.
    func testStoreReadsMainTranscriptsAndCaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/-r")
        let subagents = project.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        let now = Date()
        let iso = ISO8601DateFormatter()
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "user", "timestamp": iso.string(from: now), "cwd": "/r",
            "message": ["role": "user", "content": "merhaba, testleri çalıştır"],
        ])
        try line.write(to: project.appendingPathComponent("s1.jsonl"))
        try line.write(to: subagents.appendingPathComponent("agent-1.jsonl"))

        let cache = root.appendingPathComponent("insights.json")
        let store = InsightStore(
            store: cache,
            claudeRoot: root.appendingPathComponent("projects"),
            codexRoot: root.appendingPathComponent("codex"),
            readsGit: false
        )
        let first = store.scan(now: now)
        XCTAssertEqual(first.facts.count, 1)
        XCTAssertEqual(first.facts.first?.verifyAsks, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let cached = try String(contentsOf: cache)
        XCTAssertFalse(cached.contains("merhaba"), "the cache keeps counts, never what was said")
        XCTAssertEqual(store.scan(now: now).facts, first.facts)
    }
}
