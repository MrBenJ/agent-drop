import AgentDropApp
import AppKit
import SwiftUI

/// What the main window shows for each phase of the app (spec §2, §3, §7).
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                SetupView(model: model)
            case .confirmFolder:
                ConfirmFolderView(model: model)
            case .running:
                LibraryView(model: model)
            case .storeError(let message):
                StoreErrorView(model: model, message: message)
            case .configUnreadable(let message):
                ContentUnavailableView {
                    Label("Agent Drop can't read its settings", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(message)\nFix or remove the file; Agent Drop picks it up as soon as it changes.")
                        .textSelection(.enabled)
                } actions: {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.configStore.configFile])
                    }
                    Button("Try Again") { Task { await model.configDidChange() } }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .alert("Agent Drop", isPresented: alertShown) {
            Button("OK") { model.library.alert = nil }
        } message: {
            Text(model.library.alert ?? "")
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.library.alert != nil }, set: { if !$0 { model.library.alert = nil } })
    }
}

/// First-run setup (spec §2, §6): the folder, any macOS prompt explained before it
/// appears, and the launch-at-login question with Yes pre-selected.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var finishing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Agent Drop").font(.largeTitle.weight(.semibold))
            Text("Agents drop files here with context: what each file is, why it exists, which project it's from, and whether a handoff has been picked up.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Drop folder") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.folder.path).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Change…") { pickFolder() }
                    }
                    if model.folderIsProtected {
                        ProtectedFolderNote()
                    }
                }
                .padding(6)
            }

            GroupBox("Start Agent Drop at login?") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Start Agent Drop at login?", selection: $model.launchAtLogin) {
                        Text("Yes").tag(true)
                        Text("No").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("Agents and apps that watch for changes need it running. You can change this in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if let error = model.folderError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(finishing ? "Setting up…" : "Finish Setup") {
                    finishing = true
                    Task {
                        await model.completeSetup()
                        finishing = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(finishing)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFolder() {
        guard let url = FolderPicker.choose(startingAt: model.folder) else { return }
        Task { await model.chooseFolder(url) }
    }
}

/// Spec §3 protected-folder confirmation, after the folder was changed outside the app.
struct ConfirmFolderView: View {
    @Bindable var model: AppModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Drop folder changed").font(.largeTitle.weight(.semibold))
            Text("The drop folder was changed outside Agent Drop to:")
            Text(model.folder.path).font(.body.monospaced()).textSelection(.enabled)
            ProtectedFolderNote()
            Text("Until you confirm, Agent Drop leaves this folder alone: its local server and change tracking are off, and `drop watch` can't connect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.folderError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose Another Folder…") {
                    if let url = FolderPicker.choose(startingAt: model.folder) {
                        Task { await model.chooseFolder(url) }
                    }
                }
                Spacer()
                Button("Use This Folder") {
                    confirming = true
                    Task {
                        await model.confirmFolder()
                        confirming = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirming)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Explains the macOS prompt before it appears (spec §2).
struct ProtectedFolderNote: View {
    var body: some View {
        Label {
            Text("This folder is in a location macOS protects (Desktop, Documents, Downloads, iCloud Drive, or a removable or network drive). When you continue, macOS asks whether Agent Drop may access it. Agent Drop needs that to list and show your drops; it reads and writes only inside this folder.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
    }
}

/// Spec §7: the store can't be opened. Never deleted or repaired automatically.
struct StoreErrorView: View {
    let model: AppModel
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Agent Drop can't open its store", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("Reveal in Finder") {
                let store = model.folder.appendingPathComponent(".agentdrop", isDirectory: true)
                let target = FileManager.default.fileExists(atPath: store.path) ? store : model.folder
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            Button("Try Again") { Task { await model.retryStore() } }
        }
    }
}

enum FolderPicker {
    @MainActor static func choose(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = folder.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
