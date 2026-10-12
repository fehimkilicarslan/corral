import XCTest
@testable import Corral

// ─ Fixtures ─────────────────────────────────────────────────────────────────

private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func json(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func claude(
    _ id: String, _ when: Date,
    input: Int = 0, write: Int = 0, read: Int = 0, output: Int
) -> String {
    json([
        "type": "assistant",
        "timestamp": iso(when),
        "cwd": "/proj",
        "message": [
            "id": id,
            "model": "claude-opus-5",
            "content": [],
            "usage": [
                "input_tokens": input,
                "cache_creation_input_tokens": write,
                "cache_read_input_tokens": read,
                "output_tokens": output,
            ],
        ],
    ])
}

private func codex(
    _ when: Date,
    total: (input: Int, cached: Int, output: Int),
    last: (input: Int, cached: Int, output: Int)
) -> String {
    func usage(_ u: (input: Int, cached: Int, output: Int)) -> [String: Any] {
        [
            "input_tokens": u.input, "cached_input_tokens": u.cached,
            "output_tokens": u.output, "total_tokens": u.input + u.output,
        ]
    }
    return json([
        "timestamp": iso(when),
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "total_token_usage": usage(total),
                "last_token_usage": usage(last),
                "model_context_window": 258_400,
            ],
        ],
    ])
}

private func kiroSession(id: String, cwd: String, turns: [(Date, Double)]) -> String {
    json([
        "session_id": id,
        "cwd": cwd,
        "updated_at": iso(turns.last?.0 ?? base),
        "session_state": [
            "conversation_metadata": [
                "user_turn_metadatas": turns.map { when, credits -> [String: Any] in
                    [
                        "end_timestamp": iso(when),
                        "model": "auto",
                        "metering_usage": [["unit": "credit", "value": credits]],
                        "input_token_count": 0,
                        "output_token_count": 0,
                    ]
                },
            ],
        ],
    ])
}

private extension TokenCount {
    /// The four token figures and credits, without what they were priced at —
    /// for the tests that are about counting, not pricing.
    var tokensOnly: TokenCount {
        TokenCount(input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output, credits: credits)
    }
}

