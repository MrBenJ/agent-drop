import Foundation

/// Default titles (spec §3 data model `title`).
enum TitleExtractor {
    /// How much of a file is scanned for a heading; anything later is ignored.
    static let maxScanBytes = 64 * 1024
    /// Longest title returned from a heading, in characters.
    static let maxTitleLength = 200

    static func title(for url: URL, isFolder: Bool) -> String? {
        if isFolder {
            let fm = FileManager.default
            let readme = url.appendingPathComponent("README.md")
            if fm.fileExists(atPath: readme.path) { return firstHeading(in: readme) }
            let markdown = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }
                .sorted()
            return markdown.first.flatMap { firstHeading(in: url.appendingPathComponent($0)) }
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return nil }
        return firstHeading(in: url)
    }

    static func fallback(filename: String, isFolder: Bool) -> String {
        guard !isFolder else { return filename }
        let base = (filename as NSString).deletingPathExtension
        return base.isEmpty ? filename : base
    }

    private static func firstHeading(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScanBytes), !data.isEmpty else { return nil }
        // Lossy decoding tolerates a multi-byte sequence cut at the prefix boundary.
        let text = String(decoding: data, as: UTF8.self)
        var found: String?
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { return }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty {
                found = String(heading.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
                stop = true
            }
        }
        return found
    }
}
