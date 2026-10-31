import AppKit
import Foundation

/// Turns on the one thing an agent will not tell you unless asked.
///
/// This writes to files Corral does not own — the user's own
/// `~/.claude/settings.json` and `~/.cursor/cli-config.json` — which is why
/// every part of it is arranged around being reversible and being understood
/// first. It asks, in a dialog that names the exact setting it is about to add.
/// It keeps a timestamped copy of the file beside it. It edits the text rather
/// than re-serialising the JSON, so the rest of the file comes out byte for
/// byte as it went in. And it refuses outright to touch a status line somebody
/// else already set up.
@MainActor
extension StatusLineSetup {

    // ─ Asking ───────────────────────────────────────────────────────────────

    /// Offer to install it, and do so if the answer is yes.
    static func offer(_ target: Target) {
        switch state(of: target) {
        case .installed:
            tell(
                "Already set up",
                "\(target.name) is already reporting to Corral. Its figures appear "
                    + "once a session makes a request."
            )

        case .unreadable:
            tell(
                "Cannot read those settings",
                "Corral could not parse \(short(target.file)), so it will not write to "
                    + "it. Fix or remove the file and try again."
            )

        case .taken(let existing):
            // Chaining two status lines means running someone else's command
            // and passing its output through, and getting that wrong breaks the
            // line they already rely on. Corral says what it would do instead.
            let alert = NSAlert()
            alert.messageText = "You already have a status line"
            alert.informativeText = """
                \(target.name) is set to run:

                \(existing)

                Corral will not replace it. To use both, add this to the end of your \
                own command so it sees the same input:

                \(command(for: target))
                """
            alert.addButton(withTitle: "Copy Corral's Command")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command(for: target), forType: .string)
            }

        case .absent:
            let alert = NSAlert()
            alert.messageText = "Let \(target.name) report its usage?"
            alert.informativeText = """
                \(target.name) does not write these figures to disk, but it does hand \
                them to a status line command. Corral can be that command.

                This adds one setting to \(short(target.file)):

                "statusLine": { "type": "command", "command": … }

                \(target.provides)

                Corral keeps only the session id, the working directory, the context \
                size and any limit percentages — not the transcript path, the branch, \
                or anything you are working on. A copy of the file is saved first.

                Your status line will show the project and those figures.
                """
            alert.addButton(withTitle: "Add It")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            report(install(target), target: target)
        }
    }

    // ─ Telling ──────────────────────────────────────────────────────────────

    private static func report(_ outcome: Outcome, target: Target) {
        switch outcome {
        case .added(let backup):
            var text = "Sessions started from now on will report to Corral. Figures "
                + "appear once a session makes its first request; on plans with nothing "
                + "metered, the limits never appear, and that is not an error."
            if let backup {
                text += "\n\nYour previous settings are in \(backup.lastPathComponent)."
            }
            tell("\(target.name) is set up", text)
        case .failed(let reason):
            tell("Nothing was changed", reason)
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// `~`-relative, because that is how a person refers to these files.
    private static func short(_ file: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return file.path.hasPrefix(home)
            ? "~" + file.path.dropFirst(home.count)
            : file.path
    }
}
