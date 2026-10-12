import AgentDropApp
import AgentDropCore
import SwiftUI

/// The main window once the folder is served (spec §6 Main window).
struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner, model: model)
            }
            if let error = model.library.loadError {
                NoticeBar(text: "Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle")
            }
            NavigationSplitView {
                SidebarView(library: model.library)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                DropListView(library: model.library)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340)
            } detail: {
                DetailView(library: model.library)
            }
        }
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let model: AppModel

    var body: some View {
        switch banner {
        case .noPort:
            NoticeBar(text: "No free port for the local server, so `drop watch` and other apps can't connect. Agent Drop still records changes; they catch up once connected.",
                      systemImage: "network.slash") {
                Button("Retry") { Task { await model.retryPort() } }
            }
        case .invalidRetention:
            NoticeBar(text: "config.json has an invalid eventRetentionDays value, so 30 days is used. Fix it in Settings → Event history.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}

/// A one-line strip above the window's content.
struct NoticeBar<Accessory: View>: View {
    let text: String
    let systemImage: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

extension NoticeBar where Accessory == EmptyView {
    init(text: String, systemImage: String) {
        self.init(text: text, systemImage: systemImage) { EmptyView() }
    }
}
