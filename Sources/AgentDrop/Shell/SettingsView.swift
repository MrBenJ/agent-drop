import AgentDropApp
import AgentDropCore
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
        .onAppear { launchAtLogin = model.launchesAtLogin }
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
