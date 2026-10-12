import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Spec §6 Rendering: GFM via swift-cmark → HTML. Raw HTML in the Markdown is never
/// passed through (cmark's safe mode replaces it with a comment and blanks
/// `javascript:` links), and the page's Content-Security-Policy allows no scripts, so
/// nothing in a drop can run code even before the web view's own JavaScript switch.
public enum MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tasklist", "tagfilter"]

    /// The HTML fragment for `markdown`.
    public static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.utf8CString.withUnsafeBufferPointer { buffer in
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1) // without the NUL
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            return ""
        }
        defer { free(html) }
        return String(cString: html)
    }

    /// A complete page: the fragment, the bundled stylesheet (light and dark), and a
    /// policy that only allows images from the drop folder, `data:` and `https:`.
    public static func page(_ markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(PreviewResources.scheme): data: https:; media-src \(PreviewResources.scheme):; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <style>\(MarkdownStyle.css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body(markdown))
        </article>
        </body>
        </html>
        """
    }
}

enum MarkdownStyle {
    static let css = """
        :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --link: #0969da; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --code-bg: #151b23; --link: #4493f8; }
        }
        html { background: transparent; }
        body { margin: 0; padding: 24px 32px; color: var(--fg); font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; }
        .markdown-body { max-width: 860px; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
        h1, h2, h3, h4 { margin: 1.4em 0 .6em; line-height: 1.25; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre { font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code-bg); border-radius: 6px; }
        code { padding: .2em .4em; }
        pre { padding: 12px 16px; overflow: auto; }
        pre code { padding: 0; background: none; }
        blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { border: 1px solid var(--border); padding: 6px 13px; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid var(--border); }
        li > input[type=checkbox] { margin-right: .4em; }
        """
}
