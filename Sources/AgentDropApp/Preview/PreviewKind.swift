import Foundation

/// A classification remembered with the path it was made for. A view that re-classifies
/// asynchronously must not render a newly selected file with the previous file's kind:
/// that would read a huge file inline, or follow a link (spec §3).
public struct ClassifiedPreview: Equatable, Sendable {
    public var path: String
    public var kind: PreviewKind

    public init(path: String, kind: PreviewKind) {
        self.path = path
        self.kind = kind
    }

    public func kind(for path: String) -> PreviewKind? {
        path == self.path ? kind : nil
    }
}

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
        // Legacy-encoded text (e.g. a Windows-1252 CSV) would show as U+FFFD garbage:
        // Quick Look detects encodings, so it gets those whatever their extension.
        guard looksLikeText(url) else { return .quickLook }
        return markdownExtensions.contains(url.pathExtension.lowercased()) ? .markdown : .text
    }

    /// No NUL bytes and valid UTF-8 in the first 8 KB (allowing a character cut off at the end).
    static func looksLikeText(_ url: URL) -> Bool {
        let limit = 8192
        guard let data = NoFollowFile.read(url.lastPathComponent, under: url.deletingLastPathComponent(),
                                           maxBytes: limit) else { return false }
        guard !data.isEmpty else { return true }
        guard !data.contains(0) else { return false }
        let maxCut = data.count == limit ? 3 : 0
        return (0...maxCut).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }
}
