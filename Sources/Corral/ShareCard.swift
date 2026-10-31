import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The picture people post: archetype, best badges, a few totals.
///
/// Drawn at the 1.91:1 size X and LinkedIn crop link previews to, and always
/// dark, whatever the app's appearance — it is going onto someone else's feed.
/// Nothing on it names a project or quotes a prompt; it carries exactly what
/// the Insights tab shows at the top, and that is all that leaves the Mac,
/// and only when the person sends it.
struct ShareCardView: View {
    let report: InsightReport
    let archetype: Archetype
    let badges: [Badge]

    static let size = CGSize(width: 1200, height: 630)

    private let ink = Color.white
    private let accent = Theme.accent(for: .claudeCode)

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.11), Color(red: 0.12, green: 0.10, blue: 0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    mark
                    Text("Corral")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("· how I build with AI agents")
                        .font(.system(size: 22))
                        .foregroundStyle(ink.opacity(0.55))
                    Spacer()
                    Text("Last \(report.days) days")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(ink.opacity(0.55))
                }

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(archetype.title.uppercased())
                            .font(.system(size: 74, weight: .heavy, design: .rounded))
                            .tracking(1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(LinearGradient(
                                colors: [ink, accent], startPoint: .leading, endPoint: .trailing
                            ))
                        Text(archetype.line)
                            .font(.system(size: 26))
                            .foregroundStyle(ink.opacity(0.72))
                            .padding(.top, 2)

                        HStack(alignment: .top, spacing: 22) {
                            ForEach(BadgeCatalog.earned(badges).prefix(5)) { badge in
                                VStack(spacing: 8) {
                                    BadgeArt(badge: badge, report: report, cell: 3.2)
                                        .frame(width: 96, height: 96)
                                        .background(badge.tier.color.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(badge.tier.color.opacity(0.55), lineWidth: 1.5)
                                        )
                                    // A fixed two-line box, top-aligned, so every
                                    // tier label lands on the same line whether
                                    // the title above it took one line or two.
                                    Text(badge.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(height: 40, alignment: .top)
                                    Text(badge.tier.title.uppercased())
                                        .font(.system(size: 11.5, weight: .bold))
                                        .tracking(1)
                                        .foregroundStyle(badge.tier.color)
                                }
                                .frame(width: 128)
                            }
                        }
                        .padding(.top, 34)

                        Spacer(minLength: 0)

                        HStack(alignment: .bottom, spacing: 42) {
                            figure("\(Int(report.activeHours.rounded()).formatted())h", "active")
                            figure(report.sessions.formatted(), "sessions")
                            if report.gitAvailable { figure(report.assistedCommits.formatted(), "commits") }
                            figure("\(report.peakParallel)", "agents at once")
                        }
                    }
                    .frame(width: 740, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 0) {
                        RetroWindow(
                            title: "\(ArtScene.of(archetype).rawValue).fig",
                            status: "\(BadgeCatalog.earned(badges).count) badges · \(report.days) days · 1 bit",
                            ink: ink,
                            shadow: accent
                        ) {
                            DitherPlate(
                                scene: ArtScene.of(archetype),
                                params: .of(archetype, badges: badges, report: report),
                                ink: .accent,
                                cell: 4
                            )
                            .frame(height: 238)
                        }
                        .frame(width: 284)
                        .padding(.top, 10)

                        Spacer(minLength: 0)

                        Text("Read locally from my agent logs.\nNothing uploaded.\ngithub.com/\(BuildInfo.repository)")
                            .font(.system(size: 14))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(ink.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 40)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 50)
        }
        .foregroundStyle(ink)
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The app's icon from the bundle. A build run straight from `swift run`
    /// has no bundle, and AppKit would hand back a folder.
    @ViewBuilder private var mark: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
        } else if let icon = NSImage(contentsOfFile: "Assets/icon-square-1024.png") {
            // `swift run` runs from the repository, where the icon's square
            // render sits, so the card still carries the real icon rather
            // than a drawing of it that would drift out of date.
            Image(nsImage: icon)
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent)
                .frame(width: 44, height: 44)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(ink.opacity(0.5))
        }
    }
}

/// A one-bit window from the first Macs: a striped title bar with a close box
/// and the name cut out of the stripes, a hard pixel shadow, and a status line
/// along the bottom. The archetype's plate is the document it has open.
private struct RetroWindow<Content: View>: View {
    let title: String
    let status: String
    let ink: Color
    let shadow: Color
    @ViewBuilder let content: Content

    private let paper = Color(red: 0.06, green: 0.065, blue: 0.09)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { _ in Rectangle().fill(ink.opacity(0.8)).frame(height: 2) }
                }
                .padding(.horizontal, 6)
                HStack {
                    Rectangle()
                        .fill(paper)
                        .frame(width: 18, height: 18)
                        .overlay(Rectangle().strokeBorder(ink, lineWidth: 2))
                        .padding(.horizontal, 6)
                        .background(paper)
                        .padding(.leading, 10)
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .background(paper)
            }
            .frame(height: 30)
            Rectangle().fill(ink).frame(height: 2)
            content
            Rectangle().fill(ink).frame(height: 2)
            HStack {
                Text(status)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
        }
        .background(paper)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: 2))
        .background(Rectangle().fill(shadow.opacity(0.55)).offset(x: 8, y: 8))
    }
}

