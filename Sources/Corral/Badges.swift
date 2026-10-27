import Foundation

enum BadgeTier: Int, Comparable, CaseIterable {
    case locked, bronze, silver, gold

    var title: String {
        switch self {
        case .locked: return "Locked"
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        }
    }

    /// For text that leaves the app, where there is no colour to carry it.
    var medal: String {
        switch self {
        case .locked: return ""
        case .bronze: return "🥉"
        case .silver: return "🥈"
        case .gold: return "🥇"
        }
    }

    static func < (a: BadgeTier, b: BadgeTier) -> Bool { a.rawValue < b.rawValue }
}

enum BadgeFamily: String, CaseIterable {
    case craft, steering, orchestration, output, rhythm

    var title: String {
        switch self {
        case .craft: return "Craft"
        case .steering: return "Steering"
        case .orchestration: return "Orchestration"
        case .output: return "Output"
        case .rhythm: return "Rhythm"
        }
    }

    var detail: String {
        switch self {
        case .craft: return "Habits that make an agent's work easier to trust."
        case .steering: return "How you keep the agent pointed at the right problem."
        case .orchestration: return "Working with more than one agent at a time."
        case .output: return "What made it into git."
        case .rhythm: return "When and how you work. Not better or worse, just yours."
        }
    }
}

/// One habit, measured, with the tier it has reached.
struct Badge: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let family: BadgeFamily
    /// What is measured, in a line.
    let summary: String
    let tier: BadgeTier
    /// The measurement as shown, or nil when there is not enough to judge.
    let value: String?
    /// What the next tier asks for.
    let next: String?
    /// How far towards the next tier, 0–1.
    let progress: Double
    /// Where bronze, silver and gold start, as shown.
    let ladder: [String]
    /// True when less is better, so the ladder counts down.
    let lowerIsBetter: Bool

    var hasData: Bool { value != nil }
}

/// The habits Insights awards, and the bar for each tier.
///
/// Every bar is a number someone can check against their own logs, and every
/// badge says what it measured. A badge with too little behind it stays locked
/// and says so, rather than rewarding or scolding three sessions.
enum BadgeCatalog {

    private struct Rule {
        let id: String
        let title: String
        let symbol: String
        let family: BadgeFamily
        let summary: String
        /// Bronze, silver, gold.
        let bars: [Double]
        var lowerIsBetter = false
        /// Nil when there is too little to judge.
        let measure: (InsightReport) -> Double?
        let format: (Double) -> String
    }

    /// The badges reached, best first; within a tier, in catalogue order.
    static func earned(_ badges: [Badge]) -> [Badge] {
        badges.enumerated()
            .filter { $0.element.tier > .locked }
            .sorted { ($0.element.tier, -$0.offset) > ($1.element.tier, -$1.offset) }
            .map(\.element)
    }

