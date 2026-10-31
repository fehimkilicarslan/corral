import Foundation

/// Where each ring sits, in one place.
///
/// The rail is laid out by SwiftUI and hit-tested by AppKit, so the two have to
/// agree about it exactly. Rather than have each measure separately and drift,
/// both read these.
enum RailLayout {
    static let itemHeight: CGFloat = 66
    static let spacing: CGFloat = 15
    static let margin: CGFloat = 18

    /// How much of the screen's height the rail is kept away from at each end.
    /// Used to place it by its middle, so that opening and closing does not
    /// move it.
    static let railMargin: CGFloat = 60

    static func height(for count: Int) -> CGFloat {
        let items = max(1, count)
        return CGFloat(items) * itemHeight + CGFloat(items - 1) * spacing + margin * 2
    }

    /// The middle of one ring, measured down from the top of the rail.
    static func centre(of index: Int) -> CGFloat {
        margin + CGFloat(index) * (itemHeight + spacing) + itemHeight / 2
    }

    /// Which ring a point falls in, measured down from the top of the rail.
    static func index(atDepth y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let stride = itemHeight + spacing
        let offset = y - margin
        guard offset >= 0 else { return nil }
        let index = Int(offset / stride)
        guard index < count else { return nil }
        // Inside the gap between two rings is not inside either of them.
        return offset - CGFloat(index) * stride <= itemHeight ? index : nil
    }
}