// ─ Sharing ──────────────────────────────────────────────────────────────────

/// Turning the card into a file, and the file into a post.
@MainActor
enum CardExport {

    static func image(_ card: ShareCardView, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        return renderer.nsImage
    }

    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The card as a file the share menu can hand to Mail, Messages or
    /// AirDrop. Rewritten each time the sheet opens, in Corral's own corner
    /// of the temporary directory.
    static func temporaryFile(_ data: Data) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Corral", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("corral-card.png")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    static func save(_ data: Data, name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

// ─ Sheet ────────────────────────────────────────────────────────────────────

struct ShareSheet: View {
    @EnvironmentObject private var insights: InsightsViewModel
    let done: () -> Void

    @State private var image: NSImage?
    @State private var file: URL?
    @State private var note: String?
    /// The button that just did its job, which says so for a moment.
    @State private var confirmed: Action?
    @State private var clearing: Task<Void, Never>?

    private enum Action { case copy, save, x, linkedIn, readme }

    private let previewWidth: CGFloat = 600

    private var card: ShareCardView? {
        guard let report = insights.report else { return nil }
        return ShareCardView(report: report, archetype: insights.archetype, badges: insights.badges)
    }

    private var postText: String {
        guard let report = insights.report else { return "" }
        return ShareText.post(report: report, archetype: insights.archetype, badges: insights.badges)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Share your card")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }

            if let card {
                card
                    .scaleEffect(previewWidth / ShareCardView.size.width, anchor: .topLeading)
                    .frame(
                        width: previewWidth,
                        height: previewWidth * ShareCardView.size.height / ShareCardView.size.width,
                        alignment: .topLeading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }

            Text("The card shows your archetype, your best badges and the totals on it. "
                + "No project names, no prompts. It goes nowhere until you send it.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { copyImage() } label: { label(.copy, "Copy Image", "doc.on.doc", done: "Copied") }
                Button { savePNG() } label: { label(.save, "Save PNG…", "square.and.arrow.down", done: "Saved") }
                if let file {
                    ShareLink(item: file, subject: Text("How I build with AI agents"), message: Text(postText)) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button { post(.x, to: ShareText.xIntent(postText)) } label: {
                    label(.x, "Post on X", "paperplane", done: "Card copied")
                }
                Button { post(.linkedIn, to: ShareText.linkedInIntent(postText)) } label: {
                    label(.linkedIn, "Post on LinkedIn", "briefcase", done: "Card copied")
                }
                Button { saveReadmeBadge() } label: { label(.readme, "README Badge…", "tag", done: "Badge saved") }
                Spacer()
            }

            // Always laid out, so the sheet does not grow the first time a
            // button reports back; the text changes in place.
            Label(note ?? " ", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(Theme.Severity.active.color)
                .opacity(note == nil ? 0 : 1)
        }
        .padding(20)
        .frame(width: previewWidth + 40)
        .onAppear(perform: render)
        .onDisappear { clearing?.cancel() }
    }

    private func render() {
        guard let card, let image = CardExport.image(card) else { return }
        self.image = image
        if let data = CardExport.png(image) { file = CardExport.temporaryFile(data) }
    }

    /// A button's label that turns into its result for a moment after it is
    /// pressed, where the eye already is. Both versions are always laid out,
    /// so the button keeps the width of the wider one and its neighbours do
    /// not shuffle along when it changes.
    private func label(_ action: Action, _ title: String, _ symbol: String, done: String) -> some View {
        let isDone = confirmed == action
        return ZStack {
            Label(title, systemImage: symbol).opacity(isDone ? 0 : 1)
            Label(done, systemImage: "checkmark").opacity(isDone ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isDone)
    }

    /// Marks the button that acted and says what happened. Pressing again
    /// restarts the moment rather than leaving the old one to run out.
    private func confirm(_ action: Action, _ text: String) {
        note = text
        confirmed = action
        clearing?.cancel()
        clearing = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            confirmed = nil
        }
    }

    private func copyImage() {
        guard let image else { return }
        CardExport.copy(image)
        confirm(.copy, "Card copied. Paste it wherever you like.")
    }

    private func savePNG() {
        guard let image, let data = CardExport.png(image) else { return }
        if let url = CardExport.save(data, name: "corral-card.png", type: .png) {
            confirm(.save, "Saved to \(url.lastPathComponent).")
        }
    }

    /// The intent pages take text and a link but no picture, so the card goes
    /// onto the clipboard first, ready to paste into the post.
    private func post(_ action: Action, to url: URL?) {
        guard let url else { return }
        if let image { CardExport.copy(image) }
        NSWorkspace.shared.open(url)
        confirm(action, "Card copied. Paste it into the post (⌘V) before you send it.")
    }

    private func saveReadmeBadge() {
        let svg = ShareText.readmeBadge(archetype: insights.archetype, earned: insights.earned.count)
        guard let url = CardExport.save(Data(svg.utf8), name: "corral-badge.svg", type: .svg) else { return }
        CardExport.copy(ShareText.readmeMarkdown(archetype: insights.archetype, file: url.lastPathComponent))
        confirm(.readme, "Badge saved. The Markdown to show it is on the clipboard.")
    }
}
