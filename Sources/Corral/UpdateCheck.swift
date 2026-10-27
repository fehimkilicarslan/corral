import AppKit
import Combine
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

/// The switch, the check and what it found.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(latest: String, at: Date)
        case available(UpdateCheck.Release, at: Date)
        case failed(String, at: Date)
    }

    /// Nil until asked.
    @Published private(set) var isEnabled: Bool?
    @Published private(set) var status: Status = .idle

    private var timer: Timer?
    /// Someone asked, so the check in flight answers even if it began on its own.
    private var answerAsked = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdateCheck.timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: UpdateCheck.settingKey) == nil
            ? nil : defaults.bool(forKey: UpdateCheck.settingKey)
    }

    /// At launch. Only a downloaded build asks or checks by itself: one made
    /// with `make app` or `swift run` is somebody's own, and a DMG is not what
    /// it is behind.
    func start() {
        guard BuildInfo.isReleaseBuild else { return }
        switch isEnabled {
        case nil:
            // A turn after the window is up, so the question has something to
            // sit in front of.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in ask() }
        case true?:
            check(manual: false)
            schedule()
        case false?:
            break
        }
    }

    /// The question, once.
    private func ask() {
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
            Corral can ask GitHub whether a newer version is out, when it opens and \
            once a day while it stays open, and tell you when there is one.

            Each check is one HTTPS request to api.github.com for the latest release \
            of \(BuildInfo.repository). Nothing about your agents, projects or usage \
            goes with it; GitHub sees a request from your address, as it would for any \
            page you open. Corral never downloads or installs anything itself.

            You can change this in Settings. Check for Updates… in the Corral menu \
            works either way.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        NSApp.activate(ignoringOtherApps: true)
        setEnabled(alert.runModal() == .alertFirstButtonReturn)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: UpdateCheck.settingKey)
        isEnabled = on
        timer?.invalidate()
        timer = nil
        if on {
            check(manual: false)
            schedule()
        } else {
            status = .idle
        }
    }

    /// Hourly, asking only once a day has passed: a timer a day long would
    /// lose the day the Mac spent asleep.
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let last = UserDefaults.standard.object(forKey: UpdateCheck.lastCheckedKey) as? Date
                if UpdateCheck.isDue(lastChecked: last) { UpdateChecker.shared.check(manual: false) }
            }
        }
    }

    /// Ask GitHub. A check you asked for always answers, up to date or not; an
    /// automatic one speaks only when there is something new, and only once
    /// for each release.
    func check(manual: Bool) {
        if manual { answerAsked = true }
        if case .checking = status { return }
        status = .checking
        var request = URLRequest(url: UpdateCheck.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub refuses a request without one; this one says no more than
        // the name.
        request.setValue("Corral", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = code == 200 ? data.flatMap(UpdateCheck.release(from:)) : nil
            let reason = error?.localizedDescription
                ?? (code == 200 ? "GitHub's answer could not be read." : "GitHub answered \(code).")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UpdateChecker.shared.finish(release: release, reason: reason)
                }
            }
        }.resume()
    }

    private func finish(release: UpdateCheck.Release?, reason: String) {
        let manual = answerAsked
        answerAsked = false
        let now = Date()
        guard let release else {
            status = .failed(reason, at: now)
            if manual { tell("Could not check for updates", reason) }
            return
        }
        UserDefaults.standard.set(now, forKey: UpdateCheck.lastCheckedKey)
        guard UpdateCheck.isNewer(release.version, than: BuildInfo.version) else {
            status = .upToDate(latest: release.version, at: now)
            if manual {
                tell(
                    "Corral is up to date",
                    BuildInfo.isReleaseBuild
                        ? "\(BuildInfo.version) is the latest release."
                        : "The latest release is \(release.version). This is a local build, "
                            + "\(BuildInfo.version), so there is nothing to update it to."
                )
            }
            return
        }
        status = .available(release, at: now)
        let defaults = UserDefaults.standard
        // Turned off while the request was out: it may say what it found in
        // Settings, but not interrupt anyone with it.
        if !manual, isEnabled != true || defaults.string(forKey: UpdateCheck.offeredKey) == release.version {
            return
        }
        defaults.set(release.version, forKey: UpdateCheck.offeredKey)
        offer(release)
    }

    func offer(_ release: UpdateCheck.Release) {
        let alert = NSAlert()
        alert.messageText = "Corral \(release.version) is out"
        alert.informativeText = "You have \(BuildInfo.version). The release page has the DMG, "
            + "what changed and how it was signed. Quit Corral before you replace it."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    /// One line on where things stand, for Settings.
    func summary(now: Date = Date()) -> String {
        func ago(_ at: Date) -> String {
            let age = now.timeIntervalSince(at)
            return age < 90 ? "just now" : "\(age.durationString) ago"
        }
        switch status {
        case .idle:
            return isEnabled == true ? "Not checked yet." : "Off. Nothing is sent."
        case .checking:
            return "Asking GitHub now."
        case .upToDate(let latest, let at):
            return BuildInfo.isReleaseBuild
                ? "\(BuildInfo.version) is the latest. Checked \(ago(at))."
                : "The latest release is \(latest); this is a local build. Checked \(ago(at))."
        case .available(let release, let at):
            return "\(release.version) is out; you have \(BuildInfo.version). Checked \(ago(at))."
        case .failed(let reason, let at):
            return "\(reason) Tried \(ago(at))."
        }
    }

    private func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