private extension XCTestCase {
    func temporaryFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corral-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func write(_ lines: [String], to url: URL, terminated: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let text = lines.joined(separator: "\n") + (terminated && !lines.isEmpty ? "\n" : "")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

// ─ The count itself ─────────────────────────────────────────────────────────

final class TokenCountTests: XCTestCase {

    func testTheFourPartsAddUpToTheTotal() {
        let count = TokenCount(input: 3, cacheWrite: 40, cacheRead: 500, output: 6)
        XCTAssertEqual(count.total, 549)
        XCTAssertFalse(count.isCredits)
        XCTAssertTrue(TokenCount(credits: 0.4).isCredits)
        XCTAssertTrue(TokenCount().isEmpty)
    }

    func testArithmeticIsPartByPart() {
        let a = TokenCount(input: 1, cacheWrite: 2, cacheRead: 3, output: 4, credits: 0.5)
        let b = TokenCount(input: 10, cacheWrite: 20, cacheRead: 30, output: 40, credits: 1)
        XCTAssertEqual(a + b, TokenCount(input: 11, cacheWrite: 22, cacheRead: 33, output: 44, credits: 1.5))
        XCTAssertEqual((a + b) - b, a)
        XCTAssertTrue((a - b).hasNegativePart)
    }

    func testItIsWrittenAsABareArrayAndReadBack() throws {
        let priced = TokenCount(input: 1, cacheWrite: 2, cacheRead: 3, output: 4, fullPrice: 27)
        let data = try JSONEncoder().encode(priced)
        XCTAssertEqual(String(data: data, encoding: .utf8), "[1,2,3,4,0,27]")
        XCTAssertEqual(try JSONDecoder().decode(TokenCount.self, from: data), priced)

        let billed = TokenCount(credits: 0.38)
        let back = try JSONDecoder().decode(TokenCount.self, from: JSONEncoder().encode(billed))
        XCTAssertEqual(back, billed)
    }

    func testCompactFiguresRoundWhereTheyLand() {
        XCTAssertEqual(TokenFormat.compact(980), "980")
        XCTAssertEqual(TokenFormat.compact(4_210), "4.2k")
        XCTAssertEqual(TokenFormat.compact(35_400), "35k")
        XCTAssertEqual(TokenFormat.compact(4_200_000), "4.2M")
        XCTAssertEqual(TokenFormat.compact(563_000_000), "563M")
        XCTAssertEqual(TokenFormat.compact(1_243_512_334), "1.24B")
        // Never a four-digit figure in the smaller unit.
        XCTAssertEqual(TokenFormat.compact(999_960_000), "1.00B")
        XCTAssertEqual(TokenFormat.compact(999_960), "1.0M")
        XCTAssertEqual(TokenFormat.compact(TokenCount(credits: 0.3814)), "0.38")
    }
}

final class HourlyTokensTests: XCTestCase {

    func testTurnsLandInTheHourTheyWereTaken() {
        var hours = HourlyTokens()
        hours.add(TokenCount(output: 5), at: at(10))
        hours.add(TokenCount(output: 7), at: at(20))
        hours.add(TokenCount(output: 100), at: at(4 * 3_600))
        XCTAssertEqual(hours[TokenHours.start(of: at(10))]?.output, 12)
        XCTAssertEqual(hours.total.output, 112)
        XCTAssertEqual(hours.total(from: TokenHours.start(of: at(4 * 3_600))).output, 100)

        hours.remove(TokenCount(output: 12), at: at(15))
        XCTAssertNil(hours[TokenHours.start(of: at(10))], "an emptied hour is gone, not zero")
    }

    func testRecentHoursAreTwentyFourConsecutiveOnes() {
        for zone in ["UTC", "Asia/Kolkata", "Europe/Istanbul"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let hours = TokenHours.recent(24, endingAt: at(1_234), calendar: calendar)
            XCTAssertEqual(hours.count, 24)
            XCTAssertEqual(hours.last, TokenHours.start(of: at(1_234), calendar: calendar))
            for (earlier, later) in zip(hours, hours.dropFirst()) {
                XCTAssertEqual(later - earlier, 3_600, zone)
            }
        }
    }

    /// In a zone half an hour off UTC, an hour starts at half past in UTC
    /// terms — the chart is read against the local clock.
    func testHoursAreLocalHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let start = TokenHours.start(of: at(0), calendar: calendar)
        XCTAssertEqual(start % 3_600, 1_800)
    }

    func testAFloorKeepsWhatALaterRecountLost() {
        let hour = TokenHours.start(of: at(0))
        let floor = HourlyTokens(byHour: [hour: TokenCount(output: 50)])
        let shrunk = HourlyTokens(byHour: [hour: TokenCount(output: 20)])
        let grown = HourlyTokens(byHour: [hour: TokenCount(output: 80)])
        XCTAssertEqual(shrunk.atLeast(floor)[hour]?.output, 50)
        XCTAssertEqual(grown.atLeast(floor)[hour]?.output, 80)
        XCTAssertEqual(grown.atLeast(nil), grown)
    }

    func testHoursAreKeyedByTheirStartOnDisk() throws {
        let hour = TokenHours.start(of: at(0))
        let hours = HourlyTokens(byHour: [hour: TokenCount(output: 9, fullPrice: 45)])
        let data = try JSONEncoder().encode(hours)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"\(hour)\":[0,0,0,9,0,45]}")
        XCTAssertEqual(try JSONDecoder().decode(HourlyTokens.self, from: data), hours)
    }
}

// ─ Reading each tool's logs ─────────────────────────────────────────────────

final class ClaudeTokenCounterTests: XCTestCase {

