import AppKit
import SwiftUI

/// How you work with your agents: an archetype, the habits behind it as
/// badges, and where the next improvement is.
struct InsightsView: View {
    @EnvironmentObject private var insights: InsightsViewModel
    @State private var sharing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .onAppear { insights.refreshIfStale() }
        .sheet(isPresented: $sharing) {
            ShareSheet { sharing = false }
                .environmentObject(insights)
        }
    }

    // ─ Header ───────────────────────────────────────────────────────────────

    private var subtitle: String {
        if insights.scanning && insights.report == nil { return "reading your sessions…" }
        guard let report = insights.report, !report.isEmpty else { return "no sessions yet" }
        let sessions = "\(report.sessions) session\(report.sessions == 1 ? "" : "s")"
        return insights.scanning ? "\(sessions) · updating…" : "\(sessions) · \(report.projects) projects"
    }

    private var header: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }

            if let report = insights.report, !report.isEmpty {
                Divider().frame(height: 26).opacity(0.4)
                Stat(value: "\(Int(report.activeHours.rounded()).formatted())h", label: "active")
                Stat(value: report.prompts.formatted(), label: "prompts")
                if report.gitAvailable {
                    Stat(value: report.assistedCommits.formatted(), label: "commits", tint: Theme.Severity.active.color)
                }
                Stat(value: "\(insights.earned.count)", label: "badges", tint: BadgeTier.gold.color)
            }

            Spacer(minLength: 8)

            Picker("", selection: $insights.days) {
                ForEach(InsightsViewModel.ranges, id: \.self) { Text("\($0)d").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 138)
            .help("How far back to look")

            Button { insights.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(insights.scanning)
                .help("Read the sessions again")

            Button {
                sharing = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share card")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent(for: .claudeCode))
            .disabled(insights.report?.isEmpty ?? true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // ─ Content ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if let report = insights.report, !report.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ArchetypeHero(report: report)
                    ForEach(BadgeFamily.allCases, id: \.self) { family in
                        FamilySection(family: family, all: insights.badges, report: report)
                    }
                    if !insights.tips.isEmpty { GrowthSection(tips: insights.tips) }
                    PrivacyNote()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        } else if insights.scanning || insights.report == nil {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Reading your Claude Code and Codex sessions…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                Text("The first look reads every transcript once; after that only what changed.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "rosette")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.faint)
                Text("No sessions in the last \(insights.days) days")
                    .font(.system(size: 15, weight: .medium))
                Text("Insights reads Claude Code and Codex transcripts on this Mac.\n"
                    + "Work with an agent for a while and your habits show up here.")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.faint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// ─ Archetype ────────────────────────────────────────────────────────────────

private struct ArchetypeHero: View {
    @EnvironmentObject private var insights: InsightsViewModel
    let report: InsightReport

    private var tally: String {
        let earned = insights.earned
        return [BadgeTier.gold, .silver, .bronze].compactMap { tier in
            let n = earned.filter { $0.tier == tier }.count
            return n > 0 ? "\(n) \(tier.title.lowercased())" : nil
        }.joined(separator: " · ")
    }

    private var rhythm: String {
        var parts: [String] = []
        if let hour = report.peakHour { parts.append("busiest at \(String(format: "%02d:00", hour))") }
        if let day = report.busiestWeekday { parts.append("on \(day)s") }
        if report.currentStreak > 1 { parts.append("\(report.currentStreak)-day streak going") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 16) {
            DitherPlate(
                scene: ArtScene.of(insights.archetype),
                params: .of(insights.archetype, badges: insights.badges, report: report),
                ink: .accent,
                cell: 2.6
            )
            .frame(width: 112, height: 80)
            .background(Theme.accent(for: .claudeCode).opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.accent(for: .claudeCode).opacity(0.3), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR LAST \(insights.days) DAYS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.faint)
                Text(insights.archetype.title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(insights.archetype.line)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtle)
                if !rhythm.isEmpty {
                    Text(rhythm)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            if !tally.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(insights.earned.prefix(6)) { badge in
                            // Coarser cells than a tile's: at this size a fine
                            // dither is noise, a coarse one is still a picture.
                            BadgeArt(badge: badge, report: report, cell: 2.2)
                                .frame(width: 30, height: 30)
                                .background(badge.tier.color.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .help("\(badge.title) · \(badge.tier.title)")
                        }
                    }
                    Text(tally)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.rowBackground.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// ─ Badges ───────────────────────────────────────────────────────────────────

private struct FamilySection: View {
    let family: BadgeFamily
    let all: [Badge]
    let report: InsightReport

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 320), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(family.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(family.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(all.enumerated()).filter { $0.element.family == family }, id: \.element.id) { item in
                    BadgeTile(badge: item.element, figure: item.offset + 1, report: report)
                }
            }
        }
    }
}

/// A habit, its plate and how far along it is. Clicking it opens the ladder
/// behind the number, since a tile that lights up under the pointer had
/// better do something when pressed.
private struct BadgeTile: View {
    @EnvironmentObject private var insights: InsightsViewModel
    let badge: Badge
    let figure: Int
    let report: InsightReport
    @State private var hovering = false
    @State private var showing = false

    /// `testFirst` → `test-first`: the plate's label, in the voice of a
    /// figure in a technical manual.
    private var caption: String {
        let name = badge.id.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
        }
        return String(format: "FIG.%02d", figure) + " · " + name
    }

    var body: some View {
        Button { showing.toggle() } label: { tile }
            .buttonStyle(PressableStyle())
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                BadgeDetail(badge: badge, report: report, tip: insights.tips.first { $0.id == badge.id })
            }
            .accessibilityHint("Shows where each tier starts")
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            BadgeArt(badge: badge, report: report)
                .frame(height: 78)
                .frame(maxWidth: .infinity)
                .background(badge.tier.color.opacity(badge.tier > .locked ? 0.07 : 0.025))
                .overlay(alignment: .topTrailing) {
                    Pill(text: badge.hasData ? badge.tier.title : "No data yet", color: badge.tier.color,
                         filled: badge.tier > .locked)
                        .background(Capsule().fill(Theme.rowBackground.opacity(0.9)))
                        .padding(7)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(caption)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.subtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.rowBackground.opacity(0.9))
                        )
                        .padding(6)
                }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(badge.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(badge.value ?? "—")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(badge.tier > .locked ? Color.primary : Theme.subtle)
                Text(badge.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2, reservesSpace: true)
                if let next = badge.next {
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline)
                                Capsule()
                                    .fill(nextColor)
                                    .frame(width: proxy.size.width * badge.progress)
                            }
                        }
                        .frame(height: 3)
                        Text(next)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.faint)
                    }
                } else {
                    Text("Top tier")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(BadgeTier.gold.color)
                        .padding(.top, 6)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowBackground.opacity(hovering ? 1 : 0.7))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .strokeBorder(badge.tier == .gold ? BadgeTier.gold.color.opacity(0.45) : Theme.hairline, lineWidth: 1)
        )
        .opacity(badge.hasData ? 1 : 0.7)
        .onHover { hovering = $0 }
    }

    private var nextColor: Color {
        (BadgeTier(rawValue: badge.tier.rawValue + 1) ?? .gold).color.opacity(0.8)
    }
}

