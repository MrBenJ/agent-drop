import AgentDropApp
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Markdown rendered by `MarkdownRenderer` in a web view with JavaScript off. Pages load
/// with a base URL in the preview scheme; `PreviewSchemeHandler` answers from the drop
/// folder only.
struct MarkdownView: NSViewRepresentable {
    let root: URL
    let relativePath: String
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PreviewSchemeHandler(root: root), forURLScheme: PreviewResources.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let markdown = (try? Data(contentsOf: root.appendingPathComponent(relativePath)))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let base = PreviewResources.baseURL(forDocumentAt: relativePath)
        // Reload only when the text changed, so a refresh doesn't lose the scroll position.
        let page = Coordinator.Loaded(base: base, markdown: markdown)
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        webView.loadHTMLString(MarkdownRenderer.page(markdown), baseURL: base)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Loaded: Equatable {
            var base: URL
            var markdown: String
        }

        let root: URL
        var loaded: Loaded?

        init(root: URL) { self.root = root }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url, let base = loaded?.base else {
                decisionHandler(.allow) // the page itself
                return
            }
            switch LinkPolicy.action(for: url, documentBase: base, root: root) {
            case .scrollInPage:
                decisionHandler(.allow)
            case .openInBrowser(let url):
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            case .revealInFinder(let file):
                decisionHandler(.cancel)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            case .ignore:
                decisionHandler(.cancel)
            }
        }
    }
}

/// Serves `agentdrop-preview:` requests (images, linked files) from the drop folder.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = PreviewResources.file(for: url, root: root),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
