import Foundation

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

    /// A share as a whole percentage — except that something which is there
    /// never reads as 0%: six million tokens of output is not nothing,
    /// whatever share of five billion it rounds to.
    static func percent(_ share: Double) -> String {
        share > 0 && share < 0.005 ? "<1%" : String(format: "%.0f%%", (share * 100).rounded())
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
