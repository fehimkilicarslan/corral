import Foundation

/// What the menus and the Usage tab say about asking Kiro. Kept apart from
/// the dialog and the switch, which need AppKit and Combine, so that this
/// builds on Linux too.
@MainActor
enum KiroAccountSetup {

    static let title = "Ask Kiro for Account Usage"

    /// One sentence on where things stand, for the Usage tab.
    static func summary(now: Date = Date()) -> String {
        switch KiroAccountStore.shared.status {
        case .off:
            return "Not asked. Kiro keeps the balance on its servers; Corral can ask "
                + "for it every five minutes, using Kiro CLI's own sign-in, if you turn "
                + "that on. Apart from the update check, it is the only thing in Corral that uses "
                + "the network."
        case .asking:
            return "Asking Kiro's servers now."
        case .answered(let at):
            let age = now.timeIntervalSince(at)
            return "Asking Kiro's servers every five minutes. Last answer "
                + (age < 90 ? "just now." : "\(age.durationString) ago.")
        case .failed(let reason, let at):
            let age = now.timeIntervalSince(at)
            return "\(reason) Last tried \(age < 90 ? "just now" : "\(age.durationString) ago")."
        }
    }
}
