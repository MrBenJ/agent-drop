import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 menu bar extra: icon with the unread count.
struct MenuBarLabel: View {
    let library: LibraryModel

    var body: some View {
        let count = library.unreadCount
        Image(systemName: count > 0 ? "tray.full" : "tray")
        if count > 0 { Text("\(count)") }
    }
}

/// The dropdown: the 10 most recent drops, the Inbox, then Open / Settings / Quit.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let status = model.menuStatus {
            Button(status) { model.showWindow() }
            Divider()
        }
        if model.phase == .running {
            Section("Recent") {
                if model.library.recentDrops.isEmpty {
                    Text("No drops yet")
                }
                ForEach(model.library.recentDrops, id: \.id) { drop in
                    Button(DropFormatting.menuLine(drop)) { Task { await model.open(dropID: drop.id) } }
                }
            }
            Section("Inbox") {
                if model.library.inboxDrops.isEmpty {
                    Text("No open handoffs")
                }
                ForEach(model.library.inboxDrops, id: \.id) { drop in
                    Button(DropFormatting.menuLine(drop)) { Task { await model.open(dropID: drop.id) } }
                }
            }
            Divider()
        }
        Button("Open Agent Drop") { model.showWindow() }
            .keyboardShortcut("o")
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Agent Drop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