    /// The shape that makes Claude's transcripts hard to count: one message
    /// written several times, the output growing, only the last copy whole.
    func testARepeatedMessageCountsOnceAtItsLargest() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        try write([
            claude("old", at(-60), read: 1_000, output: 999),
            json(["type": "user", "timestamp": iso(at(5))]),
            claude("m1", at(10), input: 3, write: 100, read: 5_000, output: 4),
            claude("m1", at(11), input: 3, write: 100, read: 5_000, output: 40),
            claude("m1", at(12), input: 3, write: 100, read: 5_000, output: 400),
            claude("synthetic", at(13), output: 0),
            claude("m2", at(20), read: 6_000, output: 7),
        ], to: transcript)

        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        XCTAssertTrue(counter.advance())
        let total = counter.hours.total
        XCTAssertEqual(total.tokensOnly, TokenCount(input: 3, cacheWrite: 100, cacheRead: 11_000, output: 407))
        XCTAssertTrue(counter.found)
        XCTAssertEqual(counter.subagents, 0)
        XCTAssertFalse(counter.advance(), "nothing new, nothing moved")
    }

    func testSubagentsAreCountedAndOnesFromAnEarlierRunAreNot() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        try write([claude("main", at(10), output: 10)], to: transcript)
        let subagents = folder.appendingPathComponent("s1/subagents", isDirectory: true)
        try write([claude("sub-a", at(20), read: 900, output: 30)],
                  to: subagents.appendingPathComponent("agent-a.jsonl"))
        try write([claude("sub-b", at(25), output: 5)],
                  to: subagents.appendingPathComponent("agent-b.jsonl"))
        // Meta files sit next to the logs and are not logs.
        try write(["{\"agentType\":\"Explore\"}"], to: subagents.appendingPathComponent("agent-a.json"))
        // A subagent from before this agent started: a resumed session's past.
        let stale = subagents.appendingPathComponent("agent-old.jsonl")
        try write([claude("sub-old", at(-500), output: 1_000)], to: stale)
        try FileManager.default.setAttributes([.modificationDate: at(-400)], ofItemAtPath: stale.path)

        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        _ = counter.advance()
        XCTAssertEqual(counter.hours.total.output, 45)
        XCTAssertEqual(counter.hours.total.cacheRead, 900)
        XCTAssertEqual(counter.subagents, 2)
    }

    func testGrowthIsReadFromWhereTheLastPassStopped() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        try write([claude("m1", at(10), output: 4)], to: transcript)
        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        _ = counter.advance()
        XCTAssertEqual(counter.hours.total.output, 4)

        // The finished copy of the same message replaces the unfinished one.
        try append(claude("m1", at(11), output: 400) + "\n", to: transcript)
        XCTAssertTrue(counter.advance())
        XCTAssertEqual(counter.hours.total.output, 400)

        // A line still being written is not counted until it is whole…
        let line = claude("m2", at(30), output: 50)
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(String(line[..<cut]), to: transcript)
        XCTAssertFalse(counter.advance())
        XCTAssertEqual(counter.hours.total.output, 400)

        // …and is counted once it is.
        try append(String(line[cut...]) + "\n", to: transcript)
        XCTAssertTrue(counter.advance())
        XCTAssertEqual(counter.hours.total.output, 450)
    }

    func testAFileFirstSeenMidLineIsPickedUpWhenTheLineFinishes() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        let line = claude("m2", at(30), output: 50)
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try write([claude("m1", at(10), output: 4)], to: transcript)
        try append(String(line[..<cut]), to: transcript)

        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        _ = counter.advance()
        XCTAssertEqual(counter.hours.total.output, 4)
        try append(String(line[cut...]) + "\n", to: transcript)
        _ = counter.advance()
        XCTAssertEqual(counter.hours.total.output, 54)
    }

    func testACutOffKeepsOnlyWhatCameBefore() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        try write([
            claude("m1", at(10), output: 4),
            claude("m2", at(100), output: 6),
        ], to: transcript)
        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        _ = counter.advance()
        XCTAssertEqual(counter.hours(before: at(50)).total.output, 4)
    }

    func testAMissingTranscriptIsNotFound() throws {
        let folder = try temporaryFolder()
        let counter = ClaudeTokenCounter(
            transcript: folder.appendingPathComponent("gone.jsonl"), since: at(0)
        )
        XCTAssertFalse(counter.advance())
        XCTAssertFalse(counter.found)
    }

    func testTheLastCompleteLineEndsAtItsNewline() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("f.jsonl")
        try "abc\ndef\nghi".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileTail.endOfLastLine(of: file), 8)
        try "abc\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileTail.endOfLastLine(of: file), 4)
        try "no newline at all".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileTail.endOfLastLine(of: file), 0)
    }
}

final class CodexTokenCounterTests: XCTestCase {

    /// Measured from the running total: a repeated reading adds nothing, and
    /// the first turn after the agent started is measured from the reading
    /// before it.
    func testTheRunningTotalIsDifferencedAndRepeatsAddNothing() throws {
        let folder = try temporaryFolder()
        let rollout = folder.appendingPathComponent("rollout-1.jsonl")
        try write([
            json(["timestamp": iso(at(-100)), "type": "session_meta", "payload": ["cwd": "/proj"]]),
            codex(at(-50), total: (100, 0, 10), last: (100, 0, 10)),
            codex(at(10), total: (1_100, 800, 30), last: (1_000, 800, 20)),
            codex(at(11), total: (1_100, 800, 30), last: (1_000, 800, 20)),
            json(["timestamp": iso(at(12)), "type": "event_msg",
                  "payload": ["type": "token_count", "info": NSNull()]]),
            codex(at(20), total: (1_600, 1_200, 35), last: (500, 400, 5)),
        ], to: rollout)

        let counter = CodexTokenCounter(rollout: rollout, since: at(0))
        XCTAssertTrue(counter.advance())
        // 1,000 in of which 800 cached, then 500 of which 400: uncached 300,
        // cached 1,200, output 25. The turn before the agent started is out.
        XCTAssertEqual(counter.hours.total.tokensOnly, TokenCount(input: 300, cacheRead: 1_200, output: 25))
    }

