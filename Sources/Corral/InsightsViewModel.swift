import Foundation
import SwiftUI

/// The Insights tab's state: one scan of the transcripts, folded into a
/// report for whichever range is picked.
///
/// Changing the range does not read anything again. The scan always covers the
/// longest range, so 7, 30 and 90 days are three folds over the same facts.
@MainActor
final class InsightsViewModel: ObservableObject {

    static let ranges = [7, 30, 90]
    private static let rangeKey = "insightsDays"

    @Published var days: Int {
        didSet {
            UserDefaults.standard.set(days, forKey: Self.rangeKey)
            rebuild()
        }
    }
    @Published private(set) var report: InsightReport?
    @Published private(set) var badges: [Badge] = []
    @Published private(set) var archetype = ArchetypeCatalog.explorer
    @Published private(set) var tips: [GrowthTip] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?

    private var scan: InsightStore.Scan?
    private let store: InsightStore

    /// A scan older than this is redone when the tab is opened again.
    private static let freshness: TimeInterval = 10 * 60

    init(store: InsightStore = InsightStore()) {
        self.store = store
        let saved = UserDefaults.standard.integer(forKey: Self.rangeKey)
        days = Self.ranges.contains(saved) ? saved : 30
    }

    var earned: [Badge] { BadgeCatalog.earned(badges) }

    func refreshIfStale() {
        guard let scannedAt else { return refresh() }
        if Date().timeIntervalSince(scannedAt) > Self.freshness { refresh() }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let store = self.store
        Task.detached(priority: .utility) {
            let scan = store.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scan = scan
                self.scanning = false
                self.scannedAt = Date()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        guard let scan else { return }
        let report = InsightReport.build(scan, days: days)
        let badges = BadgeCatalog.evaluate(report)
        self.report = report
        self.badges = badges
        archetype = ArchetypeCatalog.pick(badges)
        tips = GrowthEdge.tips(badges)
    }
}
