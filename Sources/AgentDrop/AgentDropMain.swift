import AgentDropApp
import SwiftUI

@main
struct AgentDropMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Spec §6: the menu bar extra is always present while the app runs. The main
        // window is an AppKit window the delegate opens on demand, so `--windowless`
        // launches show no window at all.
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            MenuBarLabel(library: delegate.model.library)
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