    func testAppendedEventsContinueFromTheLastTotal() throws {
        let folder = try temporaryFolder()
        let rollout = folder.appendingPathComponent("rollout-1.jsonl")
        try write([codex(at(10), total: (100, 0, 10), last: (100, 0, 10))], to: rollout)
        let counter = CodexTokenCounter(rollout: rollout, since: at(0))
        _ = counter.advance()
        try append(codex(at(20), total: (300, 100, 15), last: (200, 100, 5)) + "\n", to: rollout)
        XCTAssertTrue(counter.advance())
        XCTAssertEqual(counter.hours.total.total, 315)
        XCTAssertEqual(counter.hours.total.cacheRead, 100)
    }
}

final class KiroTokenCounterTests: XCTestCase {

    func testCreditsAreCountedAndKeptWhenTheFileForgetsThem() throws {
        let folder = try temporaryFolder()
        let session = folder.appendingPathComponent("k1.json")
        try write([kiroSession(id: "k1", cwd: "/proj", turns: [
            (at(-100), 9.0), (at(10), 0.38), (at(20), 0.4),
        ])], to: session)

        let counter = KiroTokenCounter(session: session, since: at(0))
        XCTAssertTrue(counter.advance())
        XCTAssertEqual(counter.hours.total.credits, 0.78, accuracy: 0.0001)
        XCTAssertEqual(counter.project, "/proj")

        // Rewritten without its first turn, as after a compaction, plus a new
        // one: what was spent stays spent.
        try write([kiroSession(id: "k1", cwd: "/proj", turns: [(at(20), 0.4), (at(30), 1.0)])],
                  to: session)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: session.path)
        XCTAssertTrue(counter.advance())
        XCTAssertEqual(counter.hours.total.credits, 1.78, accuracy: 0.0001)
    }
}

// ─ The ledger ───────────────────────────────────────────────────────────────

final class TokenLedgerTests: XCTestCase {

    private func claim(
        _ pid: pid_t, started: Date, file: URL?,
        tool: Tool = .claudeCode, project: String? = "/proj", pids: Set<pid_t>? = nil
    ) -> TokenLedger.Claim {
        TokenLedger.Claim(
            owner: TokenOwner(pid: pid, startedAt: started),
            startedAt: started,
            tool: tool,
            project: project,
            pids: pids ?? [pid],
            source: file?.path
        )
    }

    private func owner(_ pid: pid_t, _ started: Date) -> TokenOwner {
        TokenOwner(pid: pid, startedAt: started)
    }

    private func transcript(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("projects/-proj/s1.jsonl")
        try write([
            claude("a", at(10), read: 1_000, output: 100),
            claude("b", at(20), output: 200),
        ], to: url)
        return url
    }

    func testAnAgentsSessionIsCountedUnderItAndItsProject() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let ledger = TokenLedger(store: nil, kiroRoot: folder, ttl: 0, saveInterval: 0)

