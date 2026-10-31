import Foundation

/// How far back the header sparklines look.
enum TrendRange: String, CaseIterable, Identifiable {
    case fifteenMinutes, hour, threeHours

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .hour: return 3_600
        case .threeHours: return 10_800
        }
    }

    var label: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .hour: return "1h"
        case .threeHours: return "3h"
        }
    }

    /// How much time one column covers. Chosen so every range draws a similar
    /// number of columns — a fixed slice across all three would make the
    /// 15-minute view six bars wide or the 3-hour view a thousand.
    var sliceSeconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 10
        case .hour: return 30
        case .threeHours: return 60
        }
    }

    /// Columns in the grid. Fixed for the range, whatever history exists.
    var columnCount: Int { Int(seconds / sliceSeconds) }

    /// Clicking the header cycles through the ranges rather than spending a
    /// control on something most people set once.
    var next: TrendRange {
        switch self {
        case .fifteenMinutes: return .hour
        case .hour: return .threeHours
        case .threeHours: return .fifteenMinutes
        }
    }
}

/// Rolling history of one header number.
///
/// Samples arrive every two seconds and are averaged into 10-second buckets;
/// three hours of them are kept, the longest range the header offers.
///
/// Buckets are stored with their absolute index rather than as a plain array,
/// so a gap is a real gap. A Mac that slept for an hour did not hold a steady
/// value through it, and drawing a flat line across that stretch would be a
/// claim Corral cannot make.
struct TrendBuffer {
    /// The finest slice any range asks for, so every range can be built by
    /// aggregating buckets rather than interpolating between them.
    static let bucketSeconds: TimeInterval = 10

    struct Bucket: Equatable {
        let index: Int
        let value: Double
    }

    private(set) var buckets: [Bucket] = []

    private var openIndex: Int?
    private var openSum = 0.0
    private var openCount = 0

    /// The in-progress bucket, so the rightmost point tracks live rather than
    /// snapping into place every 30 seconds.
    var live: Double? { openCount > 0 ? openSum / Double(openCount) : nil }

    var latest: Double? { live ?? buckets.last?.value }

    mutating func record(_ value: Double, at date: Date = Date()) {
        let index = Int(date.timeIntervalSince1970 / Self.bucketSeconds)
        if let open = openIndex, open != index {
            buckets.append(Bucket(index: open, value: openSum / Double(max(openCount, 1))))
            openSum = 0
            openCount = 0
        }
        openIndex = index
        openSum += value
        openCount += 1

        let cutoff = index - Int(TrendRange.threeHours.seconds / Self.bucketSeconds)
        if let first = buckets.first, first.index < cutoff {
            buckets.removeAll { $0.index < cutoff }
        }
    }

    /// Buckets inside `range`, plus the live one, oldest first.
    func series(_ range: TrendRange) -> [Bucket] {
        guard let openIndex else { return buckets }
        let span = Int(range.seconds / Self.bucketSeconds)
        var result = buckets.filter { $0.index > openIndex - span }
        if let live { result.append(Bucket(index: openIndex, value: live)) }
        return result
    }

    /// True once there is enough history for a line to mean anything. Two
    /// points is a segment; one is a dot that reads as a flat trend.
    func hasShape(_ range: TrendRange) -> Bool { series(range).count >= 3 }

    /// Values on a fixed grid anchored at `now`: one slot per slice of `range`,
    /// oldest on the left, the live moment at the right edge.
    ///
    /// This is the difference between a graph and a picture of one. Spreading
    /// whatever history exists across the full width made five minutes of data
    /// fill a three-hour chart, so the axis said one thing and the bars another.
    /// Here a slot with no samples in it is nil and stays empty, and the graph
    /// fills in from the right as time passes — which is also what makes the
    /// three ranges comparable to each other.
    func columns(_ range: TrendRange, now: Date = Date()) -> [Double?] {
        let count = range.columnCount
        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)

        var all = buckets
        if let openIndex, let live { all.append(Bucket(index: openIndex, value: live)) }

        for bucket in all {
            let start = Double(bucket.index) * Self.bucketSeconds
            let age = now.timeIntervalSince1970 - start
            guard age >= 0 else { continue }
            let slot = count - 1 - Int(age / range.sliceSeconds)
            guard slot >= 0, slot < count else { continue }
            sums[slot] += bucket.value
            hits[slot] += 1
        }
        return (0..<count).map { hits[$0] == 0 ? nil : sums[$0] / Double(hits[$0]) }
    }
}

/// The header's trend lines, recorded together so they share a time axis.
struct Trends {
    var cpu = TrendBuffer()
    var memory = TrendBuffer()
    var agents = TrendBuffer()
    var projects = TrendBuffer()

    func series(for metric: TrendMetric) -> TrendBuffer {
        switch metric {
        case .cpu: return cpu
        case .memory: return memory
        case .agents: return agents
        case .projects: return projects
        }
    }
}

/// Which number the header graph is plotting.
///
/// One graph rather than one per figure: four thumbnails at this size say less
/// than a single readable chart, and the question is almost always about one
/// number at a time. CPU is the default because it is the one that made you
/// open the app.
enum TrendMetric: String, CaseIterable, Identifiable {
    case cpu, memory, agents, projects

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .agents: return "Agents"
        case .projects: return "Projects"
        }
    }

    /// Counts and CPU are measured from zero, so their axis starts there.
    /// Memory is not: every agent holds a hundred megabytes before it does
    /// anything, and a zero floor would flatten every real change into nothing.
    var zeroBased: Bool { self != .memory }
}

/// Where a value sits between the bottom of a graph and its top, 0 to 1.
///
/// The awkward case is a series with nothing to scale against, every value
/// the same. A steady 2.9 GB is a level, and sits on the midline rather than
/// on the floor or the ceiling. A steady zero is nothing: drawn on the
/// midline, a day in which an agent spent no tokens read as a day it spent
/// some every hour.
struct TrendScale {
    let top: Double
    let bottom: Double

    func fraction(of value: Double) -> Double {
        let range = top - bottom
        guard range >= .ulpOfOne else { return top == 0 ? 0 : 0.5 }
        return (value - bottom) / range
    }
}
