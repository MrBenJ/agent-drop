import AgentDropApp
import AgentDropCore
import AppKit
import SwiftUI

/// Spec §6 detail column: metadata header, action buttons, then the preview.
struct DetailView: View {
    let library: LibraryModel

    var body: some View {
        if let store = library.store, let drop = library.selectedDrop {
            DropDetailView(library: library, drop: drop, folder: store.folder)
                .id(store.folder.path + "/" + drop.id)
        } else if let store = library.store, let entry = library.selectedEntry {
            EntryDetailView(library: library, entry: entry, folder: store.folder)
                .id(store.folder.path + "/" + entry.name)
        } else {
            ContentUnavailableView("Select a drop", systemImage: "tray")
        }
    }
}

struct DropDetailView: View {
    let library: LibraryModel
    let drop: Drop
    let folder: URL
    @State private var editing = false
    @State private var finishing = false
    @State private var confirmingRemove = false

    private var url: URL { folder.appendingPathComponent(drop.filename, isDirectory: drop.isFolder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(drop.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let status = drop.status { StatusPill(status: status) }
                    Spacer()
                }
                if drop.missing {
                    Label("The file is no longer in the drop folder.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let description = drop.description {
                    Text(description).textSelection(.enabled)
                }
                MetadataGrid(drop: drop)
                actions
            }
            .padding(16)
            Divider()
            if drop.missing {
                ContentUnavailableView("Missing", systemImage: "questionmark.folder",
                                       description: Text("“\(drop.filename)” was moved, renamed or deleted."))
            } else if drop.isFolder {
                FolderPreview(root: folder, folderName: drop.filename, revision: library.revision)
            } else {
                FilePreview(root: folder, relativePath: drop.filename, revision: library.revision)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $editing) { EditMetadataSheet(library: library, drop: drop) }
        .sheet(isPresented: $finishing) { DoneSheet(library: library, drop: drop) }
        .confirmationDialog("Remove the record for “\(drop.title)”?", isPresented: $confirmingRemove) {
            Button("Remove Record", role: .destructive) { Task { await library.removeRecord(drop.id) } }
        } message: {
            Text("Only Agent Drop's record is removed. The file is already gone from the drop folder.")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            OpenInCodeButton(url: url, library: library).disabled(drop.missing)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(drop.missing)
            Menu("Copy") {
                Button("Copy Path") { Pasteboard.copy(url.path) }
                Button("Copy `\(DropFormatting.copyCommand(drop))`") { Pasteboard.copy(DropFormatting.copyCommand(drop)) }
            }
            .fixedSize()
            if drop.status == .claimed {
                Button("Release") { Task { await library.release(drop.id) } }
            }
            if drop.status == .open || drop.status == .claimed {
                Button("Mark Done…") { finishing = true }
            }
            if drop.status == .done {
                Button("Reopen") { Task { await library.reopen(drop.id) } }
            }
            Spacer()
            Menu {
                Button("Edit Metadata…") { editing = true }
                Button(drop.archived ? "Unarchive" : "Archive") {
                    Task { await library.setArchived(drop.id, !drop.archived) }
                }
                if drop.missing {
                    Divider()
                    Button("Remove Record…", role: .destructive) { confirmingRemove = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }
}

struct MetadataGrid: View {
    let drop: Drop

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Project", drop.project)
            row("Tags", drop.tags.isEmpty ? nil : drop.tags.joined(separator: ", "))
            row("From", drop.from)
            row("Claimed by", drop.claimedBy)
            row("Note", drop.statusNote)
            row("File", drop.filename + (drop.isFolder ? "/" : ""))
            row("Created", drop.createdAt.formatted(date: .abbreviated, time: .shortened))
            row("Updated", drop.updatedAt.formatted(date: .abbreviated, time: .shortened))
            row("Read", drop.readAt?.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.callout)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct EntryDetailView: View {
    let library: LibraryModel
    let entry: UnregisteredEntry
    let folder: URL
    @State private var registering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("Unregistered: this \(entry.isFolder ? "folder" : "file") is in the drop folder but has no record. Register it here, or have an agent run `drop add \(entry.name)` from the drop folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Register…") { registering = true }.buttonStyle(.borderedProminent)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(entry.name)])
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
            Divider()
            if entry.isFolder {
                FolderPreview(root: folder, folderName: entry.name, revision: library.revision)
            } else {
                FilePreview(root: folder, relativePath: entry.name, revision: library.revision)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $registering) { RegisterSheet(library: library, entry: entry) }
    }
}

struct OpenInCodeButton: View {
    let url: URL
    let library: LibraryModel
    @State private var code = CodeLocator.find()

    var body: some View {
        Button("Open in VS Code") {
            guard let code else { return }
            do {
                try CodeLocator.open(url, with: code)
            } catch {
                library.alert = "Couldn't start VS Code: \(error.localizedDescription)"
            }
        }
        .disabled(code == nil)
        .help(code == nil
              ? "VS Code's `code` command wasn't found. In VS Code, run “Shell Command: Install 'code' command in PATH”."
              : "Open in VS Code")
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