        let agent = claim(10, started: at(0), file: file)
        let snapshot = ledger.pass([agent], alive: [agent.owner], now: at(30))
        XCTAssertEqual(snapshot.agents[agent.owner]?.total.tokensOnly, TokenCount(cacheRead: 1_000, output: 300))
        XCTAssertEqual(snapshot.agents[agent.owner]?.sessions, 1)
        XCTAssertEqual(snapshot.projects["/proj"]?.total.output, 300)
    }

    /// A tool that writes nothing countable gets no record, not a zero.
    func testUncountedToolsAreLeftOut() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let ledger = TokenLedger(store: nil, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let agent = claim(10, started: at(0), file: file, tool: .cursorAgent)
        let snapshot = ledger.pass([agent], alive: [agent.owner], now: at(30))
        XCTAssertTrue(snapshot.agents.isEmpty)
    }

    /// The property everything else rests on: counting again after a restart
    /// reproduces the count rather than adding to it.
    func testARestartRecountsRatherThanAddingAgain() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")
        let agent = claim(10, started: at(0), file: file)

        let first = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        _ = first.pass([agent], alive: [agent.owner], now: at(30))
        first.flush()

        try append(claude("c", at(40), output: 50) + "\n", to: file)
        let second = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let snapshot = second.pass([agent], alive: [agent.owner], now: at(50))
        XCTAssertEqual(snapshot.agents[agent.owner]?.total.output, 350)
        XCTAssertEqual(snapshot.agents[agent.owner]?.sessions, 1)
    }

    func testAGoneAgentIsClosedAndASecondOneOnTheSameLogStartsWhereItEnded() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let ledger = TokenLedger(store: nil, kiroRoot: folder, ttl: 0, saveInterval: 0)

        let first = claim(10, started: at(0), file: file)
        _ = ledger.pass([first], alive: [first.owner], now: at(30))
        _ = ledger.pass([], alive: [], now: at(40))

        // Resumed by a new process, which writes one more turn.
        try append(claude("c", at(60), output: 50) + "\n", to: file)
        let second = claim(11, started: at(50), file: file)
        let snapshot = ledger.pass([second], alive: [second.owner], now: at(70))

        XCTAssertEqual(snapshot.agents[first.owner]?.total.output, 300)
        XCTAssertEqual(snapshot.agents[second.owner]?.total.output, 50)
        XCTAssertEqual(snapshot.projects["/proj"]?.total.output, 350, "each turn exactly once")
    }

    /// The same, with the handover happening while Corral was not running:
    /// the first agent's record ends where the second began.
    func testAHandoverWhileClosedIsSplitAtTheSecondAgentsStart() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")

        let first = claim(10, started: at(0), file: file)
        let before = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        _ = before.pass([first], alive: [first.owner], now: at(30))
        before.flush()

        try append(claude("c", at(60), output: 50) + "\n", to: file)
        let second = claim(11, started: at(50), file: file)
        let after = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let snapshot = after.pass([second], alive: [second.owner], now: at(70))

        XCTAssertEqual(snapshot.agents[first.owner]?.total.output, 300)
        XCTAssertEqual(snapshot.agents[second.owner]?.total.output, 50)
        XCTAssertEqual(snapshot.projects["/proj"]?.total.output, 350)
    }

    func testALogIsNeverCountedUnderTwoRunningAgents() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let ledger = TokenLedger(store: nil, kiroRoot: folder, ttl: 0, saveInterval: 0)

        let one = claim(10, started: at(0), file: file)
        let two = claim(11, started: at(1), file: file)
        _ = ledger.pass([one, two], alive: [one.owner, two.owner], now: at(30))
        let snapshot = ledger.pass([two, one], alive: [one.owner, two.owner], now: at(40))

        XCTAssertEqual(snapshot.agents[one.owner]?.total.output, 300)
        XCTAssertNil(snapshot.agents[two.owner])
        XCTAssertEqual(snapshot.projects["/proj"]?.total.output, 300)
    }

    func testALogThatDisappearsKeepsItsCount() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")
        let agent = claim(10, started: at(0), file: file)

        let first = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        _ = first.pass([agent], alive: [agent.owner], now: at(30))
        first.flush()
        try FileManager.default.removeItem(at: file)

        let second = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        var snapshot = second.pass([agent], alive: [agent.owner], now: at(40))
        XCTAssertEqual(snapshot.agents[agent.owner]?.total.output, 300)
        snapshot = second.pass([], alive: [], now: at(50))
        XCTAssertEqual(snapshot.agents[agent.owner]?.total.output, 300)
    }

    func testKiroSessionsAreFoundByTheirLocks() throws {
        let folder = try temporaryFolder()
        let kiro = folder.appendingPathComponent("kiro", isDirectory: true)
        try write([kiroSession(id: "k1", cwd: "/crew-project", turns: [(at(10), 0.5)])],
                  to: kiro.appendingPathComponent("k1.json"))
        try write([json(["pid": 77, "started_at": iso(at(5))])],
                  to: kiro.appendingPathComponent("k1.lock"))
        try write([kiroSession(id: "k2", cwd: "/crew-project", turns: [(at(12), 0.25)])],
                  to: kiro.appendingPathComponent("k2.json"))
        try write([json(["pid": 78, "started_at": iso(at(6))])],
                  to: kiro.appendingPathComponent("k2.lock"))

        let ledger = TokenLedger(store: nil, kiroRoot: kiro, ttl: 0, saveInterval: 0)
        let crew = claim(70, started: at(0), file: nil, tool: .kiroCrew, project: nil, pids: [70, 77, 78])
        let snapshot = ledger.pass([crew], alive: [crew.owner], now: at(30))

        XCTAssertEqual(snapshot.agents[crew.owner]?.total.credits ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.agents[crew.owner]?.sessions, 2)
        XCTAssertEqual(snapshot.projects["/crew-project"]?.sessions, 2, "filed under the session's own folder")
    }

    func testAFileFromANewerCorralIsNeverWrittenOver() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")
        let newer = "{\"version\":99,\"records\":[],\"something\":\"new\"}"
        try newer.write(to: store, atomically: true, encoding: .utf8)

        let ledger = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let agent = claim(10, started: at(0), file: file)
        let snapshot = ledger.pass([agent], alive: [agent.owner], now: at(30))
        ledger.flush()

        XCTAssertEqual(snapshot.agents[agent.owner]?.total.output, 300, "still counts, in memory")
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), newer)
    }

    func testAnUnreadableFileIsMovedAsideNotLost() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")
        try "not a ledger".write(to: store, atomically: true, encoding: .utf8)

        let ledger = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let agent = claim(10, started: at(0), file: file)
        _ = ledger.pass([agent], alive: [agent.owner], now: at(30))

        let aside = folder.appendingPathComponent("ledger.unreadable.json")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "not a ledger")
        XCTAssertNotNil(try? Data(contentsOf: store), "a fresh ledger in its place")
    }

    func testClosedRecordsAgeOutAndOpenOnesDoNot() throws {
        let folder = try temporaryFolder()
        let file = try transcript(in: folder)
        let store = folder.appendingPathComponent("ledger.json")
        let ledger = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)

        let old = claim(10, started: at(0), file: file)
        _ = ledger.pass([old], alive: [old.owner], now: at(30))
        _ = ledger.pass([], alive: [], now: at(40))

        // Half a year on, a new session somewhere else makes the ledger save.
        let later = at(TokenLedger.retention + 1_000)
        let other = folder.appendingPathComponent("projects/-proj/s2.jsonl")
        try write([claude("z", later.addingTimeInterval(10), output: 1)], to: other)
        // Written when its turn was, as a real log would have been.
        try FileManager.default.setAttributes(
            [.modificationDate: later.addingTimeInterval(10)], ofItemAtPath: other.path
        )
        let fresh = claim(12, started: later, file: other)
        let snapshot = ledger.pass([fresh], alive: [fresh.owner], now: later.addingTimeInterval(20))
        ledger.flush()

        let reread = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let after = reread.pass([], alive: [fresh.owner], now: later.addingTimeInterval(30))
        XCTAssertNil(after.agents[old.owner], "the closed record from six months ago is gone")
        XCTAssertEqual(after.agents[fresh.owner]?.total.output, 1)
        XCTAssertEqual(snapshot.agents[fresh.owner]?.total.output, 1)
    }

    func testTwoCopiesOfCorralAddToEachOthersLedger() throws {
        let folder = try temporaryFolder()
        let store = folder.appendingPathComponent("ledger.json")
        let first = folder.appendingPathComponent("projects/-a/s1.jsonl")
        let second = folder.appendingPathComponent("projects/-b/s2.jsonl")
        try write([claude("a", at(10), output: 10)], to: first)
        try write([claude("b", at(10), output: 20)], to: second)

        // Both start before either has written anything, so neither read the
        // other's work at launch: the second to save has to find it on disk.
        let installed = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let development = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        _ = installed.pass([], alive: [], now: at(1))
        _ = development.pass([], alive: [], now: at(1))

        let one = claim(10, started: at(0), file: first, project: "/a")
        let two = claim(11, started: at(0), file: second, project: "/b")
        _ = installed.pass([one], alive: [one.owner], now: at(30))
        _ = development.pass([two], alive: [two.owner], now: at(31))

        // Read back after both agents have gone, so nothing can be recounted
        // from a running agent's log: what is there is what was kept.
        let reread = TokenLedger(store: store, kiroRoot: folder, ttl: 0, saveInterval: 0)
        let snapshot = reread.pass([], alive: [], now: at(40))
        XCTAssertEqual(snapshot.projects["/a"]?.total.output, 10)
        XCTAssertEqual(snapshot.projects["/b"]?.total.output, 20)
    }
}

