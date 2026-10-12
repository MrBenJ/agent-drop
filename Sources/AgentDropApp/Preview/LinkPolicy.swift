import Foundation

/// What clicking a link in the rendered view does (spec §6: links open in the default
/// browser). A link to a file in the drop folder reveals it in Finder rather than
/// opening it: opening could run a script or app an agent left there.
public enum LinkAction: Equatable, Sendable {
    /// A `#fragment` in the same document: scroll there.
    case scrollInPage
    case openInBrowser(URL)
    case revealInFinder(URL)
    case ignore
}

public enum LinkPolicy {
    public static func action(for url: URL, documentBase: URL, root: URL) -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .openInBrowser(url)
        case PreviewResources.scheme:
            if url.fragment != nil, sameDocument(url, documentBase) { return .scrollInPage }
            return PreviewResources.file(for: url, root: root).map(LinkAction.revealInFinder) ?? .ignore
        default:
            return .ignore
        }
    }

    /// Fragment links resolve against the base URL (the document's directory).
    private static func sameDocument(_ url: URL, _ base: URL) -> Bool {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url?.absoluteString == base.absoluteString
    }
}