    static func evaluate(_ report: InsightReport) -> [Badge] {
        rules.map { rule in
            guard let value = rule.measure(report) else {
                return Badge(
                    id: rule.id, title: rule.title, symbol: rule.symbol, family: rule.family,
                    summary: rule.summary, tier: .locked, value: nil,
                    next: "Not enough to go on yet", progress: 0,
                    ladder: rule.bars.map(rule.format), lowerIsBetter: rule.lowerIsBetter
                )
            }
            let passed = rule.bars.filter { rule.lowerIsBetter ? value <= $0 : value >= $0 }.count
            let tier = BadgeTier(rawValue: passed) ?? .locked
            var next: String?
            var progress = 1.0
            if passed < rule.bars.count {
                let bar = rule.bars[passed]
                let nextTier = BadgeTier(rawValue: passed + 1) ?? .gold
                next = "\(nextTier.title) at \(rule.format(bar))"
                progress = rule.lowerIsBetter
                    ? (value <= 0 ? 1 : min(1, bar / value))
                    : (bar <= 0 ? 1 : min(1, value / bar))
            }
            return Badge(
                id: rule.id, title: rule.title, symbol: rule.symbol, family: rule.family,
                summary: rule.summary, tier: tier, value: rule.format(value),
                next: next, progress: progress,
                ladder: rule.bars.map(rule.format), lowerIsBetter: rule.lowerIsBetter
            )
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    /// Grouped the way the rest of the app writes numbers — 1,759 or 1.759 —
    /// since a 90-day count runs into the thousands.
    private static func count(_ noun: String) -> (Double) -> String {
        { value in "\(Int(value).formatted()) \(noun)\(Int(value) == 1 ? "" : "s")" }
    }

    private static let rules: [Rule] = [
        // Craft
        Rule(
            id: "plan", title: "Plan First", symbol: "map", family: .craft,
            summary: "Sessions that started from a plan",
            bars: [0.15, 0.35, 0.60],
            measure: { $0.sessions >= 5 ? $0.plannedShare : nil }, format: percent
        ),
        Rule(
            id: "verify", title: "Proof, Not Promises", symbol: "checkmark.seal", family: .craft,
            summary: "Sessions that changed code and ran its tests",
            bars: [0.30, 0.55, 0.80],
            measure: { $0.editingSessions >= 5 ? $0.verifyShare : nil }, format: percent
        ),
        Rule(
            id: "testFirst", title: "Test First", symbol: "testtube.2", family: .craft,
            summary: "Tested sessions where a test ran before the first edit",
            bars: [0.10, 0.25, 0.45],
            measure: { $0.testedSessions >= 5 ? $0.testFirstShare : nil }, format: percent
        ),
        Rule(
            id: "calm", title: "Calm Debugger", symbol: "stethoscope", family: .craft,
            summary: "Failed commands run again unchanged",
            bars: [0.12, 0.06, 0.02], lowerIsBetter: true,
            measure: { $0.errors >= 20 ? $0.blindRetryShare : nil }, format: percent
        ),
        Rule(
            id: "codify", title: "Rule Writer", symbol: "text.book.closed", family: .craft,
            summary: "Sessions that edited CLAUDE.md or AGENTS.md",
            bars: [1, 4, 10],
            measure: { $0.sessions >= 3 ? Double($0.codifySessions) : nil }, format: count("session")
        ),
        // Steering
        Rule(
            id: "steer", title: "Hands on the Wheel", symbol: "hand.raised", family: .steering,
            summary: "Interrupts, declined tool calls and course corrections",
            bars: [10, 40, 100],
            measure: { $0.prompts >= 30 ? Double($0.steering) : nil }, format: count("correction")
        ),
        Rule(
            id: "pushback", title: "Second Opinion", symbol: "arrow.triangle.branch", family: .steering,
            summary: "Times you turned down every option the agent offered",
            bars: [3, 10, 25],
            measure: { $0.prompts >= 30 ? Double($0.counterProposals) : nil }, format: count("time")
        ),
        Rule(
            id: "context", title: "Clean Slate", symbol: "rectangle.compress.vertical", family: .steering,
            summary: "/compact or /clear typed between tasks",
            bars: [3, 10, 30],
            measure: { $0.sessions >= 3 ? Double($0.contextResets) : nil }, format: count("reset")
        ),
        // Orchestration
        Rule(
            id: "conductor", title: "Conductor", symbol: "square.stack.3d.up", family: .orchestration,
            summary: "The most sessions at work at the same time",
            bars: [2, 3, 5],
            measure: { $0.sessions >= 3 ? Double($0.peakParallel) : nil }, format: { "\(Int($0)) at once" }
        ),
        Rule(
            id: "delegator", title: "Delegator", symbol: "person.3", family: .orchestration,
            summary: "Subagents dispatched to do part of the work",
            bars: [10, 50, 200],
            measure: { $0.sessions >= 3 ? Double($0.dispatches) : nil }, format: count("subagent")
        ),
        // Output
        Rule(
            id: "shipper", title: "Shipper", symbol: "shippingbox", family: .output,
            summary: "Your commits made while an agent was at work",
            bars: [10, 60, 250],
            measure: { $0.gitAvailable ? Double($0.assistedCommits) : nil }, format: count("commit")
        ),
        Rule(
            id: "tidy", title: "Tidy History", symbol: "checklist", family: .output,
            summary: "Commits with a conventional subject (feat:, fix: …)",
            bars: [0.30, 0.60, 0.90],
            measure: { $0.commits >= 10 ? $0.conventionalShare : nil }, format: percent
        ),
        // Rhythm
        Rule(
            id: "night", title: "Night Owl", symbol: "moon.stars", family: .rhythm,
            summary: "Prompts sent between 22:00 and 02:00",
            bars: [0.20, 0.30, 0.45],
            measure: { $0.prompts >= 50 ? $0.nightShare : nil }, format: percent
        ),
        Rule(
            id: "early", title: "Early Bird", symbol: "sunrise", family: .rhythm,
            summary: "Prompts sent between 05:00 and 09:00",
            bars: [0.15, 0.25, 0.40],
            measure: { $0.prompts >= 50 ? $0.earlyShare : nil }, format: percent
        ),
        Rule(
            id: "marathon", title: "Marathoner", symbol: "figure.walk", family: .rhythm,
            summary: "The longest unbroken stretch of work in one session",
            bars: [2, 4, 8],
            measure: { $0.sessions > 0 ? $0.longestRun / 3_600 : nil },
            format: { String(format: "%.1f h", $0) }
        ),
        Rule(
            id: "streak", title: "Streak", symbol: "flame", family: .rhythm,
            summary: "The most days in a row with an agent at work",
            bars: [5, 14, 30],
            measure: { $0.sessions > 0 ? Double($0.longestStreak) : nil }, format: count("day")
        ),
        Rule(
            id: "concise", title: "Straight to the Point", symbol: "text.quote", family: .rhythm,
            summary: "Words in your typical prompt",
            bars: [12, 8, 5], lowerIsBetter: true,
            measure: { $0.prompts >= 50 ? $0.medianPromptWords : nil }, format: count("word")
        ),
        Rule(
            id: "polite", title: "Courteous", symbol: "heart", family: .rhythm,
            summary: "Prompts that said thanks, in English or Turkish",
            bars: [5, 20, 60],
            measure: { $0.prompts >= 30 ? Double($0.gratitude) : nil }, format: count("thank-you")
        ),
        Rule(
            id: "catchphrase", title: "Catchphrase", symbol: "repeat", family: .rhythm,
            summary: "How often your most-sent short prompt was sent",
            bars: [5, 12, 30],
            measure: { $0.prompts >= 30 ? Double($0.topRepeat) : nil }, format: { "sent \(Int($0).formatted())×" }
        ),
    ]
}

// ─ Archetype ────────────────────────────────────────────────────────────────

/// The one-line answer to "how do I work", picked from the badges.
struct Archetype: Equatable {
    let title: String
    let symbol: String
    let line: String
}

enum ArchetypeCatalog {

    static let explorer = Archetype(
        title: "The Explorer", symbol: "binoculars",
        line: "Still finding a rhythm. Every badge is open."
    )

    /// In order: a tie goes to the one listed first.
    private static let all: [(Archetype, [String])] = [
        (Archetype(title: "The Architect", symbol: "building.columns",
                   line: "Plans before building, and writes the rules down."),
         ["plan", "codify", "testFirst"]),
        (Archetype(title: "The Verifier", symbol: "checkmark.shield",
                   line: "Trusts what passes, not what is promised."),
         ["verify", "testFirst", "calm"]),
        (Archetype(title: "The Conductor", symbol: "square.stack.3d.up",
                   line: "Keeps several agents busy at once."),
         ["conductor", "delegator", "marathon"]),
        (Archetype(title: "The Navigator", symbol: "safari",
                   line: "Steers hard, and argues back when the agent drifts."),
         ["steer", "pushback", "context"]),
        (Archetype(title: "The Shipper", symbol: "shippingbox",
                   line: "Turns sessions into commits, day after day."),
         ["shipper", "tidy", "streak"]),
        (Archetype(title: "The Night Owl", symbol: "moon.stars",
                   line: "Does the real work after dark."),
         ["night", "marathon"]),
    ]

    static func pick(_ badges: [Badge]) -> Archetype {
        let tiers = Dictionary(uniqueKeysWithValues: badges.map { ($0.id, $0.tier.rawValue) })
        var best = explorer
        var bestScore = 0.0
        for (archetype, ids) in all {
            let score = Double(ids.reduce(0) { $0 + (tiers[$1] ?? 0) }) / Double(ids.count * 3)
            if score > bestScore {
                best = archetype
                bestScore = score
            }
        }
        return best
    }
}

// ─ Growth edge ──────────────────────────────────────────────────────────────

/// Where the next improvement is, from the craft and steering badges that are
/// measurable and still below silver.
struct GrowthTip: Identifiable, Equatable {
    let id: String
    let symbol: String
    let text: String
}

enum GrowthEdge {

    static func tips(_ badges: [Badge], limit: Int = 3) -> [GrowthTip] {
        let byID = Dictionary(uniqueKeysWithValues: badges.map { ($0.id, $0) })
        return order.compactMap { id -> GrowthTip? in
            guard let badge = byID[id], badge.hasData, badge.tier < .silver,
                  let text = advice(id, value: badge.value ?? "")
            else { return nil }
            return GrowthTip(id: id, symbol: badge.symbol, text: text)
        }
        .prefix(limit)
        .map { $0 }
    }

    private static let order = ["verify", "plan", "testFirst", "calm", "codify", "context"]

    private static func advice(_ id: String, value: String) -> String? {
        switch id {
        case "plan":
            return "Plan mode in \(value) of sessions. Before a change that touches several files, "
                + "start in plan mode and read the plan before any code is written."
        case "verify":
            return "Tests ran in \(value) of the sessions that changed code. "
                + "Ask for the test run before you accept a change, not after."
        case "testFirst":
            return "A test came first in \(value) of tested sessions. Asking for a failing test "
                + "first turns \u{201C}done\u{201D} into something the agent has to prove."
        case "calm":
            return "\(value) of failed commands were run again unchanged. "
                + "When something fails, ask the agent why before it retries."
        case "codify":
            return "No instruction-file edits yet. The second time you correct the agent on something, "
                + "have it write the rule into CLAUDE.md or AGENTS.md."
        case "context":
            return "Few context resets. /clear between unrelated tasks keeps the agent's "
                + "attention on the one in front of it."
        default:
            return nil
        }
    }
}
