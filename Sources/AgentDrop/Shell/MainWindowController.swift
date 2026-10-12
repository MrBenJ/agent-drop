import AgentDropApp
import AppKit
import SwiftUI

/// The main window, created once and reused: closing it only hides it (spec §6).
@MainActor
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Agent Drop"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: RootView(model: model))
        // The list's search field and the window title come from SwiftUI's toolbar and
        // navigationTitle; say explicitly that this hand-made window carries them.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("AgentDropMainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
