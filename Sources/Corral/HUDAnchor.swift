import Foundation

/// Which screen edge the panel is attached to.
enum HUDAnchor: String, CaseIterable, Identifiable {
    case top, right, left

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "Top"
        case .right: return "Right Edge"
        case .left: return "Left Edge"
        }
    }

    /// The two side edges share one behaviour — a line that opens into a rail
    /// of rings when the pointer arrives — and differ only in which way the
    /// rail is uncovered and which side the popover sits on.
    var isRail: Bool { self != .top }
}
