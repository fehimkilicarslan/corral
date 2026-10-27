import Foundation

/// How you have been working with your agents, over a window of days.
///
/// A fold over `SessionFacts` and commits. Every share is optional: a share
/// of nothing is not zero, and a badge has to be able to tell "you never do
/// this" from "there is nothing here to judge yet".
struct InsightReport: Equatable {

    struct ModelShare: Equatable {
        var name: String
        var turns: Int
    }

    var days: Int
    var since: Date

    var sessions = 0
    var projects = 0
    var tools: [Tool: Int] = [:]
    var activeHours: Double = 0
    /// The longest stretch of uninterrupted activity in one session.
    var longestRun: TimeInterval = 0
    /// The most sessions at work at the same moment.
    var peakParallel = 0
    var activeDays = 0
    var longestStreak = 0
    var currentStreak = 0

    var prompts = 0
    var medianPromptWords: Double?
    var nightShare: Double?
    var earlyShare: Double?
    var peakHour: Int?
    var busiestWeekday: String?
    var gratitude = 0
    var charged = 0
    /// How often your most-repeated short prompt was sent.
    var topRepeat = 0

    var plannedShare: Double?
    var editingSessions = 0
    var verifyShare: Double?
    var testedSessions = 0
    var testFirstShare: Double?
    var testRuns = 0
    var failingTestRuns = 0
    var errors = 0
    var blindRetryShare: Double?
    var medianRecovery: Double?
    /// Interrupts, declined tool calls and prompts that turn the agent around.
    var steering = 0
    var counterProposals = 0
    var contextResets = 0
    var codifySessions = 0

    var dispatches = 0
    var backgroundDispatches = 0
    var returnedDispatches = 0

    /// Whether any session ran in a repository git could read.
    var gitAvailable = false
    var commits = 0
    /// Commits made in a session's repository while that session was at work.
    var assistedCommits = 0
    var linesAdded = 0
    var linesDeleted = 0
    var conventionalShare: Double?

    var models: [ModelShare] = []

    var isEmpty: Bool { sessions == 0 }

    /// How close to a session's activity a commit must land to be its commit.
    static let commitSlack: TimeInterval = 10 * 60

