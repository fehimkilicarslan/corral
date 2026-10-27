import Foundation

extension CLI {

    /// `--insights`: the Insights tab, printed.
    ///
    /// `--json` is the same figures for a script — or for an agent asked to
    /// look at how its user works, which can read this instead of the
    /// transcripts themselves.
    static func insights(days: Int, json: Bool) {
        let scan = InsightStore().scan()
        let report = InsightReport.build(scan, days: days)
        let badges = BadgeCatalog.evaluate(report)
        let archetype = ArchetypeCatalog.pick(badges)
        let tips = GrowthEdge.tips(badges)

        if json {
            let object = insightsJSON(report: report, badges: badges, archetype: archetype, tips: tips)
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }

        guard !report.isEmpty else {
            print("No Claude Code or Codex sessions in the last \(days) days.")
            return
        }
        print("")
        print("  \(archetype.title) — \(archetype.line)")
        print("  last \(days) days · \(report.sessions) sessions · \(report.prompts) prompts · "
            + "\(Int(report.activeHours.rounded())) active hours · \(report.commits) commits")
        print("")
        for family in BadgeFamily.allCases {
            let group = badges.filter { $0.family == family }
            guard !group.isEmpty else { continue }
            print("  \(family.title.uppercased())")
            for badge in group {
                let tier = badge.tier.title.padding(toLength: 7, withPad: " ", startingAt: 0)
                let title = badge.title.padding(toLength: 22, withPad: " ", startingAt: 0)
                let value = (badge.value ?? "—").padding(toLength: 16, withPad: " ", startingAt: 0)
                print("    \(tier) \(title) \(value) \(badge.next ?? "")")
            }
            print("")
        }
        if !tips.isEmpty {
            print("  NEXT")
            for tip in tips { print("    · \(tip.text)") }
            print("")
        }
    }

    static func insightsJSON(
        report: InsightReport,
        badges: [Badge],
        archetype: Archetype,
        tips: [GrowthTip]
    ) -> [String: Any] {
        func optional(_ value: Double?) -> Any { value.map { ($0 * 1_000).rounded() / 1_000 } ?? NSNull() }
        return [
            "days": report.days,
            "archetype": ["title": archetype.title, "line": archetype.line],
            "totals": [
                "sessions": report.sessions,
                "projects": report.projects,
                "prompts": report.prompts,
                "activeHours": (report.activeHours * 10).rounded() / 10,
                "activeDays": report.activeDays,
                "peakParallel": report.peakParallel,
                "commits": report.commits,
                "assistedCommits": report.assistedCommits,
                "linesAdded": report.linesAdded,
                "linesDeleted": report.linesDeleted,
                "testRuns": report.testRuns,
                "failingTestRuns": report.failingTestRuns,
                "errors": report.errors,
                "dispatches": report.dispatches,
            ],
            "shares": [
                "planned": optional(report.plannedShare),
                "verified": optional(report.verifyShare),
                "testFirst": optional(report.testFirstShare),
                "blindRetry": optional(report.blindRetryShare),
                "night": optional(report.nightShare),
                "early": optional(report.earlyShare),
                "conventionalCommits": optional(report.conventionalShare),
            ],
            "badges": badges.map { badge -> [String: Any] in
                [
                    "id": badge.id,
                    "title": badge.title,
                    "family": badge.family.rawValue,
                    "tier": badge.tier.title.lowercased(),
                    "value": badge.value ?? NSNull(),
                    "next": badge.next ?? NSNull(),
                ]
            },
            "next": tips.map(\.text),
            "models": report.models.prefix(5).map { ["name": $0.name, "turns": $0.turns] },
        ]
    }
}
