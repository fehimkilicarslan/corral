import AppKit
import SwiftUI

/// Corral's settings, in one window, behind ⌘, where a Mac user looks first.
///
/// They used to live in two menus at once — the app menu and the menu bar
/// item — under slightly different names, with nothing behind ⌘, at all. The
/// one setting a first-time user most needs, turning on usage reporting, sat
/// in a submenu between the panel's position and the colour scheme.
///
/// An AppKit window holding a SwiftUI view rather than SwiftUI's own
/// `Settings` scene, because the menu bar item has to be able to open it, and
/// on current macOS a scene of that kind opens only from a SwiftUI view that
/// is on screen — which, for an app that mostly runs with its window closed,
/// is usually none of them.
@MainActor
enum SettingsWindow {

    /// How `AppState.openWindow` tells this window from the main one.
    static let identifier = NSUserInterfaceItemIdentifier("CorralSettings")

    private static var window: NSWindow?

    static func show() {
        let window = self.window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.identifier = identifier
        window.title = "Corral Settings"
        window.styleMask = [.titled, .closable]
        // Kept, not rebuilt, so it opens where it was left.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CorralSettings")
        return window
    }
}

/// What the window shows.
struct SettingsView: View {
    @ObservedObject private var panels = PanelSettings.shared
    @ObservedObject private var appearance = AppearanceController.shared
    @ObservedObject private var kiro = KiroAccountSettings.shared
    @ObservedObject private var updates = UpdateChecker.shared

    /// Bumped whenever the window comes forward. The status lines live in other
    /// apps' settings files, which can change behind Corral's back, so what
    /// each row says is read again rather than remembered.
    @State private var looked = 0

    var body: some View {
        Form {
            Section {
                ForEach(StatusLineSetup.Target.all, id: \.tool) { target in
                    ReportingRow(target: target, looked: looked) { looked += 1 }
                }
                Toggle(isOn: Binding(
                    get: { kiro.isEnabled },
                    set: { on in on ? KiroAccountSetup.offer() : KiroAccountSetup.turnOff() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KiroAccountSetup.title)
                        Text("Asks Kiro's servers what the account has left, every five "
                            + "minutes — one of the two things in Corral that use the network, "
                            + "so it asks before it starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Usage reporting")
            } footer: {
                Text("Claude Code and Cursor tell a status line what is left of the account "
                    + "and how full each session is, and Corral can be that status line. "
                    + "Each asks first, shows the exact setting, and keeps a copy of the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Display") {
                Picker("Usage panel", selection: Binding(
                    get: { panels.placement },
                    set: { choice in
                        // The same rule the menus enforced: never turn off the
                        // last way back into the app.
                        if choice == .off && !panels.showsMenuBarItem { return NSSound.beep() }
                        panels.placement = choice
                    }
                )) {
                    ForEach(PanelPlacement.allCases) { Text($0.label).tag($0) }
                }

                Toggle(isOn: Binding(
                    get: { panels.showsMenuBarItem },
                    set: { on in
                        if !on && panels.wouldStrandTheApp(turningOffMenuBar: true) {
                            return NSSound.beep()
                        }
                        panels.showsMenuBarItem = on
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in menu bar")
                        if panels.placement == .off {
                            Text("Stays on while the usage panel is off — otherwise there "
                                + "would be no way back into Corral.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .disabled(panels.showsMenuBarItem && panels.wouldStrandTheApp(turningOffMenuBar: true))

                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updates") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { updates.isEnabled == true },
                        set: { updates.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically")
                            Text("Asks GitHub for the latest release when Corral opens and "
                                + "once a day. Nothing else is sent, and nothing is installed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(updates.summary())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Check Now") { updates.check(manual: true) }
                        .disabled(updates.status == .checking)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier == SettingsWindow.identifier else { return }
            looked += 1
        }
    }
}

/// One agent's status line: whether it reports, and the button that sets it up
/// when it does not.
private struct ReportingRow: View {
    let target: StatusLineSetup.Target
    /// Changes whenever the row should look at the file again. Being an input,
    /// a new value is enough to make SwiftUI read the state afresh.
    let looked: Int
    let lookAgain: () -> Void

    var body: some View {
        let state = StatusLineSetup.state(of: target)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                Text(target.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .installed:
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Severity.active.color)
            case .absent:
                Button("Set Up…") {
                    StatusLineSetup.offer(target)
                    lookAgain()
                }
            case .taken, .unreadable:
                Button("Details…") {
                    StatusLineSetup.offer(target)
                    lookAgain()
                }
            }
        }
    }
}
