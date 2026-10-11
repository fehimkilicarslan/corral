import SwiftUI

// ─ Formatting ───────────────────────────────────────────────────────────────

enum TokenFormat {

    /// The size at a glance — 1.24B, 563M, 4.2M, 35k, 980. The popover has the
    /// exact figure for anyone who wants it.
    ///
    /// Thresholds are set on where the rounded figure lands, so 999.96 million
    /// reads as 1.00B rather than as a four-digit "1000M".
    static func compact(_ value: Int) -> String {
        let figure = Double(value)
        switch figure {
        case 999_500_000...: return String(format: "%.2fB", figure / 1_000_000_000)
        case 99_950_000...: return String(format: "%.0fM", figure / 1_000_000)
        case 999_950...: return String(format: "%.1fM", figure / 1_000_000)
        case 9_999.5...: return String(format: "%.0fk", figure / 1_000)
        case 1_000...: return String(format: "%.1fk", figure / 1_000)
        default: return "\(value)"
        }
    }

    /// The figure a row shows: tokens, or Kiro's credits when that is all
    /// there is.
    static func compact(_ count: TokenCount) -> String {
        count.isCredits ? ModelUse.compact(credits: count.credits) : compact(count.total)
    }

    static func unit(_ count: TokenCount) -> String {
        count.isCredits ? "credits" : "tokens"
    }

    static func exact(_ value: Int) -> String {
        grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

// ─ A tooltip with room for a chart ──────────────────────────────────────────

extension View {
    /// A popover that opens when the pointer rests on this view and stays open
    /// while the pointer is over either — so the chart inside can be pointed
    /// at, which a tooltip that closes on leaving its anchor would not allow.
    func hoverPopover<Popover: View>(
        @ViewBuilder _ popover: @escaping () -> Popover
    ) -> some View {
        modifier(HoverPopover(popover: popover))
    }
}

private struct HoverPopover<Popover: View>: ViewModifier {
    let popover: () -> Popover

    @State private var overAnchor = false
    @State private var overPopover = false
    @State private var shown = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                overAnchor = inside
                reconsider()
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                popover()
                    .onHover { inside in
                        overPopover = inside
                        reconsider()
                    }
            }
    }

    /// A tooltip's patience on the way in, so sweeping the pointer down the
    /// list does not open a popover per row; less on the way out, so the gap
    /// between the figure and its popover can be crossed without it closing.
    private func reconsider() {
        pending?.cancel()
        let wanted = overAnchor || overPopover
        guard wanted != shown else { return }
        let work = DispatchWorkItem { shown = overAnchor || overPopover }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.45 : 0.25), execute: work)
    }
}

// ─ The row's figure ─────────────────────────────────────────────────────────

/// What this agent has spent, in the row, next to its memory and uptime.
///
/// The token counterpart of CPU time: a running total since the process
/// started, kept from the tool's own logs rather than sampled. Pointing at it
/// opens the hour-by-hour story and what the project as a whole has spent.
struct TokenMetric: View {
    @ObservedObject var model: CorralViewModel
    let group: AgentGroup
    let usage: TokenSnapshot.Usage

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(TokenFormat.compact(usage.total))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(TokenFormat.unit(usage.total).uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
        }
        .frame(minWidth: 52, alignment: .trailing)
        .hoverPopover {
            // Read here rather than inside the popover: the row is redrawn on
            // every refresh, which hands an open popover fresh figures, and a
            // popover that takes plain values can be drawn on its own.
            TokenPopover(
                label: model.label(for: group),
                group: group,
                usage: model.tokens(for: group),
                project: model.projectTokens(for: group)
            )
        }
    }
}

// ─ The popover ──────────────────────────────────────────────────────────────

struct TokenPopover: View {
    let label: String
    let group: AgentGroup
    let usage: TokenSnapshot.Usage?
    let project: TokenSnapshot.Usage?
    var now = Date()

