import Foundation

extension CLI {

    /// Runs the terminal mode the arguments ask for, if any, and says whether
    /// one ran. Kept out of Main.swift, whose app half needs SwiftUI, so that
    /// the terminal modes build on Linux too.
    static func handle(_ args: [String]) -> Bool {
        // First, and with no side effects: Claude Code runs this on every
        // status update, so it has to start and finish without touching the
        // process table or drawing anything.
        if args.contains("--statusline") {
            StatusLine.run(tool: StatusLine.tool(from: args))
            return true
        }
        if args.contains("--version") {
            print("Corral \(BuildInfo.display)")
            return true
        }
        if args.contains("--bench") {
            CLI.bench()
            return true
        }
        if args.contains("--disk") {
            CLI.disk()
            return true
        }
        if args.contains("--insights") {
            var days = 30
            if let i = args.firstIndex(of: "--days"), args.count > i + 1, let n = Int(args[i + 1]) {
                days = max(1, min(n, 90))
            }
            CLI.insights(days: days, json: args.contains("--json"))
            return true
        }
        if args.contains("--list") {
            var filter: String?
            if let i = args.firstIndex(of: "--search"), args.count > i + 1 {
                filter = args[i + 1]
            }
            CLI.list(json: args.contains("--json"), search: filter)
            return true
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Corral \(BuildInfo.display) — see what your AI coding agents are doing

              Corral               open the window
              Corral --list        print running agents
              Corral --list --search <text>
                                   only agents matching a project, tool or pid
              Corral --disk        print what the tools have left on disk
              Corral --insights [--days N] [--json]
                                   habits and badges from your agent sessions
              Corral --list --json machine-readable output
              Corral --version     print version
              Corral --statusline <claude|cursor>
                                   status line for that agent; see the menu
            """)
            return true
        }
        return false
    }
}
