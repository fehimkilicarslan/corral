import SwiftUI

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
                TokenTotals(usage: usage, tint: accent)
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
        let cost = (usage?.total.fullPrice ?? 0) > 0
            ? " Full price is the same tokens read fresh; from list-price ratios, not a bill."
            : ""
        return source + cache + cost + " Kept since the agent started."
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
    var tint: Color = Theme.trend

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

            // What the pile actually cost, in the only unit that compares
            // with it: tokens read at full price.
            if let share = total.costShare {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Costs what \(TokenFormat.compact(Int(total.fullPrice.rounded()))) tokens "
                        + "would at full price — \(TokenFormat.percent(share))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint)
                    if total.unpriced > 0 {
                        Text("\(TokenFormat.compact(total.unpriced)) from models Corral has no "
                            + "price for are left out of that.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.faint)
                    }
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
            Text(TokenFormat.percent(share))
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
///
/// Where the tokens can be priced it is two graphs over the same hours. The
/// first is every token, faint, with what they cost drawn over it on the same
/// scale — so the share that cost anything is the coloured part of the bar,
/// and in a long session it is a sliver. A sliver says *how little*, but not
/// *when*: the hour that cost most and the hour that read most are often not
/// the same hour. So the second graph is the cost alone, on a scale of its
/// own. One probe serves both.
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
        let counts: [TokenCount?] = hours.map { $0 >= first ? (usage.hours[$0] ?? TokenCount()) : nil }
        let credits = usage.total.isCredits
        // A history with no price in it — Kiro's, or one kept before costs
        // were counted — is drawn as it always was.
        let priced = !credits && usage.total.fullPrice > 0
        let tokens = counts.map { $0.map { Double($0.total) } }
        let costs = counts.map { $0.map(\.fullPrice) }
        let marked = Self.index(of: probe, among: hours)
        let window = usage.hours.total(from: hours.first ?? 0)

        VStack(alignment: .leading, spacing: 3) {
            heading(title, span: "24h", reading: tokenReading(
                marked, hours: hours, counts: counts, window: window, credits: credits
            ))
            TrendGraph(
                columns: credits ? counts.map { $0.map(\.credits) } : (priced ? costs : tokens),
                sliceSeconds: TokenHours.length,
                color: tint,
                zeroBased: true,
                backdrop: priced ? tokens : nil,
                highlighted: marked,
                onProbe: { probe = $0 }
            )
            .frame(height: 38)

            if priced {
                heading("COST", span: nil, reading: costReading(
                    marked, hours: hours, counts: counts, window: window
                ))
                .padding(.top, 4)
                TrendGraph(
                    columns: costs,
                    sliceSeconds: TokenHours.length,
                    color: tint,
                    zeroBased: true,
                    highlighted: marked,
                    onProbe: { probe = $0 }
                )
                .frame(height: 24)
            }

            HStack {
                Text(Self.clock(hours.first))
                Spacer()
                Text("now")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(Theme.faint)

            if priced { legend }
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

    private func heading(_ title: String, span: String?, reading: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(tint)
            if let span {
                Text(span)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 4)
            Text(reading)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(probe == nil ? Theme.subtle : tint)
                .lineLimit(1)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Color.primary.opacity(0.16), "tokens")
            swatch(tint.opacity(0.8), "cost, as tokens at full price")
        }
        .font(.system(size: 8.5))
        .foregroundStyle(Theme.faint)
        .padding(.top, 2)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    /// The hour under the pointer, or the whole window when there is none.
    private func tokenReading(
        _ marked: Int?, hours: [Int], counts: [TokenCount?], window: TokenCount, credits: Bool
    ) -> String {
        if let marked, let count = counts[marked] {
            let when = Self.when(marked, hours)
            if credits { return "\(when) · \(ModelUse.compact(credits: count.credits)) credits" }
            let share = count.costShare.map { " · \(TokenFormat.percent($0)) of full price" } ?? ""
            return "\(when) · \(TokenFormat.compact(count.total))" + share
        }
        if credits { return "\(ModelUse.compact(credits: window.credits)) credits in 24h" }
        let share = window.costShare.map { " · \(TokenFormat.percent($0)) of full price" } ?? ""
        return "\(TokenFormat.compact(window.total)) in 24h" + share
    }

    private func costReading(
        _ marked: Int?, hours: [Int], counts: [TokenCount?], window: TokenCount
    ) -> String {
        if let marked, let count = counts[marked] {
            return "\(Self.when(marked, hours)) · "
                + "\(TokenFormat.compact(Int(count.fullPrice.rounded()))) at full price"
        }
        return "\(TokenFormat.compact(Int(window.fullPrice.rounded()))) at full price"
    }

    private static func index(of probe: TrendGraph.Probe?, among hours: [Int]) -> Int? {
        guard let probe else { return nil }
        let index = hours.count - 1 - Int((probe.age / TokenHours.length).rounded())
        return hours.indices.contains(index) ? index : nil
    }

    /// The rightmost column is the hour still running.
    private static func when(_ index: Int, _ hours: [Int]) -> String {
        index == hours.count - 1 ? "this hour" : clock(hours[index])
    }

    private static func clock(_ hour: Int?) -> String {
        guard let hour else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(hour))
            .formatted(date: .omitted, time: .shortened)
    }
}