    private var accent: Color { Theme.accent(for: group.root.tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let usage {
                TokenTotals(usage: usage)
                TokenHistory(title: "THIS AGENT", usage: usage, now: now, tint: accent)
            } else {
                Text("Nothing counted yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }

            if let project, Self.adds(project, to: usage) {
                Divider().opacity(0.5)
                projectSection(project, now: now)
            }

            Text(footnote(for: usage))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Pill(text: group.root.title, color: accent)
                Spacer(minLength: 0)
            }
            Text("Since \(Self.moment(group.root.startedAt)) · up \(group.root.uptime.durationString)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
        }
    }

    /// Worth a section of its own only when the project is more than this
    /// agent: other agents in the same directory, or earlier sessions Corral
    /// watched there.
    static func adds(_ project: TokenSnapshot.Usage, to agent: TokenSnapshot.Usage?) -> Bool {
        guard let agent else { return !project.total.isEmpty }
        return project.sessions > agent.sessions || project.total != agent.total
    }

    private func projectSection(_ project: TokenSnapshot.Usage, now: Date) -> some View {
        let calendar = Calendar.current
        let today = TokenHours.start(of: calendar.startOfDay(for: now))
        let week = TokenHours.start(of: now.addingTimeInterval(-7 * 86_400))
        let sessions = project.sessions == 1 ? "1 session" : "\(project.sessions) sessions"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("PROJECT")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.faint)
                Text(group.root.projectName ?? "this folder")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(sessions) since \(project.since.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.faint)
            }
            HStack(spacing: 18) {
                figure("Today", project.hours.total(from: today))
                figure("7 days", project.hours.total(from: week))
                figure("All", project.total)
            }
            TokenHistory(title: "PROJECT", usage: project, now: now, tint: Theme.trend)
        }
    }

    private func figure(_ label: String, _ count: TokenCount) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TokenFormat.compact(count))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
        }
    }

    /// Where the numbers came from, which differs by tool and is part of
    /// what they mean.
    private func footnote(for usage: TokenSnapshot.Usage?) -> String {
        let source: String
        switch group.root.tool {
        case .codex:
            source = "From Codex's rollout log, by its own running total."
        case .kiroCLI, .kiroCrew:
            source = "From Kiro's session files. Kiro records the credits each turn "
                + "cost, not tokens."
        default:
            source = "From Claude Code's transcripts, subagents included."
        }
        let cache = (usage?.total.cacheRead ?? 0) > 0
            ? " Cache reads are context the model had already seen."
            : ""
        return source + cache + " Counted since the agent started, and kept while "
            + "Corral runs in the menu bar."
    }

    static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The total, and what it was made of.
private struct TokenTotals: View {
    let usage: TokenSnapshot.Usage

    var body: some View {
        let total = usage.total
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenFormat.compact(total))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(TokenFormat.unit(total))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                if !total.isCredits {
                    Text(TokenFormat.exact(total.total))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .textSelection(.enabled)
                }
            }

            if let extent = extent {
                Text(extent)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtle)
            }

            if !total.isCredits {
                VStack(spacing: 4) {
                    part("Output", total.output, of: total.total)
                    part("Input", total.input, of: total.total)
                    part("Cache write", total.cacheWrite, of: total.total)
                    part("Cache read", total.cacheRead, of: total.total)
                }
            }
        }
    }

    /// Subagents and sessions, when there is more than one of either.
    private var extent: String? {
        var parts: [String] = []
        if usage.subagents > 0 {
            parts.append(usage.subagents == 1 ? "1 subagent" : "\(usage.subagents) subagents")
        }
        if usage.sessions > 1 { parts.append("\(usage.sessions) sessions") }
        return parts.isEmpty ? nil : "Includes " + parts.joined(separator: " and ")
    }

    private func part(_ label: String, _ value: Int, of total: Int) -> some View {
        let share = total > 0 ? Double(value) / Double(total) : 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtle)
                .frame(width: 72, alignment: .leading)
            Meter(fraction: share, tint: Theme.trend, height: 3, track: Color.primary.opacity(0.09))
            Text(TokenFormat.compact(value))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            // Six million tokens of output is not nothing, whatever share of
            // five billion it rounds to.
            Text(share > 0 && share < 0.005 ? "<1%" : String(format: "%.0f%%", (share * 100).rounded()))
                .font(.system(size: 9.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// The last twenty-four hours, an hour to a column.
///
/// The same instrument as the header graph — bars on a graticule, a reading
/// docked above it — at a coarser grain. An hour before the agent started is
/// an empty slot; an hour it spent waiting is a zero, drawn as a tick, because
/// those are different facts.
private struct TokenHistory: View {
    let title: String
    let usage: TokenSnapshot.Usage
    let now: Date
    var tint: Color = Theme.trend

    @State private var probe: TrendGraph.Probe?

    private static let span = 24

    var body: some View {
        let hours = TokenHours.recent(Self.span, endingAt: now)
        let first = TokenHours.start(of: usage.since)
        let credits = usage.total.isCredits
        let columns: [Double?] = hours.map { hour in
            guard hour >= first else { return nil }
            let count = usage.hours[hour] ?? TokenCount()
            return credits ? count.credits : Double(count.total)
        }
        let recent = usage.hours.total(from: hours.first ?? 0)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(tint)
                Text("24h")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                Text(reading(hours, credits: credits) ?? "\(TokenFormat.compact(recent)) in 24h")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(probe == nil ? Theme.subtle : tint)
            }
            TrendGraph(
                columns: columns,
                sliceSeconds: TokenHours.length,
                color: tint,
                zeroBased: true,
                onProbe: { probe = $0 }
            )
            .frame(height: 38)
            HStack {
                Text(Self.clock(hours.first))
                Spacer()
                Text("now")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    /// The hour under the pointer and what it held.
    private func reading(_ hours: [Int], credits: Bool) -> String? {
        guard let probe else { return nil }
        let index = hours.count - 1 - Int((probe.age / TokenHours.length).rounded())
        guard hours.indices.contains(index) else { return nil }
        let start = Self.clock(hours[index])
        let value = credits
            ? "\(ModelUse.compact(credits: probe.value)) credits"
            : TokenFormat.compact(Int(probe.value))
        return index == hours.count - 1 ? "\(value) this hour" : "\(start) · \(value)"
    }

    private static func clock(_ hour: Int?) -> String {
        guard let hour else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(hour))
            .formatted(date: .omitted, time: .shortened)
    }
}
