import Foundation

/// Default titles (spec §3 data model `title`).
enum TitleExtractor {
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
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return nil
    }
}