    static func build(
        _ scan: InsightStore.Scan,
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> InsightReport {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var report = InsightReport(days: days, since: since)
        let facts = scan.facts.filter { ($0.end ?? .distantPast) >= since }
        guard !facts.isEmpty else { return report }

        report.sessions = facts.count
        report.projects = Set(facts.compactMap(\.project)).count
        for fact in facts { report.tools[fact.tool, default: 0] += 1 }

        let spans = facts.flatMap(\.spans).filter { $0.end >= since }
        report.activeHours = spans.reduce(0) { $0 + $1.end.timeIntervalSince(max($1.start, since)) } / 3_600
        report.longestRun = spans.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        report.peakParallel = peakOverlap(spans)

        // ─ Rhythm
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let firstDay = day.string(from: since)
        var byDay: [String: Int] = [:]
        for fact in facts {
            for (key, count) in fact.promptDays where key >= firstDay { byDay[key, default: 0] += count }
        }
        report.activeDays = byDay.count
        (report.longestStreak, report.currentStreak) = streaks(Set(byDay.keys), today: now, format: day, calendar: calendar)
        var weekdays: [Int: Int] = [:]
        for (key, count) in byDay {
            if let date = day.date(from: key) { weekdays[calendar.component(.weekday, from: date), default: 0] += count }
        }
        if let busiest = weekdays.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) {
            report.busiestWeekday = calendar.weekdaySymbols[busiest.key - 1]
        }

        var hours = [Int](repeating: 0, count: 24)
        for fact in facts { for h in 0..<24 { hours[h] += fact.promptHours[h] } }
        let hourTotal = hours.reduce(0, +)
        if hourTotal > 0 {
            report.nightShare = Double(hours[22] + hours[23] + hours[0] + hours[1]) / Double(hourTotal)
            report.earlyShare = Double(hours[5...8].reduce(0, +)) / Double(hourTotal)
            report.peakHour = hours.indices.max { hours[$0] < hours[$1] }
        }

        // ─ The person
        let words = facts.flatMap(\.promptWords)
        report.prompts = words.count
        report.medianPromptWords = median(words.map(Double.init))
        report.gratitude = facts.reduce(0) { $0 + $1.gratitude }
        report.charged = facts.reduce(0) { $0 + $1.charged }
        var repeats: [String: Int] = [:]
        for fact in facts { for (key, count) in fact.shortPrompts { repeats[key, default: 0] += count } }
        report.topRepeat = repeats.values.max() ?? 0
        report.steering = facts.reduce(0) { $0 + $1.interrupts + $1.declinedTools + $1.pushback }
        report.counterProposals = facts.reduce(0) { $0 + $1.counterProposals }
        report.contextResets = facts.reduce(0) { $0 + $1.contextResets }
        report.codifySessions = facts.filter { $0.codifyEdits > 0 }.count

        // ─ Craft
        report.plannedShare = share(facts.filter(\.planned).count, of: facts.count)
        let editing = facts.filter { $0.edits > 0 }
        report.editingSessions = editing.count
        report.verifyShare = share(editing.filter { $0.testRuns > 0 }.count, of: editing.count)
        let both = facts.compactMap(\.testedBeforeEditing)
        report.testedSessions = both.count
        report.testFirstShare = share(both.filter { $0 }.count, of: both.count)
        report.testRuns = facts.reduce(0) { $0 + $1.testRuns }
        report.failingTestRuns = facts.reduce(0) { $0 + $1.failingTestRuns }
        report.errors = facts.reduce(0) { $0 + $1.errors }
        report.blindRetryShare = share(facts.reduce(0) { $0 + $1.blindRetries }, of: report.errors)
        report.medianRecovery = median(facts.flatMap(\.recoverySteps).map(Double.init))

        // ─ Orchestration
        report.dispatches = facts.reduce(0) { $0 + $1.dispatches }
        report.backgroundDispatches = facts.reduce(0) { $0 + $1.backgroundDispatches }
        report.returnedDispatches = facts.reduce(0) { $0 + $1.returnedDispatches }

        var models: [String: Int] = [:]
        for fact in facts { for (name, turns) in fact.models { models[name, default: 0] += turns } }
        report.models = models.map { ModelShare(name: $0.key, turns: $0.value) }
            .sorted { ($0.turns, $1.name) > ($1.turns, $0.name) }

        // ─ Output
        let recorded = Set(facts.flatMap(\.commitSHAs))
        var spansByRoot: [String: [SessionFacts.Span]] = [:]
        for fact in facts {
            guard let project = fact.project, let root = scan.roots[project] else { continue }
            spansByRoot[root, default: []].append(contentsOf: fact.spans)
        }
        let commits = scan.commits.flatMap { root, list in
            list.filter { $0.at >= since }.map { (root, $0) }
        }
        report.gitAvailable = !spansByRoot.isEmpty
        report.commits = commits.count
        report.linesAdded = commits.reduce(0) { $0 + $1.1.added }
        report.linesDeleted = commits.reduce(0) { $0 + $1.1.deleted }
        report.assistedCommits = commits.filter { root, commit in
            if recorded.contains(String(commit.sha.prefix(7))) { return true }
            return (spansByRoot[root] ?? []).contains {
                commit.at >= $0.start.addingTimeInterval(-commitSlack)
                    && commit.at <= $0.end.addingTimeInterval(commitSlack)
            }
        }.count
        report.conventionalShare = share(
            commits.filter { InsightPatterns.matches(InsightPatterns.conventionalCommit, $0.1.subject) }.count,
            of: commits.count
        )
        return report
    }

    // ─ Helpers ──────────────────────────────────────────────────────────────

    static func share(_ part: Int, of whole: Int) -> Double? {
        whole > 0 ? Double(part) / Double(whole) : nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The most spans open at one instant: a sweep over their edges, where a
    /// span that ends exactly as another starts does not count as overlapping.
    static func peakOverlap(_ spans: [SessionFacts.Span]) -> Int {
        let edges = spans.flatMap { [($0.start, 1), ($0.end, -1)] }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var open = 0, peak = 0
        for (_, change) in edges {
            open += change
            peak = max(peak, open)
        }
        return peak
    }

    /// The longest run of consecutive days, and the run that reaches today —
    /// or yesterday, since a streak is not broken by a day that is not over.
    static func streaks(
        _ days: Set<String>,
        today: Date,
        format: DateFormatter,
        calendar: Calendar
    ) -> (longest: Int, current: Int) {
        let dates = days.compactMap(format.date(from:)).map { calendar.startOfDay(for: $0) }.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for date in dates {
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        var current = 0
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(format.string(from: cursor)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while days.contains(format.string(from: cursor)) {
            current += 1
            guard let back = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = back
        }
        return (longest, current)
    }
}