// ─ What it cost ─────────────────────────────────────────────────────────────

final class TokenPriceTests: XCTestCase {

    func testClaudeRatiosFollowTheModel() throws {
        let opus = try XCTUnwrap(TokenPrice.of("claude-opus-5-5"))
        XCTAssertEqual(opus.cacheRead, 0.05)
        XCTAssertEqual(opus.cacheWrite5m, 1.25)
        XCTAssertEqual(opus.cacheWrite1h, 2)
        XCTAssertEqual(opus.output, 5)
        XCTAssertEqual(TokenPrice.of("claude-fable-5-1")?.cacheRead, 0.025)
        XCTAssertEqual(TokenPrice.of("claude-sonnet-5-5")?.cacheRead, 0.1)
        // A release date and a context marker change nothing about the price.
        XCTAssertEqual(TokenPrice.of("claude-haiku-4-5-20251001")?.cacheRead, 0.1)
        XCTAssertEqual(TokenPrice.of("claude-opus-5-5[1m]")?.cacheRead, 0.05)
    }

    func testOpenAIRatiosFollowTheModel() throws {
        let terra = try XCTUnwrap(TokenPrice.of("gpt-5.6-terra"))
        XCTAssertEqual(terra.cacheRead, 0.1)
        XCTAssertEqual(terra.output, 6)
        XCTAssertEqual(terra.cacheWrite5m, 1, "OpenAI does not charge for writing the cache")
        XCTAssertEqual(TokenPrice.of("gpt-5.6-sol")?.output, 5)
        XCTAssertEqual(TokenPrice.of("gpt-5.3-codex")?.output, 8)
        XCTAssertEqual(TokenPrice.of("gpt-5.5-pro")?.cacheRead, 1, "no cached price: a cached token is a full one")
    }

