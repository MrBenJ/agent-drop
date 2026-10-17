import AgentDropApp
import AgentDropCore
import AgentDropServer
import AppKit
import SwiftUI

/// Spec §6 settings and §5.1 Settings → Event history.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            EventHistorySettings(model: model)
                .tabItem { Label("Event history", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @State private var receiveFromTailnet = false
    @State private var confirmingRegenerate = false

    var body: some View {
        Form {
            LabeledContent("Drop folder") {
                HStack {
                    Text(model.folder.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Change…") {
                        if let url = FolderPicker.choose(startingAt: model.folder) {
                            Task { await model.chooseFolder(url) }
                        }
                    }
                }
            }
            LabeledContent("Local server") {
                HStack {
                    Text(serverText)
                    if model.serverState == .noPort {
                        Button("Retry") { Task { await model.retryPort() } }
                    }
                }
            }
            tailnetSection
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != model.launchesAtLogin else { return }
                    model.setLaunchesAtLogin(enabled)
                    launchAtLogin = model.launchesAtLogin
                }
            if let error = model.loginItemError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Toggle("Hide Dock icon", isOn: Bindable(model.settings).hideDockIcon)
                .onChange(of: model.settings.hideDockIcon) { _, hidden in DockIcon.apply(hidden: hidden) }
            Toggle("Notify on new drops", isOn: Bindable(model.settings).notifyOnNewDrops)
        }
        .onAppear {
            launchAtLogin = model.launchesAtLogin
            receiveFromTailnet = model.settings.receiveFromTailnet
        }
        .onChange(of: model.settings.receiveFromTailnet) { _, on in receiveFromTailnet = on }
        .alert("Regenerate the key?", isPresented: $confirmingRegenerate) {
            Button("Regenerate", role: .destructive) { model.regenerateTailnetKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Senders using the old key will stop working until you run the new setup command on them.")
        }
    }

    @ViewBuilder private var tailnetSection: some View {
        Section("Tailnet") {
            Toggle("Receive drops from my tailnet", isOn: $receiveFromTailnet)
                .onChange(of: receiveFromTailnet) { _, on in
                    guard on != model.settings.receiveFromTailnet else { return }
                    Task {
                        await model.setReceiveFromTailnet(on)
                        receiveFromTailnet = model.settings.receiveFromTailnet
                    }
                }
            Text("Only devices on your Tailscale network can connect, and they can only send drops — never read them. If the macOS firewall is on, allow Agent Drop when asked.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Status") { Text(tailnetText) }
            if case .receiving = model.tailnetState {
                HStack {
                    Button("Copy setup command") {
                        guard let command = model.tailnetSetupCommand else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    Button("Regenerate key") { confirmingRegenerate = true }
                }
            }
            if let error = model.tailnetError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var tailnetText: String {
        switch model.tailnetState {
        case .off: "Off"
        case .waiting: "Starts when Agent Drop is serving"
        case .notConnected: "Tailscale not connected"
        case .portInUse(let port): "Port \(port) is in use"
        case .receiving(let host, let port): "Receiving on \(host):\(port)"
        }
    }

    private var serverText: String {
        switch model.serverState {
        case .running(let port): "Running on 127.0.0.1:\(port)"
        case .noPort: "No free port"
        case .stopped: "Off"
        }
    }
}

struct EventHistorySettings: View {
    let model: AppModel
    @State private var choice: RetentionChoice = .days30
    @State private var customDays = ""
    @State private var customError: String?

    var body: some View {
        Form {
            Picker("Keep change-log entries for", selection: $choice) {
                ForEach(RetentionChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: choice) { _, newChoice in
                guard let retention = newChoice.retention,
                      retention != model.config.eventRetentionDays || model.config.retentionWasInvalid else { return }
                Task { await model.setRetention(retention) }
            }
            if choice == .custom {
                HStack {
                    TextField("Days", text: $customDays).frame(width: 80)
                    Text("days")
                    Button("Apply") {
                        guard let retention = Retention(argument: customDays.trimmingCharacters(in: .whitespaces)),
                              retention != .forever else {
                            customError = "Enter a whole number of days, 1 or more."
                            return
                        }
                        customError = nil
                        Task { await model.setRetention(retention) }
                    }
                }
                if let customError { Text(customError).foregroundStyle(.red).font(.callout) }
            }
            if model.config.retentionWasInvalid {
                HStack {
                    Text("config.json has an invalid value, so 30 days is used until you choose one here.")
                        .foregroundStyle(.orange).font(.callout)
                    Button("Use 30 Days") { Task { await model.setRetention(.default) } }
                }
            }
            Text(RetentionChoice.note).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: sync)
        .onChange(of: model.config.eventRetentionDays) { _, _ in sync() }
    }

    /// Shows whatever config.json holds, including a value set from the CLI.
    private func sync() {
        choice = RetentionChoice(model.config.eventRetentionDays)
        if case .days(let days) = model.config.eventRetentionDays { customDays = String(days) }
    }
}
