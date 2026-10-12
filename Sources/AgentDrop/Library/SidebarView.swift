import AgentDropApp
import SwiftUI

/// Spec §6 sidebar: fixed views, then Projects, Tags and From as filter lists (trees when
/// values contain `/`).
struct SidebarView: View {
    @Bindable var library: LibraryModel

    private var selection: Binding<SidebarItem?> {
        Binding(get: { library.sidebar }, set: { library.sidebar = $0 ?? .allDrops })
    }

    var body: some View {
        List(selection: selection) {
            Label("All Drops", systemImage: "tray.full").tag(SidebarItem.allDrops)
            Label("Inbox", systemImage: "tray.and.arrow.down").badge(library.inboxCount).tag(SidebarItem.inbox)
            Label("Handoffs", systemImage: "arrow.left.arrow.right").tag(SidebarItem.handoffs)
            Label("Unregistered", systemImage: "questionmark.folder").badge(library.unregisteredCount)
                .tag(SidebarItem.unregistered)
            Label("Archived", systemImage: "archivebox").tag(SidebarItem.archived)

            if !library.projectTree.isEmpty {
                Section("Projects") {
                    OutlineGroup(library.projectTree, children: \.children) { node in
                        IdentityRow(node: node, systemImage: "folder").tag(SidebarItem.project(node.path))
                    }
                }
            }
            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(SidebarItem.tag(tag))
                    }
                }
            }
            if !library.fromTree.isEmpty {
                Section("From") {
                    OutlineGroup(library.fromTree, children: \.children) { node in
                        IdentityRow(node: node, systemImage: "person").tag(SidebarItem.from(node.path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct IdentityRow: View {
    let node: IdentityNode
    let systemImage: String

    var body: some View {
        Label(node.name.isEmpty ? "(empty)" : node.name, systemImage: systemImage)
            .badge(node.count)
            .help(node.path)
    }
}
