import AgentDropApp
import AppKit
import Quartz
import SwiftUI

/// Spec §6 Rendering for one file, `relativePath` inside the drop folder `root`.
struct FilePreview: View {
    let root: URL
    let relativePath: String
    /// The library's revision: a change re-reads the file (content events).
    let revision: Int
    /// Kept with the path it was made for: `body` runs with a new path before the task
    /// re-classifies, and must never read that file with the old kind.
    @State private var classified: ClassifiedPreview?

    private var url: URL { root.appendingPathComponent(relativePath) }

    var body: some View {
        Group {
            switch classified?.kind(for: relativePath) {
            case nil:
                Color.clear
            case .markdown?:
                MarkdownView(root: root, relativePath: relativePath, revision: revision)
            case .text?:
                TextFileView(url: url, revision: revision)
            case .quickLook?:
                QuickLookView(url: url, revision: revision)
            case .folder?:
                ContentUnavailableView("Folder", systemImage: "folder",
                                       description: Text("Select a file inside it to preview it."))
            case .symlink(let target)?:
                ContentUnavailableView("Link", systemImage: "link",
                                       description: Text("Points to \(target ?? "an unknown target"). Agent Drop never follows links."))
            case .unavailable(let message)?:
                ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(relativePath)#\(revision)") {
            classified = ClassifiedPreview(path: relativePath, kind: PreviewKind.of(url))
        }
    }
}

/// Plain text and code: a read-only monospace text view (fast for large files).
struct TextFileView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text { textView.string = text }
    }
}

/// Images, PDFs and everything else (spec §6). Only ever given regular files.
struct QuickLookView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        } else {
            view.refreshPreviewItem()
        }
    }
}

/// Spec §6: a folder drop shows its file tree above the rendered README (or first `.md`).
/// Selecting a file in the tree previews it with the rules above.
struct FolderPreview: View {
    let root: URL
    let folderName: String
    let revision: Int
    @State private var nodes: [FileNode] = []
    @State private var selected: String?

    var body: some View {
        VSplitView {
            List(selection: $selected) {
                OutlineGroup(nodes, children: \.children) { node in
                    Label(node.type == "symlink" ? "\(node.name) → \(node.target ?? "?")" : node.name,
                          systemImage: icon(node))
                        .tag(node.path)
                }
            }
            .frame(minHeight: 100, idealHeight: 160)
            Group {
                if let selected {
                    FilePreview(root: root, relativePath: folderName + "/" + selected, revision: revision)
                } else {
                    ContentUnavailableView("No README", systemImage: "doc.text",
                                           description: Text("Select a file to preview it."))
                }
            }
            .frame(minHeight: 200)
        }
        .task(id: revision) {
            nodes = await FolderTree.loadOffMain(root.appendingPathComponent(folderName, isDirectory: true))
            if selected == nil { selected = FolderTree.defaultDocument(nodes)?.path }
        }
    }

    private func icon(_ node: FileNode) -> String {
        switch node.type {
        case "directory": "folder"
        case "symlink": "link"
        case "file": "doc"
        default: "questionmark.square"
        }
    }
}
