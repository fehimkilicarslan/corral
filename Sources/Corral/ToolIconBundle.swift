import Foundation

/// Where a process's app bundle is, worked out from its path alone. Kept
/// apart from the icon lookup, which needs AppKit, because `ToolCatalog`
/// uses it and has to build on Linux too.
enum ToolIcon {

    /// The bundle a path executes from, if any.
    ///
    /// Takes the *first* `.app/` in the path rather than the last: an Electron
    /// helper lives at `Cursor.app/Contents/Frameworks/Cursor Helper.app/…`,
    /// and the product is the outer bundle, not the helper's own.
    static func bundlePath(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}
