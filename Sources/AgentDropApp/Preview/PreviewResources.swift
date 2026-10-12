import Foundation

/// The rendered view's private URL scheme. A Markdown page is loaded with a base URL in
/// this scheme, so relative links and images resolve against the rendered file's own
/// directory (spec §6), and every request is answered from the drop folder only:
/// nothing above it, no dot-entries (`.agentdrop/`), and never through a symlink (§3).
public enum PreviewResources {
    public static let scheme = "agentdrop-preview"
    private static let host = "root"

    /// The base URL for a document at `relativePath` (relative to the drop folder).
    public static func baseURL(forDocumentAt relativePath: String) -> URL {
        let directories = relativePath.split(separator: "/").dropLast()
        let encoded = directories.map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }
        return URL(string: "\(scheme)://\(host)/" + encoded.map { $0 + "/" }.joined())!
    }

    /// The regular file a preview URL names inside `root`, or nil.
    public static func file(for url: URL, root: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.hasPrefix(".") }) else { return nil }
        var current = root
        for (index, component) in components.enumerated() {
            current = current.appendingPathComponent(component)
            let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType
            let isLast = index == components.count - 1
            guard type == (isLast ? .typeRegular : .typeDirectory) else { return nil }
        }
        return current
    }
}
