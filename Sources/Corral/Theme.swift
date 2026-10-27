import AppKit
import SwiftUI

/// One place for colour and type, so the window reads as a designed thing
/// rather than a stack of default controls.
enum Theme {

    // ─ Tool identity ────────────────────────────────────────────────────────

    /// Each product gets a colour, so a wall of rows is scannable before you
    /// have read a single word.
    static func accent(for tool: Tool) -> Color {
        switch tool {
        case .claudeCode, .claudeDesktop:
            return Color(red: 0.85, green: 0.47, blue: 0.34)   // terracotta
        case .codex:
            return Color(red: 0.16, green: 0.66, blue: 0.53)   // teal
        case .cursor, .cursorAgent:
            return Color(red: 0.42, green: 0.45, blue: 0.90)   // indigo
        case .copilot:
            return Color(red: 0.55, green: 0.58, blue: 0.64)   // graphite
        case .windsurf:
            return Color(red: 0.30, green: 0.70, blue: 0.85)   // cyan
        case .kiroCLI, .kiroCrew, .kiro:
            return Color(red: 0.58, green: 0.36, blue: 0.94)   // violet
        case .antigravity:
            return Color(red: 0.25, green: 0.62, blue: 0.96)   // sky blue
        }
    }

    // ─ Idle severity ────────────────────────────────────────────────────────

    /// Idle time is the number people act on, so it is colour-coded the way a
    /// dashboard would: fine, worth a look, definitely forgotten.
    enum Severity {
        case active, recent, stale, abandoned

        static func of(_ activity: Activity) -> Severity {
            guard let idle = activity.idleFor else { return .active }
            if !activity.isIdle { return .active }
            if idle < 3_600 { return .recent }
            if idle < 86_400 { return .stale }
            return .abandoned
        }

        var color: Color {
            switch self {
            case .active: return Color(red: 0.24, green: 0.70, blue: 0.44)
            case .recent: return Color(red: 0.55, green: 0.58, blue: 0.64)
            case .stale: return Color(red: 0.90, green: 0.66, blue: 0.24)
            case .abandoned: return Color(red: 0.87, green: 0.36, blue: 0.33)
            }
        }

        var label: String {
            switch self {
            case .active: return "working"
            case .recent: return "idle"
            case .stale: return "idle"
            case .abandoned: return "abandoned"
            }
        }
    }

    // ─ Agent state ──────────────────────────────────────────────────────────

    /// Colour and wording for what a group is doing. Five states, each one a
    /// different decision: leave it, leave it, ignore it, look at it, kill it.
    static func color(for state: AgentState) -> Color {
        switch state {
        case .starting: return Severity.recent.color
        case .working: return Severity.active.color
        case .waiting: return waiting
        case .idle: return Severity.recent.color
        case .stale: return Severity.stale.color
        case .abandoned: return Severity.abandoned.color
        }
    }

    /// Blue for "busy on something it started". Deliberately not green: the
    /// agent itself is parked, and deliberately not amber: nothing is wrong.
    static let waiting = Color(red: 0.28, green: 0.56, blue: 0.90)

    /// Sparkline ink. A toned-down terminal green — recognisably the colour of
    /// scrolling text, without the neon that would vibrate on a light window.
    static let trend = Color(red: 0.18, green: 0.72, blue: 0.42)

    // ─ Surfaces ─────────────────────────────────────────────────────────────

    static let rowCorner: CGFloat = 10

    static var rowBackground: Color { Color(nsColor: .controlBackgroundColor) }

    /// AppKit's own separator and secondary label, so that "Increase
    /// contrast" in System Settings strengthens them along with every other
    /// line and label on screen. A fixed opacity of `.primary` never hears
    /// about that setting.
    static var hairline: Color { Color(nsColor: .separatorColor) }
    static var subtle: Color { Color(nsColor: .secondaryLabelColor) }

    /// The quietest text that still carries meaning: captions, paths, the
    /// time something happened.
    ///
    /// Not AppKit's tertiary label, which is a quarter-strength grey meant for
    /// placeholders and comes out near 2:1 on a white row. This sits between
    /// secondary and tertiary, a touch heavier in light mode, where the same
    /// opacity reads weaker, and close to secondary once contrast is raised.
    static let faint = adaptive(
        light: NSColor.black.withAlphaComponent(0.45),
        dark: NSColor.white.withAlphaComponent(0.42),
        lightHigh: NSColor.black.withAlphaComponent(0.68),
        darkHigh: NSColor.white.withAlphaComponent(0.68)
    )

