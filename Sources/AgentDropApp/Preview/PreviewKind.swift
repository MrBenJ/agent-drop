import Foundation

/// Which preview a file gets (spec §6 Rendering).
public enum PreviewKind: Equatable, Sendable {
    case markdown
    /// Plain text and code: a monospace text view.
    case text
    /// Images, PDFs and everything else: Quick Look.
    case quickLook
    case folder
    /// Links are listed with their target text and never followed (spec §3).
    case symlink(target: String?)
    case unavailable(String)

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    /// Shown as text even if the first bytes look odd. HTML is text here: never rendered.
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "csv", "tsv", "xml", "html",
        "htm", "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m",
        "mm", "cpp", "hpp", "sh", "zsh", "bash", "fish", "sql", "diff", "patch", "env", "gitignore",
    ]
    /// Larger files go to Quick Look instead of being loaded into a view.
    static let maxInlineBytes: Int64 = 2_000_000

    public static func of(_ url: URL) -> PreviewKind {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { // does not follow links
            return .unavailable("This file is no longer in the drop folder.")
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            return .folder
        case .typeSymbolicLink?:
            return .symlink(target: try? fm.destinationOfSymbolicLink(atPath: url.path))
        case .typeRegular?:
            break
        default:
            return .unavailable("Agent Drop doesn't preview this kind of item.")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxInlineBytes else { return .quickLook }
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if textExtensions.contains(ext) { return .text }
        return looksLikeText(url) ? .text : .quickLook
    }

    /// No NUL bytes and valid UTF-8 in the first 8 KB (allowing a character cut off at the end).
    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let limit = 8192
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return true }
        guard !data.contains(0) else { return false }
        let maxCut = data.count == limit ? 3 : 0
        return (0...maxCut).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }
}