    /// The newest models are the ones whose prices broke the pattern, so a
    /// name the table does not know is not priced from its family.
    func testAnUnknownModelIsUnpricedRatherThanGuessed() {
        XCTAssertNil(TokenPrice.of("claude-opus-6"))
        XCTAssertNil(TokenPrice.of("claude-opus-5-7"))
        XCTAssertNil(TokenPrice.of("gpt-7"))
        XCTAssertNil(TokenPrice.of("<synthetic>"))
    }

    func testFullPriceAddsEachPartAtItsMultiple() throws {
        let opus = try XCTUnwrap(TokenPrice.of("claude-opus-5-5"))
        // 10 + 100×1.25 + 50×2 + 1,000×0.05 + 20×5
        XCTAssertEqual(opus.fullPrice(input: 10, write5m: 100, write1h: 50, cacheRead: 1_000, output: 20), 385)
    }

    func testTheCostShareLeavesTheUnpricedOut() {
        let count = TokenCount(cacheRead: 1_000, output: 10, fullPrice: 150, unpriced: 0)
        XCTAssertEqual(count.costShare ?? 0, 150.0 / 1_010, accuracy: 1e-9)
        let partly = TokenCount(cacheRead: 2_000, output: 20, fullPrice: 150, unpriced: 1_010)
        XCTAssertEqual(partly.costShare ?? 0, 150.0 / 1_010, accuracy: 1e-9)
        XCTAssertNil(TokenCount(cacheRead: 5, unpriced: 5).costShare)
    }

    func testPercentagesNeverRoundSomethingToNothing() {
        XCTAssertEqual(TokenFormat.percent(0.003), "<1%")
        XCTAssertEqual(TokenFormat.percent(0.08), "8%")
        XCTAssertEqual(TokenFormat.percent(1.96), "196%")
        XCTAssertEqual(TokenFormat.percent(0), "0%")
    }

    func testThePriceTravelsInTheLedgerAndOldRowsStillRead() throws {
        let priced = TokenCount(input: 1, cacheWrite: 2, cacheRead: 3, output: 4, fullPrice: 12.6)
        let data = try JSONEncoder().encode(priced)
        XCTAssertEqual(String(data: data, encoding: .utf8), "[1,2,3,4,0,13]")
        XCTAssertEqual(try JSONDecoder().decode(TokenCount.self, from: data).fullPrice, 13)

        let unpriced = TokenCount(input: 1, cacheWrite: 2, cacheRead: 3, output: 4, unpriced: 10)
        let back = try JSONDecoder().decode(TokenCount.self, from: JSONEncoder().encode(unpriced))
        XCTAssertEqual(back.unpriced, 10)

        // Rows written before prices were counted: unpriced, not free.
        let old = try JSONDecoder().decode(TokenCount.self, from: Data("[1,2,3,4]".utf8))
        XCTAssertEqual(old.fullPrice, 0)
        XCTAssertEqual(old.unpriced, 10)
        XCTAssertNil(old.costShare)
        let credits = try JSONDecoder().decode(TokenCount.self, from: Data("[0,0,0,0,0.5]".utf8))
        XCTAssertEqual(credits.credits, 0.5)
        XCTAssertEqual(credits.unpriced, 0)

        // A price too small to round to a token still reads back as priced.
        let tiny = TokenCount(cacheRead: 3, fullPrice: 0.075)
        let written = try JSONEncoder().encode(tiny)
        XCTAssertEqual(String(data: written, encoding: .utf8), "[0,0,3,0,0,1]")
        XCTAssertEqual(try JSONDecoder().decode(TokenCount.self, from: written).unpriced, 0)
    }
}