    /// A colour with a value per appearance. AppKit resolves it against
    /// whatever the view is drawn in — SwiftUI's colour scheme, a forced-dark
    /// share card — and takes the high-contrast values, which fall back to the
    /// plain ones, while "Increase contrast" is on. That setting is read from
    /// the workspace as well as the appearance, because only the system can
    /// make a high-contrast appearance: one asked for by name is plain Aqua.
    static func adaptive(
        light: NSColor, dark: NSColor, lightHigh: NSColor? = nil, darkHigh: NSColor? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let high = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            switch (isDark, high) {
            case (false, false): return light
            case (true, false): return dark
            case (false, true): return lightHigh ?? light
            case (true, true): return darkHigh ?? dark
            }
        })
    }

    /// Window backdrop — a very slight vertical wash keeps a dense list from
    /// looking like a spreadsheet.
    static var windowBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor).opacity(0.6),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// ─ Small shared views ───────────────────────────────────────────────────────

/// A pill — used for counts, idle state and roles.
struct Pill: View {
    let text: String
    var color: Color = Theme.subtle
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(color.opacity(filled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(filled ? 0.35 : 0.0), lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

/// A labelled number in the header.
///
/// When it is one of the figures the graph can plot, it doubles as the graph's
/// selector: the underline marks which one is on screen, so the control and its
/// output are not in two different places.
struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .primary
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(selected ? Theme.trend : Theme.faint)
            // Reserved whether or not it is drawn, so selecting a figure does
            // not nudge the row's height.
            Rectangle()
                .fill(selected ? Theme.trend : .clear)
                .frame(height: 1.5)
                .padding(.top, 2)
        }
        .fixedSize()
    }
}


/// A pointing-hand cursor over something clickable.
///
/// macOS 15 has `.pointerStyle(.link)`; this app runs on 13, so the cursor is
/// pushed and popped by hand. Push and pop must balance — one stray push leaves
/// the whole app stuck with a hand cursor — so the state is tracked rather than
/// assumed, and a view that disappears while hovered pops on its way out.
private struct PointerCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(PointerCursor()) }
}

/// A surface you click — a row, a tile, the graph — that answers the moment
/// the button goes down.
///
/// `onTapGesture` hears nothing until the button comes back up, so a row
/// gave no sign it had been pressed until it had already opened. This shades
/// the surface on the press itself, lifts it quickly on release, and, being a
/// real button, lets a drag off the surface cancel. It does not shrink: AppKit's
/// own controls never scale under the pointer, and a list of rows that did
/// would feel like a web page rather than a Mac app.
struct PressableStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.rowCorner
    /// Told when a press starts and ends, for a surface whose shading belongs
    /// to something larger than the button — a row whose Stop button sits
    /// outside it. With this set, the style draws nothing itself.
    var pressed: Binding<Bool>?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if pressed == nil {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.pressedShade.opacity(configuration.isPressed ? 1 : 0))
                        .allowsHitTesting(false)
                }
            }
            // On instantly, off in a blink: the press is the user's, the
            // release is the interface catching up.
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed?.wrappedValue = $0 }
    }
}

extension View {
    /// This view as the label of a `PressableStyle` button, for a surface
    /// already laid out as a whole that should simply become clickable.
    func pressable(cornerRadius: CGFloat = Theme.rowCorner, action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(PressableStyle(cornerRadius: cornerRadius))
    }
}

extension Theme {
    /// Laid over a surface while it is held down.
    static var pressedShade: Color { Color.primary.opacity(0.07) }
}

/// The search field, shared by both panes.
struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Theme.hairline, lineWidth: 1)
        )
        .frame(width: 210)
        // ⌘F is where everyone's hand already goes.
        .background(
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
    }
}

/// Shown when a search matched nothing, so an empty pane never reads as
/// "nothing is running".
struct NoMatches: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("Nothing matches \u{201C}\(query)\u{201D}")
                .font(.system(size: 13, weight: .medium))
            Button("Clear search", action: clear)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
