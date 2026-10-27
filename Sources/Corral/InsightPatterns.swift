import Foundation

/// What Insights listens for in a prompt, a reply or a command's output.
///
/// The habits it counts are said in whatever language the person works in,
/// and on the machine this was written on that was Turkish nine prompts in
/// ten. Patterns written for English alone read that as a person who never
/// thanks, never pushes back and never asks for a test — which is a finding
/// about the patterns, not the person. So every phrase list here is English
/// and Turkish.
///
/// Text is folded before it is matched: case, accents and the dotless ı all
/// go, so "Teşekkürler", "tesekkurler" and "TEŞEKKÜRLER" are one word — people
/// type Turkish without its letters about as often as with them. The patterns
/// are therefore written in plain lowercase ASCII.
enum InsightPatterns {

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    // ─ Prompts ──────────────────────────────────────────────────────────────

    /// Thanks, not "please": please is how a request is phrased, thanks is
    /// something said about the work.
    static let gratitude = rx(
        #"\b(thank you|thx|tysm|appreciate (it|that|this|you))\b|\bthanks\b(?! to\b)"#
        + #"|\btesekkur|\bsag ?ol|\beyvallah\b|\beline (saglik|emegine)"#
    )

    /// Turning the agent around: a prompt that opens with a no, or says plainly
    /// that this is not what was asked for. Anchored to the start for the short
    /// words — "no" and "actually" turn up inside every other English sentence,
    /// and "dur" inside Turkish ones — and free-standing for the phrases that
    /// cannot mean anything else.
    static let pushback = rx(
        #"\A\W*(no|nope|wrong|stop|wait|actually|revert|undo|scratch that|never mind|go back"#
        + #"|hayir|yanlis|dur|durdur|bekle|olmadi|olmamis|vazgec|geri al|aslinda)\b"#
        + #"|\b(instead of|not what i (asked|meant|wanted)|that'?s not (it|right|what)"#
        + #"|bunun yerine|onun yerine|bunu (demedim|istemedim)|(oyle|boyle) degil|yanlis anladin)\b"#
    )

    /// Asking for proof rather than taking the agent's word that it works.
    static let verifyAsk = rx(
        #"\b(run (the )?tests?|test (it|this|that)|verify|double[- ]check|make sure|confirm"#
        + #"|test et|testleri? (calistir|kos)|kontrol et|dogrula|emin ol)"#
    )

    /// Picking one of the options the agent laid out — the opposite of a
    /// counter-proposal, which turns them all down.
    static let optionReference = rx(
        #"\b(option|approach|alternative|choice)\s*[0-9a-c]\b|\bgo with\b"#
        + #"|\b(first|second|third|last) (one|option|approach)\b|\blet'?s (do|try) [0-9a-c]\b"#
        + #"|\b(secenek|opsiyon|yol|yaklasim|alternatif)\s*[0-9a-c]\b|\b[0-9a-c]\s*(numara|nolu|ile devam|olsun)\b"#
        + #"|\b(birinci|ikinci|ucuncu|sonuncu)(si|sini|yi)?\b|\b(onerdigin|dedigin) gibi\b"#
    )

    /// Heat, in either language. Checked only on short messages: a long one
    /// that happens to contain "ugh" is a description, not an outburst.
    static let frustration = rx(
        #"\b(wtf|wth|ffs|ugh+|argh+|damn( it)?|dammit|this sucks|so frustrating|what the (hell|fuck)"#
        + #"|fuck\w*|shit\w*|are you kidding|of ya|of{2,}|yeter( artik)?|sacmalama|berbat|rezalet"#
        + #"|allah allah|ya sabir|bikti[mk]|anlamiyor musun|kac kere)\b"#
    )

