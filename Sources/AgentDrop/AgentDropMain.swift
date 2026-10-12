import AgentDropApp
import SwiftUI

@main
struct AgentDropMain: App {
    var body: some Scene {
        MenuBarExtra("Agent Drop", systemImage: "tray.and.arrow.down") {
            Button("Quit Agent Drop") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
