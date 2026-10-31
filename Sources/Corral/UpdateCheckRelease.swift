import Foundation

/// Whether a newer Corral is out, as GitHub's releases page says.
///
/// Arranged like `KiroAccountSetup`: nothing is sent until a dialog has said
/// what goes where and the person has said yes. A downloaded build asks once,
/// the first time it opens; the answer is a switch in Settings from then on.
/// Saying yes means one HTTPS request to api.github.com when Corral opens and
/// once a day while it stays open, which is the whole of it — no identifier,
/// no version, nothing about the agents, and nothing downloaded or installed.
/// A newer release is offered once, with a link to its page, where the DMG
/// and what changed are.
///
/// The pure parts — reading GitHub's answer, ordering versions, when a check
/// is due — live here; `UpdateChecker` holds the state and the dialogs.
enum UpdateCheck {

    /// Absent until the question has been answered, so "never asked" and "no"
    /// stay two different things.
    static let settingKey = "checksForUpdates"
    static let lastCheckedKey = "updatesLastChecked"
    /// The newest version already offered, so an automatic check offers each
    /// release once rather than once a day.
    static let offeredKey = "updatesOffered"

    static let interval: TimeInterval = 24 * 60 * 60
    static let timeout: TimeInterval = 15

    static var endpoint: URL {
        URL(string: "https://api.github.com/repos/\(BuildInfo.repository)/releases/latest")!
    }

    struct Release: Equatable {
        /// Without the tag's leading "v": `0.1.27`.
        let version: String
        /// The release page, which carries the DMG, its SHA-256 and how it
        /// was signed.
        let page: URL
    }

    /// GitHub's answer for the latest release. Drafts and pre-releases are not
    /// what `latest` returns, but they are refused here too, in case it ever
    /// does.
    static func release(from data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              page.host == "github.com",
              object["draft"] as? Bool != true,
              object["prerelease"] as? Bool != true,
              components(tag) != nil
        else { return nil }
        return Release(version: normalised(tag), page: page)
    }

    /// True when `candidate` is a later release than `current`. A local build's
    /// `+3` is set aside, so `0.1.25+3` is behind `0.1.26` and level with
    /// `0.1.25`. Either side unreadable — `dev`, from `swift run` — is never
    /// behind.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    private static func normalised(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        return text
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = normalised(version).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        return numbers
    }
}
