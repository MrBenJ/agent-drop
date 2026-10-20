import AgentDropApp
import AgentDropCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let notifications = SystemNotifications()
    private let launchOptions = LaunchOptions(arguments: CommandLine.arguments)
    private lazy var mainWindow = MainWindowController(model: model)

    override init() {
        model = AppModel(configStore: .live(), loginItem: SystemLoginItem(), settings: AppSettings(),
                         poster: notifications)
        super.init()
        model.showWindow = { [weak self] in self?.showMainWindow() }
        model.showWindowInBackground = { [weak self] in self?.mainWindow.showInBackground() }
        notifications.onOpen = { [weak self] dropID in
            guard let self else { return }
            if let dropID {
                Task { await self.model.open(dropID: dropID) }
            } else {
                self.showMainWindow()
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `drop open` sends agentdrop://drop/<id> (spec §4); it can arrive before launch ends.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With no window open (a `--windowless` launch, or the window closed) macOS would
        // otherwise mark the app for automatic termination and could quit it, taking the
        // server `drop watch` relies on with it. It runs until the user quits it (spec §4).
        // SwiftUI turns support on at runtime, so the Info.plist opt-out alone isn't enough.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Agent Drop serves drop watch and other apps")
        DockIcon.apply(hidden: model.settings.hideDockIcon)
        // Quick Look snapshots left by a previous run.
        try? FileManager.default.removeItem(at: NoFollowFile.snapshotRoot)
        Task {
            await model.launch()
            // Setup always shows its window (spec §2), even for a windowless launch.
            if !launchOptions.windowless || model.phase == .setup {
                launchOptions.background ? mainWindow.showInBackground() : showMainWindow()
            }
        }
    }

    /// Clicking the Dock icon (or opening the app again) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Spec §6: closing the window doesn't quit; the menu bar keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Stop the service first, so server.json is removed on a clean quit (spec §5.2).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task { await model.open(url) }
    }

    func showMainWindow() {
        mainWindow.show()
    }
}

/// Spec §6 "Hide Dock icon": accessory activation policy, menu bar only.
enum DockIcon {
    @MainActor static func apply(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
    }
}