final class TokenPricingCounterTests: XCTestCase {

    private func line(_ model: String, split: [String: Int]?) -> Data {
        var usage: [String: Any] = [
            "input_tokens": 10, "cache_creation_input_tokens": 100,
            "cache_read_input_tokens": 1_000, "output_tokens": 20,
        ]
        if let split { usage["cache_creation"] = split }
        return Data(json([
            "type": "assistant", "timestamp": iso(at(10)),
            "message": ["id": "m1", "model": model, "content": [], "usage": usage],
        ]).utf8)
    }

    /// The hour-long entry costs 2× and the five-minute one 1.25×; Claude
    /// Code uses both, so the split in the record decides.
    func testAClaudeTurnIsPricedByItsModelAndItsCacheLifetimes() throws {
        let split = try XCTUnwrap(ClaudeTokens.turn(
            line("claude-opus-5-5", split: ["ephemeral_5m_input_tokens": 60, "ephemeral_1h_input_tokens": 40])
        ))
        // 10 + 60×1.25 + 40×2 + 1,000×0.05 + 20×5
        XCTAssertEqual(split.count.fullPrice, 315, accuracy: 1e-9)
        XCTAssertEqual(split.count.unpriced, 0)

        let older = try XCTUnwrap(ClaudeTokens.turn(line("claude-opus-5-5", split: nil)))
        XCTAssertEqual(older.count.fullPrice, 285, accuracy: 1e-9, "no breakdown: the five-minute default")

        let unknown = try XCTUnwrap(ClaudeTokens.turn(line("claude-opus-6", split: nil)))
        XCTAssertEqual(unknown.count.fullPrice, 0)
        XCTAssertEqual(unknown.count.unpriced, 1_130)
    }

    /// The finished copy of a message replaces the unfinished one in the
    /// price as well as in the count.
    func testARepeatedMessageIsPricedOnceAtItsLargest() throws {
        let folder = try temporaryFolder()
        let transcript = folder.appendingPathComponent("s1.jsonl")
        try write([
            json(["type": "assistant", "timestamp": iso(at(10)), "message": [
                "id": "m1", "model": "claude-sonnet-5-5", "content": [],
                "usage": ["input_tokens": 0, "cache_read_input_tokens": 1_000, "output_tokens": 4],
            ]]),
            json(["type": "assistant", "timestamp": iso(at(11)), "message": [
                "id": "m1", "model": "claude-sonnet-5-5", "content": [],
                "usage": ["input_tokens": 0, "cache_read_input_tokens": 1_000, "output_tokens": 40],
            ]]),
        ], to: transcript)
        let counter = ClaudeTokenCounter(transcript: transcript, since: at(0))
        _ = counter.advance()
        // 1,000×0.1 + 40×5
        XCTAssertEqual(counter.hours.total.fullPrice, 300, accuracy: 1e-9)
    }

    /// Codex names its model per turn, and `/model` changes it mid-session.
    func testACodexTurnIsPricedByTheModelItRanOn() throws {
        let folder = try temporaryFolder()
        let rollout = folder.appendingPathComponent("rollout-1.jsonl")
        try write([
            json(["timestamp": iso(at(5)), "type": "turn_context", "payload": ["model": "gpt-5.6-terra"]]),
            codex(at(10), total: (1_000, 800, 10), last: (1_000, 800, 10)),
            json(["timestamp": iso(at(15)), "type": "turn_context", "payload": ["model": "gpt-5.6-sol"]]),
            codex(at(20), total: (1_500, 1_200, 15), last: (500, 400, 5)),
            json(["timestamp": iso(at(25)), "type": "turn_context", "payload": ["model": "gpt-9"]]),
            codex(at(30), total: (1_600, 1_200, 16), last: (100, 0, 1)),
        ], to: rollout)
        let counter = CodexTokenCounter(rollout: rollout, since: at(0))
        _ = counter.advance()
        let total = counter.hours.total
        // Terra: 200 + 800×0.1 + 10×6 = 340. Sol: 100 + 400×0.1 + 5×5 = 165.
        XCTAssertEqual(total.fullPrice, 505, accuracy: 1e-9)
        XCTAssertEqual(total.unpriced, 101, "the turn on a model with no price")
    }
}