    /// Capitals that are shouting rather than spelling something.
    private static let acronyms: Set<String> = [
        "I", "OK", "PR", "CI", "CD", "UI", "UX", "API", "URL", "URI", "SQL", "JSON", "HTML", "CSS",
        "YAML", "TODO", "FIXME", "LGTM", "WIP", "CLI", "SDK", "AWS", "DB", "MCP", "LLM", "PDF",
        "PNG", "SVG", "HTTP", "HTTPS", "SSH", "GPU", "CPU", "RAM", "IOS", "MD", "README", "TS",
        "JS", "ID", "UUID", "ENV", "XML", "CSV", "DNS", "TCP", "UDP", "JWT", "OAUTH", "SSO",
    ]
    private static let capsWord = rx(#"\b[A-ZÇĞİÖŞÜ][A-ZÇĞİÖŞÜ']{2,}\b"#, caseInsensitive: false)

    static func isCharged(_ raw: String) -> Bool {
        guard raw.count <= 280 else { return false }
        if raw.filter({ $0 == "!" }).count >= 2 { return true }
        if matches(frustration, fold(raw)) { return true }
        let shouted = capsWord.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            .compactMap { Range($0.range, in: raw).map { String(raw[$0]) } }
            .filter { !acronyms.contains($0) }
        return shouted.count >= 2
    }

    // ─ Agent replies ────────────────────────────────────────────────────────

    /// The agent laying out choices. The agent answers in the user's
    /// language, so this is bilingual too.
    static let agentOptions = rx(
        #"\b(option|approach|alternative)\s*[0-9a-c]\b|^\s*\d+[.)]\s+\*\*"#
        + #"|\b(here are|there are) (\d+|two|three|several|a few) (options|approaches|ways)\b"#
        + #"|\b(trade-?offs?|pros and cons)\b"#
        + #"|\b(secenek|opsiyon|yaklasim|alternatif)\s*[0-9a-c]\b|\b(iki|uc|birkac) (secenek|yol|yaklasim)\b"#
        + #"|\bsecenekler\b|\bartilari ve eksileri\b"#
    )

    /// The agent handing a decision back.
    static let agentQuestion = rx(
        #"\b(would you (like|prefer|rather)|do you want me to|should (i|we)|which (option|approach|one)"#
        + #"|what do you think|shall i|ister misin|tercih eder misin|hangisini|devam edeyim mi"#
        + #"|yapayim mi|baslayayim mi|onayliyor musun|ne dersin)\b"#
    )

    // ─ Commands and their output ────────────────────────────────────────────

    /// `git commit`, `git -C path commit`, a commit at the end of a chain.
    static let commitCommand = rx(#"\bgit\b[^|;&\n]*?\bcommit\b"#)

    /// `[main 2d10946] message` — what git prints for a commit it made. Tools
    /// that compress git's output drop it, which is why Insights matches
    /// commits to sessions by time as well.
    static let commitOutput = rx(#"\[[\w/.-]+\s+(?:\(root-commit\)\s+)?([0-9a-f]{7,40})\]"#, caseInsensitive: false)

    /// `feat:`, `fix(ui):`, `refactor!:` — a subject that says what kind of
    /// change it is.
    static let conventionalCommit = rx(
        #"\A(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\([^)]*\))?!?:"#,
        caseInsensitive: false
    )

    /// Codex marks a failed command in its output rather than with a flag.
    static let codexFailure = rx(#"\Ascript failed|"exit_code"\s*:\s*[1-9]|exit code:?\s*[1-9]|process exited with code [1-9]"#)

    /// A run of tests, from the summary line the runner prints: what passed
    /// and what failed. One per command output — the first runner that
    /// recognises it.
    static func testRun(in output: String) -> (passed: Int, failed: Int)? {
        let text = output.count > 400_000 ? String(output.suffix(400_000)) : output
        if let m = first(xctest, text) { return (max(0, m[1] - m[2]), m[2]) }
        if let m = first(swiftTestingFailed, text) { return (max(0, m[1] - m[2]), m[2]) }
        if let m = first(swiftTestingPassed, text) { return (m[1], 0) }
        if let m = first(rspec, text) { return (max(0, m[1] - m[2]), m[2]) }
        if let m = first(flutter, text) { return (m[1], m[2]) }
        if let m = first(cargo, text) { return (m[1], m[2]) }
        // pytest, jest, vitest, mocha: one line carrying "N passed" and
        // perhaps "N failed".
        for line in text.split(separator: "\n").reversed() where line.contains("pass") {
            let line = String(line)
            guard let passed = first(passedCount, line) else { continue }
            let failed = first(failedCount, line)?[1] ?? 0
            return (passed[1], failed)
        }
        let goPassed = goOK.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        let goFailed = goFail.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        if goPassed + goFailed > 0 { return (goPassed, goFailed) }
        return nil
    }

    private static let xctest = rx(#"Executed (\d+) tests?, with (\d+) failures?"#, caseInsensitive: false)
    private static let swiftTestingPassed = rx(#"Test run with (\d+) tests?(?: in \d+ suites?)? passed"#, caseInsensitive: false)
    private static let swiftTestingFailed = rx(
        #"Test run with (\d+) tests?(?: in \d+ suites?)? failed after [\d.]+ seconds with (\d+) issues?"#,
        caseInsensitive: false
    )
    private static let rspec = rx(#"(\d+) examples?, (\d+) failures?"#, caseInsensitive: false)
    private static let flutter = rx(#"\+(\d+)(?: ~\d+)?(?: -(\d+))?: (?:All tests passed|Some tests failed)"#, caseInsensitive: false)
    private static let cargo = rx(#"test result: \w+\. (\d+) passed; (\d+) failed"#, caseInsensitive: false)
    private static let passedCount = rx(#"\b(\d+) (?:passed|passing)\b"#)
    private static let failedCount = rx(#"\b(\d+) (?:failed|failing)\b"#)
    private static let goOK = rx(#"^ok\s+\S+\s+[\d.]+s"#, caseInsensitive: false)
    private static let goFail = rx(#"^FAIL\s+\S+\s+[\d.]+s"#, caseInsensitive: false)

    // ─ Paths ────────────────────────────────────────────────────────────────

    /// A plan written down as a file: `plans/x.md`, `plan.md`, `x-plan.md`.
    /// Not inside a skills, commands or agents folder, where "plan" is the name
    /// of a tool rather than a plan.
    static func isPlanFile(_ path: String) -> Bool {
        guard !path.contains("/skills/"), !path.contains("/commands/"), !path.contains("/agents/")
        else { return false }
        return matches(planPath, path)
    }

    private static let planPath = rx(#"(^|/)(plans?/[^/]+\.md|plan([-_][\w-]+)?\.md|[\w-]+[-_]plan\.md)$"#)

    /// The files an agent reads at the start of every session. Writing a rule
    /// there is how a correction stops having to be made twice.
    static func isAgentInstructions(_ path: String) -> Bool {
        matches(instructionPath, path)
    }

    private static let instructionPath = rx(
        #"(^|/)(CLAUDE\.md|CLAUDE\.local\.md|AGENTS\.md|GEMINI\.md|\.cursorrules|\.windsurfrules"#
        + #"|copilot-instructions\.md|SKILL\.md)$|/\.claude/(skills|commands|agents)/|/\.cursor/rules/"#,
        caseInsensitive: false
    )

    // ─ Plumbing ─────────────────────────────────────────────────────────────

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The integer capture groups of the first match, indexed as the regex
    /// numbers them; a group that did not take part reads as zero.
    static func first(_ regex: NSRegularExpression, _ text: String) -> [Int]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { i in
            guard let range = Range(match.range(at: i), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }
    }

    static func capture(_ regex: NSRegularExpression, _ text: String, group: Int = 1) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func rx(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Every pattern is a literal in this file; one that fails to compile
        // is a bug to catch on the first run, not a condition to handle.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }
}
