import Foundation

/// Where the usage panel lives, if anywhere.
enum PanelPlacement: String, CaseIterable, Identifiable {
    case top, right, left, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "Top of Screen"
        case .right: return "Right Edge"
        case .left: return "Left Edge"
        case .off: return "Off"
        }
    }

    var anchor: HUDAnchor? {
        switch self {
        case .top: return .top
        case .right: return .right
        case .left: return .left
        case .off: return nil
        }
    }
}
