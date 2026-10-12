import Foundation
import Testing
@testable import AgentDropApp

struct MarkdownRendererTests {
    @Test func rendersGitHubFlavoredMarkdown() {
        let html = MarkdownRenderer.body("# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~old~~ https://example.com\n")
        #expect(html.contains("<h1>Plan</h1>"))
        #expect(html.contains("<table>") && html.contains("<td>2</td>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
    }

    @Test func rawHTMLAndScriptLinksNeverReachThePage() {
        let html = MarkdownRenderer.body("<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))\n")
        #expect(!html.contains("<script"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("javascript:"))
    }

    @Test func thePageForbidsScriptsAndFollowsDarkMode() {
        let page = MarkdownRenderer.page("hi")
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("script-src"))
        #expect(page.contains("prefers-color-scheme: dark"))
    }

    @Test func emptyAndNonASCIIInput() {
        #expect(MarkdownRenderer.body("").isEmpty)
        #expect(MarkdownRenderer.body("# Café 🚀").contains("Café 🚀"))
    }
}

struct PreviewKindTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch() }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func classifiesByTypeExtensionAndContent() throws {
        #expect(PreviewKind.of(try write("a.md", Data("# x".utf8))) == .markdown)
        #expect(PreviewKind.of(try write("a.MARKDOWN", Data("# x".utf8))) == .markdown)
        #expect(PreviewKind.of(try write("a.swift", Data("let x = 1".utf8))) == .text)
        #expect(PreviewKind.of(try write("page.html", Data("<script>".utf8))) == .text) // never rendered
        #expect(PreviewKind.of(try write("NOTES", Data("plain words".utf8))) == .text)
        #expect(PreviewKind.of(try write("empty", Data())) == .text)
        #expect(PreviewKind.of(try write("a.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 1]))) == .quickLook)
        #expect(PreviewKind.of(try write("big.md", Data(count: 2_000_001))) == .quickLook)
        #expect(PreviewKind.of(scratch.url) == .folder)
        #expect(PreviewKind.of(scratch.url.appendingPathComponent("nope")) == .unavailable("This file is no longer in the drop folder."))
    }

    @Test func legacyEncodedTextGoesToQuickLookNotGarbledText() throws {
        // "café" in Windows-1252: 0xE9 alone is not UTF-8.
        #expect(PreviewKind.of(try write("README", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))) == .quickLook)
    }

    @Test func aLinkIsNeverFollowed() throws {
        _ = try write("real.md", Data("# x".utf8))
        let link = scratch.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        #expect(PreviewKind.of(link) == .symlink(target: "real.md"))
    }

    @Test func aMultibyteCharacterCutAtTheSniffLimitIsStillText() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: 8191)
        data.append(contentsOf: Array("é".utf8)) // 2 bytes: the second falls past 8192
        #expect(PreviewKind.of(try write("cut", data)) == .text)
    }
}

struct PreviewResourcesTests {
    let scratch: Scratch
    var root: URL { scratch.url.appendingPathComponent("AgentDrop", isDirectory: true) }

