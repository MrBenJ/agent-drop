import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 list column: title, project, from, tags, relative time, unread dot, status pill.
struct DropListView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        content
            .searchable(text: $library.search, placement: .toolbar, prompt: "Title, description, filename")
            .navigationTitle(title)
    }

    @ViewBuilder private var content: some View {
        switch library.sidebar {
        case .unregistered:
            List(selection: $library.selection) {
                ForEach(library.visibleEntries) { entry in
                    EntryRow(entry: entry).tag(LibraryModel.Selection.entry(entry.name))
                }
            }
            .overlay { if library.visibleEntries.isEmpty { empty("Nothing unregistered", "Every file in the drop folder has a record.") } }
        case .handoffs:
            List(selection: $library.selection) {
                ForEach(library.handoffGroups) { group in
                    Section(DropFormatting.statusLabel(group.status)) {
                        ForEach(group.drops, id: \.id) { drop in
                            DropRow(drop: drop).tag(LibraryModel.Selection.drop(drop.id))
                        }
                    }
                }
            }
            .overlay { if library.handoffGroups.isEmpty { empty("No handoffs", "Agents create them with drop add --handoff.") } }
        default:
            List(selection: $library.selection) {
                ForEach(library.visibleDrops, id: \.id) { drop in
                    DropRow(drop: drop).tag(LibraryModel.Selection.drop(drop.id))
                }
            }
            .overlay { if library.visibleDrops.isEmpty { empty("No drops", "Nothing here yet.") } }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(detail))
    }

    private var title: String {
        switch library.sidebar {
        case .allDrops: "All Drops"
        case .inbox: "Inbox"
        case .handoffs: "Handoffs"
        case .unregistered: "Unregistered"
        case .archived: "Archived"
        case .project(let path), .from(let path): path
        case .tag(let tag): "#\(tag)"
        }
    }
}

struct DropRow: View {
    let drop: Drop

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(drop.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(drop.title).fontWeight(drop.isUnread ? .semibold : .regular).lineLimit(1)
                    Spacer()
                    if let status = drop.status { StatusPill(status: status) }
                }
                Text([drop.project, drop.from].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    if !drop.tags.isEmpty {
                        Text(drop.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(DropFormatting.relativeTime(drop.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .opacity(drop.missing ? 0.5 : 1)
        .help(drop.missing ? "The file is no longer in the drop folder." : drop.filename)
    }
}

struct EntryRow: View {
    let entry: UnregisteredEntry

    var body: some View {
        Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
    }
}

struct StatusPill: View {
    let status: HandoffStatus

    var body: some View {
        Text(DropFormatting.statusLabel(status))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .open: .blue
        case .claimed: .orange
        case .done: .green
        }
    }
}