/// What a tile opens: what the badge measures, where each tier starts, where
/// you stand on that ladder, and — when there is one — the thing to try next.
private struct BadgeDetail: View {
    let badge: Badge
    let report: InsightReport
    let tip: GrowthTip?

    private var rungs: [(tier: BadgeTier, bar: String)] {
        zip([BadgeTier.bronze, .silver, .gold], badge.ladder).map { ($0, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BadgeArt(badge: badge, report: report, cell: 3)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .background(badge.tier.color.opacity(badge.tier > .locked ? 0.08 : 0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(badge.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    Pill(text: badge.hasData ? badge.tier.title : "No data yet", color: badge.tier.color,
                         filled: badge.tier > .locked)
                }
                Text(badge.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The ladder, with you on the rung you have reached: a number
            // means more next to the bars it is judged against.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rungs.enumerated()), id: \.offset) { index, rung in
                    if badge.hasData && index == badge.tier.rawValue { you }
                    row(rung.tier, rung.bar)
                }
                if badge.hasData && badge.tier == .gold { you }
            }

            if !badge.hasData {
                Text("Not enough to go on yet. The badge opens once there are a few sessions behind it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if badge.lowerIsBetter {
                Text("Lower is better: each tier asks for less.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }

            if let tip {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tip.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.waiting)
                        .frame(width: 16)
                    Text(tip.text)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.waiting.opacity(0.08))
                )
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ tier: BadgeTier, _ bar: String) -> some View {
        let reached = badge.tier >= tier
        return HStack(spacing: 8) {
            Circle()
                .fill(tier.color)
                .frame(width: 7, height: 7)
            Text(tier.title)
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            Text(bar)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tier.color)
                .frame(width: 12)
                .opacity(reached ? 1 : 0)
        }
        .foregroundStyle(reached ? Color.primary : Theme.subtle)
        .padding(.vertical, 5)
    }

    private var you: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(badge.tier.color)
                .frame(width: 7)
            Text("You")
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 8)
            Text(badge.value ?? "—")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Color.clear.frame(width: 12, height: 1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, -8)
    }
}

extension BadgeTier {
    /// The metal as a UI colour. The light-mode values are darker: the gold
    /// that glows on a dark row is about 2:1 on a white one, a label you have
    /// to hunt for. Each light value clears 4.5:1 on white.
    var color: Color {
        switch self {
        case .locked: return Theme.faint
        case .bronze: return Theme.adaptive(light: Self.rgb(0.65, 0.35, 0.15), dark: Self.rgb(0.80, 0.50, 0.27))
        case .silver: return Theme.adaptive(light: Self.rgb(0.39, 0.44, 0.50), dark: Self.rgb(0.58, 0.63, 0.70))
        case .gold: return Theme.adaptive(light: Self.rgb(0.60, 0.42, 0.00), dark: Self.rgb(0.91, 0.69, 0.18))
        }
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

// ─ Next ─────────────────────────────────────────────────────────────────────

private struct GrowthSection: View {
    let tips: [GrowthTip]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Next")
                    .font(.system(size: 12, weight: .semibold))
                Text("Measurable habits still below silver, and one thing to try for each.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
            VStack(spacing: 6) {
                ForEach(tips) { tip in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: tip.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.waiting)
                            .frame(width: 18)
                        Text(tip.text)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.waiting.opacity(0.07))
                    )
                }
            }
        }
    }
}

private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 10.5))
            Text("Read from the Claude Code and Codex transcripts on this Mac, and from git in the "
                + "repositories they ran in. Nothing is uploaded. Corral keeps counts between looks, "
                + "never what was said, and the share card carries only what is on it.")
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.faint)
        .padding(.top, 2)
    }
}