    init() throws {
        scratch = try Scratch()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bundle/img"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: root.appendingPathComponent("bundle/img/a b.png"))
        try Data("top".utf8).write(to: root.appendingPathComponent("pic.png"))
        try fm.createDirectory(at: root.appendingPathComponent(".agentdrop"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: root.appendingPathComponent(".agentdrop/index.sqlite"))
        try Data("secret".utf8).write(to: scratch.url.appendingPathComponent("outside.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("bundle/escape.txt").path,
                                  withDestinationPath: "../../outside.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("bundle/linkdir").path, withDestinationPath: "img")
    }

    func resolve(_ relative: String, from document: String) -> URL? {
        let url = URL(string: relative, relativeTo: PreviewResources.baseURL(forDocumentAt: document))!.absoluteURL
        return PreviewResources.file(for: url, root: root)
    }

    @Test func relativeReferencesResolveAgainstTheDocumentsDirectory() {
        #expect(resolve("img/a%20b.png", from: "bundle/README.md")?.path == root.appendingPathComponent("bundle/img/a b.png").path)
        #expect(resolve("pic.png", from: "plan.md")?.path == root.appendingPathComponent("pic.png").path)
        #expect(resolve("../pic.png", from: "bundle/README.md")?.path == root.appendingPathComponent("pic.png").path)
    }

    @Test func nothingOutsideTheFolderNoDotEntriesNoLinks() {
        #expect(resolve("../../outside.txt", from: "bundle/README.md") == nil) // clamped to root/outside.txt: absent
        #expect(resolve("%2E%2E/outside.txt", from: "plan.md") == nil)
        #expect(resolve(".agentdrop/index.sqlite", from: "plan.md") == nil)
        #expect(resolve("escape.txt", from: "bundle/README.md") == nil)
        #expect(resolve("linkdir/a%20b.png", from: "bundle/README.md") == nil)
        #expect(resolve("img", from: "bundle/README.md") == nil) // a directory is not a file
        #expect(PreviewResources.file(for: URL(string: "file:///etc/hosts")!, root: root) == nil)
    }

    @Test func baseURLEncodesAwkwardNames() {
        let base = PreviewResources.baseURL(forDocumentAt: "my bundle #1/docs/README.md")
        #expect(base.absoluteString == "agentdrop-preview://root/my%20bundle%20%231/docs/")
        #expect(PreviewResources.baseURL(forDocumentAt: "plan.md").absoluteString == "agentdrop-preview://root/")
    }
}

struct FolderTreeTests {
    @Test func buildsANestedTreeAndHidesDotEntries() throws {
        let scratch = try Scratch()
        let fm = FileManager.default
        let folder = scratch.url.appendingPathComponent("bundle")
        try fm.createDirectory(at: folder.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
        try Data("# R".utf8).write(to: folder.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("docs/deep/x.txt"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("config").path,
                                  withDestinationPath: "../shared/config.json")

        let nodes = try FolderTree.load(folder)
        #expect(nodes.map(\.name) == ["README.md", "config", "docs"])
        #expect(nodes[1].type == "symlink" && nodes[1].target == "../shared/config.json" && nodes[1].children == nil)
        #expect(nodes[2].children?.first?.children?.first?.path == "docs/deep/x.txt")
        #expect(FolderTree.defaultDocument(nodes)?.path == "README.md")
    }

    @Test func defaultDocumentFallsBackToTheFirstMarkdownFile() {
        func file(_ name: String) -> FileNode { FileNode(path: name, name: name, type: "file", size: 1, target: nil, children: nil) }
        #expect(FolderTree.defaultDocument([file("b.md"), file("a.md"), file("c.txt")])?.name == "a.md")
        #expect(FolderTree.defaultDocument([file("readme.md"), file("a.md")])?.name == "readme.md")
        #expect(FolderTree.defaultDocument([file("c.txt")]) == nil)
    }
}

struct CodeLocatorTests {
    @Test func searchesPathThenCommonInstallLocations() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CodeLocator.find(path: "/a:/b", home: home) { $0 == "/b/code" }?.path == "/b/code")
        #expect(CodeLocator.find(path: "/usr/bin:/bin", home: home) { $0 == "/opt/homebrew/bin/code" }?.path
                == "/opt/homebrew/bin/code")
        let bundled = "/Users/someone/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        #expect(CodeLocator.find(path: nil, home: home) { $0 == bundled }?.path == bundled)
        #expect(CodeLocator.find(path: "/usr/bin", home: home) { _ in false } == nil)
    }
}

struct LinkPolicyTests {
    @Test func linksOpenInTheBrowserFilesAreRevealedAnchorsScroll() throws {
        let scratch = try Scratch()
        try Data("x".utf8).write(to: scratch.url.appendingPathComponent("other.md"))
        let base = PreviewResources.baseURL(forDocumentAt: "plan.md")
        func action(_ href: String) -> LinkAction {
            LinkPolicy.action(for: URL(string: href, relativeTo: base)!.absoluteURL, documentBase: base, root: scratch.url)
        }
        #expect(action("https://example.com/a") == .openInBrowser(URL(string: "https://example.com/a")!))
        #expect(action("mailto:me@example.com") == .openInBrowser(URL(string: "mailto:me@example.com")!))
        #expect(action("#usage") == .scrollInPage)
        #expect(action("other.md") == .revealInFinder(scratch.url.appendingPathComponent("other.md")))
        #expect(action("missing.md") == .ignore)
        #expect(action("file:///etc/hosts") == .ignore)
        #expect(action("javascript:alert(1)") == .ignore)
    }
}
