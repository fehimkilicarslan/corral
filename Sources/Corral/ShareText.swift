import Foundation

/// What goes with the card: the words for a post, and a README badge.
enum ShareText {

    static func post(report: InsightReport, archetype: Archetype, badges: [Badge]) -> String {
        let top = BadgeCatalog.earned(badges).prefix(3)
        var lines = ["My last \(report.days) days building with AI agents: \(archetype.title)."]
        if !top.isEmpty {
            lines.append(top.map { "\($0.tier.medal) \($0.title)" }.joined(separator: "  "))
        }
        var totals = [
            "\(Int(report.activeHours.rounded()).formatted()) active hours", "\(report.sessions.formatted()) sessions",
        ]
        if report.gitAvailable { totals.append("\(report.assistedCommits.formatted()) commits") }
        lines.append(totals.joined(separator: " · "))
        lines.append("Measured locally by Corral, nothing uploaded: \(BuildInfo.repositoryURL.absoluteString)")
        return lines.joined(separator: "\n")
    }

    static func xIntent(_ text: String) -> URL? {
        var components = URLComponents(string: "https://x.com/intent/tweet")
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        return components?.url
    }

    static func linkedInIntent(_ text: String) -> URL? {
        var components = URLComponents(string: "https://www.linkedin.com/feed/")
        components?.queryItems = [
            URLQueryItem(name: "shareActive", value: "true"),
            URLQueryItem(name: "text", value: text),
        ]
        return components?.url
    }

    /// A flat, shields-style badge for a README: "corral | The Conductor · 9
    /// badges". Self-contained SVG, so it can be committed next to the README
    /// and needs no server to draw it.
    static func readmeBadge(archetype: Archetype, earned: Int) -> String {
        let left = "corral"
        let right = "\(archetype.title) · \(earned) badge\(earned == 1 ? "" : "s")"
        // Verdana 11 averages a little under 7 px a character; shields pads 10
        // either side of the text.
        let leftWidth = Int((Double(left.count) * 6.8).rounded()) + 20
        let rightWidth = Int((Double(right.count) * 6.8).rounded()) + 20
        let width = leftWidth + rightWidth
        let label = escape("\(left): \(right)")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="20" role="img" aria-label="\(label)">
          <title>\(label)</title>
          <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
          <clipPath id="r"><rect width="\(width)" height="20" rx="3" fill="#fff"/></clipPath>
          <g clip-path="url(#r)">
            <rect width="\(leftWidth)" height="20" fill="#555"/>
            <rect x="\(leftWidth)" width="\(rightWidth)" height="20" fill="#d97857"/>
            <rect width="\(width)" height="20" fill="url(#s)"/>
          </g>
          <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
            <text x="\(leftWidth / 2)" y="14">\(escape(left))</text>
            <text x="\(leftWidth + rightWidth / 2)" y="14">\(escape(right))</text>
          </g>
        </svg>
        """
    }

    static func readmeMarkdown(archetype: Archetype, file: String) -> String {
        "[![Corral: \(archetype.title)](\(file))](\(BuildInfo.repositoryURL.absoluteString))"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
