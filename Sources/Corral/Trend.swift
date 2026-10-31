import SwiftUI

/// A small history graph: discrete columns on a faint grid.
///
/// Deliberately an instrument readout rather than an infographic. This app's
/// whole claim is that it is Activity Monitor for agents, and Activity
/// Monitor's own CPU history is bars on a graticule — a filled gradient curve
/// would be the wrong dialect, and at this size it also reads as one soft blob
/// where the point is to see individual movements.
///
/// Buckets are resampled to a fixed column count so a 3-hour range and a
/// 15-minute one draw the same number of bars at the same width, instead of
/// the longer range collapsing into a solid block.
struct TrendGraph: View {
    /// One column, read off under the pointer.
    struct Probe: Equatable {
        let value: Double
        /// How far back the column sits, measured from the graph's right edge.
        let age: TimeInterval
    }

    /// One slot per slice, oldest first; nil where nothing was recorded.
    /// Built by `TrendBuffer.columns(_:now:)` for the header.
    let columns: [Double?]
    /// How much time one column covers, so a probe can say how far back it
    /// sits. The header's ranges set it; the token history uses an hour.
    let sliceSeconds: TimeInterval
    var color: Color = Theme.trend
    /// Forces the y-axis to start at zero. Right for counts, where a floor of
    /// zero is meaningful; wrong for memory, where every agent holds a hundred
    /// megabytes and a zero floor would flatten every real change into nothing.
    var zeroBased = false
    /// Fires as the pointer moves across the columns, and once with nil when it
    /// leaves.
    var onProbe: ((Probe?) -> Void)?
    /// A second series drawn faint behind the bars, on the same scale. The
    /// token history puts each hour's tokens here, behind what they cost, so
    /// the share that cost anything is the coloured part of a grey bar.
    var backdrop: [Double?]?
    /// A column to mark as if pointed at, so two graphs over the same hours
    /// can share one pointer.
    var highlighted: Int?

    @State private var hovered: Int?

    init(
        columns: [Double?],
        range: TrendRange,
        color: Color = Theme.trend,
        zeroBased: Bool = false,
        onProbe: ((Probe?) -> Void)? = nil
    ) {
        self.init(
            columns: columns, sliceSeconds: range.sliceSeconds,
            color: color, zeroBased: zeroBased, onProbe: onProbe
        )
    }

    init(
        columns: [Double?],
        sliceSeconds: TimeInterval,
        color: Color = Theme.trend,
        zeroBased: Bool = false,
        backdrop: [Double?]? = nil,
        highlighted: Int? = nil,
        onProbe: ((Probe?) -> Void)? = nil
    ) {
        self.columns = columns
        self.sliceSeconds = sliceSeconds
        self.color = color
        self.zeroBased = zeroBased
        self.backdrop = backdrop
        self.highlighted = highlighted
        self.onProbe = onProbe
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let anything = columns.contains { $0 != nil }
                    || (backdrop ?? []).contains { $0 != nil }
                guard anything else { return }
                draw(grid: context, size: size)
                draw(bars: context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    probe(at: location, width: geometry.size.width)
                case .ended:
                    if hovered != nil { hovered = nil }
                    onProbe?(nil)
                }
            }
        }
    }

    // ─ Pointer ──────────────────────────────────────────────────────────────

    private func probe(at location: CGPoint, width: CGFloat) {
        guard width > 0, !columns.isEmpty else { return }
        let slot = width / CGFloat(columns.count)
        let index = min(max(Int(location.x / slot), 0), columns.count - 1)
        if hovered != index { hovered = index }
        guard let value = columns[index] else {
            // An empty slot: nothing was recorded for that moment, and there is
            // nothing honest to report for it.
            onProbe?(nil)
            return
        }
        onProbe?(Probe(
            value: value,
            age: Double(columns.count - 1 - index) * sliceSeconds
        ))
    }

    // ─ Drawing ──────────────────────────────────────────────────────────────

    private func draw(grid context: GraphicsContext, size: CGSize) {
        let ink = Color.primary.opacity(0.10)

        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: (size.height - 1) / 2))
        midline.addLine(to: CGPoint(x: size.width, y: (size.height - 1) / 2))
        context.stroke(
            midline,
            with: .color(ink),
            style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5])
        )

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.25))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.25))
        context.stroke(baseline, with: .color(ink), lineWidth: 0.5)
    }

    private func draw(bars context: GraphicsContext, size: CGSize) {
        let values = columns.compactMap { $0 }
        let behind = (backdrop ?? []).compactMap { $0 }
        // One scale for both series, or the coloured part of a bar would
        // stop meaning a part of it. A backdrop is a count, so it starts at
        // zero whatever `zeroBased` says.
        let scale = TrendScale(
            top: max(values.max() ?? 0, behind.max() ?? 0),
            bottom: zeroBased || backdrop != nil ? 0 : (values.min() ?? 0)
        )

        let slot = size.width / CGFloat(columns.count)
        let barWidth = max(1, slot - 1)
        // The baseline owns the bottom half-pixel; bars sit on it.
        let plotHeight = size.height - 1
        let marked = hovered ?? highlighted

        func height(of value: Double) -> CGFloat {
            // A minimum of one pixel: a genuine zero still leaves a tick, so an
            // empty slot and a zero one do not look the same.
            max(1, CGFloat(scale.fraction(of: value)) * plotHeight)
        }

        for (index, value) in columns.enumerated() {
            let x = CGFloat(index) * slot

            // The crosshair is drawn over empty slots too, so the pointer never
            // seems to fall off the graph.
            if index == marked {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: max(barWidth, 1.5), height: size.height)),
                    with: .color(Color.primary.opacity(0.10))
                )
            }

            if let backdrop, backdrop.indices.contains(index), let under = backdrop[index] {
                let tall = height(of: under)
                context.fill(
                    Path(CGRect(x: x, y: plotHeight - tall, width: barWidth, height: tall)),
                    with: .color(Color.primary.opacity(0.16))
                )
            }

            guard let value else { continue }
            let tall = height(of: value)
            let rect = CGRect(x: x, y: plotHeight - tall, width: barWidth, height: tall)
            let emphasised = index == columns.count - 1 || index == marked
            context.fill(Path(rect), with: .color(color.opacity(emphasised ? 1.0 : 0.55)))
        }
    }
}
