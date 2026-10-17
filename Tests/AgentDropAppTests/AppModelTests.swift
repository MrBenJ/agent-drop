import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore
@testable import AgentDropServer

final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Bool] = []
    var failure: AgentDropError?
    var calls: [Bool] { lock.withLock { _calls } }
    var isEnabled: Bool { calls.last ?? false }
    func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        lock.withLock { _calls.append(enabled) }
    }
}

/// A scratch home with its own config.json. Nothing here touches real paths.
@MainActor
final class AppFixture {
    let scratch: Scratch
    let config: ConfigStore
    let loginItem = FakeLoginItem()
    let defaults: UserDefaults
    private(set) var models: [AppModel] = []

    init() throws {
        scratch = try Scratch()
        config = ConfigStore(configDir: scratch.url.appendingPathComponent("support", isDirectory: true),
                             homeDir: scratch.url.appendingPathComponent("home", isDirectory: true))
        let suite = "agentdrop-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    var defaultFolder: URL { config.defaultFolder }
    var desktopFolder: URL { config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true) }
    var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    func model(poster: NoticePosting? = nil) -> AppModel {
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        options.debounce = .milliseconds(50)
        let model = AppModel(configStore: config, loginItem: loginItem, settings: AppSettings(defaults: defaults),
                             poster: poster, serviceOptions: options)
        models.append(model)
        return model
    }

    /// Setup already finished in an earlier run.
    func finishedSetup(folder: URL? = nil) throws {
        if let folder { try config.setFolder(folder) }
        try config.setSetupComplete(true)
    }

    func stopAll() async {
        for model in models { await model.shutdown() }
    }
}

@MainActor
struct AppModelSetupTests {
    @Test func beforeSetupNothingButConfigIsTouched() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        #expect(model.phase == .setup)
        #expect(!FileManager.default.fileExists(atPath: f.defaultFolder.path))
        #expect(f.infoFile.read() == nil)
        #expect(model.menuStatus == "Finish setting up Agent Drop…")
        await f.stopAll()
    }

    @Test func finishingSetupCreatesTheFolderStartsServingAndSetsTheLoginItem() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        #expect(model.launchAtLogin) // Yes is pre-selected
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(try f.config.load().setupComplete)
        #expect(try f.config.load().confirmedFolder == nil) // the default folder isn't protected
        #expect(FileManager.default.fileExists(atPath: f.defaultFolder.path))
        #expect(f.loginItem.calls == [true])
        #expect(f.infoFile.read()?.status == .running)
        #expect(model.library.store?.folder.path == f.defaultFolder.path)
        await f.stopAll()
        #expect(f.infoFile.read() == nil) // removed on clean quit
    }

    @Test func declinedLoginItemAndALoginItemFailureStillFinishSetup() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        model.launchAtLogin = false
        f.loginItem.failure = .invalid("not allowed")
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(model.loginItemError?.contains("not allowed") == true)
        await f.stopAll()
    }

    @Test func aProtectedFolderIsConfirmedByFinishingSetup() async throws {
        let f = try AppFixture()
        try f.config.setFolder(f.desktopFolder) // e.g. `drop config set-folder` before setup
        let model = f.model()
        await model.launch()
        #expect(model.folderIsProtected)
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(try f.config.load().confirmedFolder == f.desktopFolder.standardizedFileURL.path)
        await f.stopAll()
    }

    @Test func aFolderThatCantBeCreatedKeepsSetupOpen() async throws {
        let f = try AppFixture()
        let blocker = f.scratch.url.appendingPathComponent("file")
        try Data().write(to: blocker)
        try f.config.setFolder(blocker.appendingPathComponent("AgentDrop"))
        let model = f.model()
        await model.launch()
        await model.completeSetup()
        #expect(model.phase == .setup)
        #expect(model.folderError?.contains("can't use") == true)
        #expect(try f.config.load().setupComplete == false)
        await f.stopAll()
    }

    @Test func choosingAFolderDuringSetupOnlyRecordsIt() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        let chosen = f.scratch.url.appendingPathComponent("Chosen", isDirectory: true)
        await model.chooseFolder(chosen)
        #expect(model.phase == .setup && model.folder.path == chosen.path)
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        await f.stopAll()
    }
}

@MainActor
struct AppModelFolderTests {
    @Test func anUnconfirmedProtectedFolderWaitsForConfirmation() async throws {
        let f = try AppFixture()
        try f.finishedSetup(folder: f.desktopFolder)
        let model = f.model()
        await model.launch()
        #expect(model.phase == .confirmFolder)
        #expect(model.menuStatus == "Drop folder changed — confirm")
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        #expect(f.infoFile.read() == nil)

        await model.confirmFolder()
        #expect(model.phase == .running)
        #expect(try f.config.load().confirmedFolder == f.desktopFolder.standardizedFileURL.path)
        await f.stopAll()
    }

    @Test func theCLISwitchingToAnUnprotectedFolderAppliesImmediately() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let firstToken = f.infoFile.read()?.token
        let other = f.scratch.url.appendingPathComponent("Other", isDirectory: true)
        try f.config.setFolder(other) // `drop config set-folder`, seen through the config watcher
        #expect(await eventually { model.library.store?.folder.path == other.path })
        #expect(model.phase == .running)
        #expect(await eventually { f.infoFile.read()?.token != firstToken })
        await f.stopAll()
    }

    @Test func theCLISwitchingToAProtectedFolderStopsTheServer() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        try f.config.setFolder(f.desktopFolder)
        await model.configDidChange()
        #expect(model.phase == .confirmFolder)
        #expect(model.library.store == nil)
        #expect(f.infoFile.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        await f.stopAll()
    }

    @Test func choosingAProtectedFolderInTheAppNeedsNoConfirmation() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        await model.chooseFolder(f.desktopFolder)
        #expect(model.phase == .running)
        #expect(model.library.store?.folder.path == f.desktopFolder.path)
        await f.stopAll()
    }

    @Test func retentionChangesApplyWithoutARestart() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let token = f.infoFile.read()?.token
        await model.setRetention(.forever)
        #expect(model.library.store?.retention == .forever)
        #expect(f.infoFile.read()?.token == token)
        await f.stopAll()
    }

    @Test func invalidRetentionShowsABanner() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        var dict = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config.configFile)) as! [String: Any]
        dict["eventRetentionDays"] = "lots"
        try JSONSerialization.data(withJSONObject: dict).write(to: f.config.configFile)
        let model = f.model()
        await model.launch()
        #expect(model.banners == [.invalidRetention])
        await f.stopAll()
    }

    @Test func aStoreThatCantOpenIsAnError() async throws {
        let f = try AppFixture()
        let blocker = f.scratch.url.appendingPathComponent("file")
        try Data().write(to: blocker)
        try f.finishedSetup(folder: blocker)
        let model = f.model()
        await model.launch()
        guard case .storeError = model.phase else {
            Issue.record("expected storeError, got \(model.phase)")
            return
        }
        #expect(model.menuStatus == "Can't open the drop store")

        // Fixed outside the app (the file moved away): Try Again recovers.
        try FileManager.default.removeItem(at: blocker)
        await model.retryStore()
        #expect(model.phase == .running)
        await f.stopAll()
    }

    @Test func launchAtLoginSettingReportsFailures() async throws {
        let f = try AppFixture()
        let model = f.model()
        model.setLaunchesAtLogin(true)
        #expect(model.launchesAtLogin && model.loginItemError == nil)
        f.loginItem.failure = .invalid("needs approval")
        model.setLaunchesAtLogin(false)
        #expect(model.launchesAtLogin && model.loginItemError?.contains("needs approval") == true)
        await f.stopAll()
    }

    @Test func noFreePortShowsTheRetryBanner() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        var options = AgentDropService.Options()
        let base = Int.random(in: 20_000...59_000)
        options.portBase = base
        options.portAttempts = 1
        let blocker = try PortBlocker(port: base)
        let model = AppModel(configStore: f.config, loginItem: f.loginItem, settings: AppSettings(defaults: f.defaults),
                             serviceOptions: options)
        await model.launch()
        #expect(model.phase == .running && model.banners == [.noPort])
        blocker.release()
        await model.retryPort()
        #expect(model.banners.isEmpty)
        await model.shutdown()
    }
}

@MainActor
struct AppModelLinkTests {
    @Test func aLinkBeforeSetupIsShownWhenSetupCompletes() async throws {
        let f = try AppFixture()
        // The CLI works before setup: an agent dropped something and ran `drop open`.
        let store = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: source)
        let drop = try store.add(AddRequest(source: .path(source), from: "agent"))

        let model = f.model()
        var windows = 0
        model.showWindow = { windows += 1 }
        await model.launch()
        await model.open(AppLink.url(forDrop: drop.id))
        #expect(model.pendingDropID == drop.id && windows == 1)
        await model.completeSetup()
        #expect(model.library.selection == [.drop(drop.id)])
        #expect(model.pendingDropID == nil)
        await f.stopAll()
    }

    @Test func badLinksAndUnknownIdsAlert() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        await model.open(URL(string: "agentdrop://elsewhere")!)
        #expect(model.library.alert?.contains("can't open") == true)
        model.library.alert = nil
        await model.open(dropID: "zzzzzz")
        #expect(model.library.alert?.contains("zzzzzz") == true)
        await f.stopAll()
    }

    @Test func aLinkThatArrivesWhileLaunchingIsShownOnceServing() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let store = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: source)
        let drop = try store.add(AddRequest(source: .path(source), from: "agent"))

        let model = f.model()
        await model.open(dropID: drop.id) // `drop open` launched the app: the link beats launch()
        #expect(model.phase == .starting && model.pendingDropID == drop.id)
        await model.launch()
        #expect(model.library.selection == [.drop(drop.id)])
        await f.stopAll()
    }

    @Test func aBurstOfCLIWritesConverges() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        for i in 0..<60 {
            let source = f.scratch.url.appendingPathComponent("burst/\(i).md")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# \(i)".utf8).write(to: source)
            _ = try cli.add(AddRequest(source: .path(source), from: "agent"))
        }
        #expect(await eventually { model.library.drops.count == 60 })
        await f.stopAll()
    }

    @Test func aBrokenConfigWhileRunningKeepsServingAndSaysSo() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let good = try Data(contentsOf: f.config.configFile)
        try Data("{ half-written".utf8).write(to: f.config.configFile)
        await model.configDidChange()
        #expect(model.phase == .running && model.library.store != nil)
        // Visible without the window too: a banner and the menu's status line.
        #expect(model.configError?.contains("config.json") == true)
        #expect(model.banners.contains { if case .configError = $0 { true } else { false } })
        #expect(model.menuStatus?.contains("config.json") == true)

        try good.write(to: f.config.configFile)
        await model.configDidChange()
        #expect(model.phase == .running && model.configError == nil && model.banners.isEmpty)
        #expect(model.menuStatus == nil && model.library.alert == nil)
        await f.stopAll()
    }

    @Test func aBrokenConfigAtLaunchIsAnErrorNotFirstRunSetup() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let good = try Data(contentsOf: f.config.configFile)
        try Data("{ half-written".utf8).write(to: f.config.configFile)
        let model = f.model()
        await model.launch()
        guard case .configUnreadable(let message) = model.phase else {
            Issue.record("expected configUnreadable, got \(model.phase)")
            await f.stopAll()
            return
        }
        #expect(message.contains("config.json"))
        #expect(!FileManager.default.fileExists(atPath: f.defaultFolder.path))
        #expect(f.loginItem.calls.isEmpty)
        await model.completeSetup() // not offered, and does nothing if called
        #expect(f.loginItem.calls.isEmpty)

        try good.write(to: f.config.configFile)
        await model.configDidChange()
        #expect(model.phase == .running && model.configError == nil)
        await f.stopAll()
    }

    @Test func changesFromTheCLIReachTheLibrary() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("x.md")
        try Data("# X".utf8).write(to: source)
        let drop = try cli.add(AddRequest(source: .path(source), from: "agent"))
        #expect(await eventually { model.library.drop(drop.id) != nil })
        try Data("y".utf8).write(to: f.defaultFolder.appendingPathComponent("loose.txt"))
        #expect(await eventually { model.library.unregistered.map(\.name) == ["loose.txt"] })
        await f.stopAll()
    }
}

@MainActor
struct AppModelNotificationTests {
    @Test func theAppPostsForCLIDropsWhileRunning() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let poster = RecordingPoster()
        let model = f.model(poster: poster)
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("x.md")
        try Data("# From the CLI".utf8).write(to: source)
        _ = try cli.add(AddRequest(source: .path(source), from: "agent"))
        #expect(await eventually { poster.posted.map(\.title) == ["From the CLI"] })

        model.settings.notifyOnNewDrops = false
        let second = f.scratch.url.appendingPathComponent("y.md")
        try Data("# Quiet".utf8).write(to: second)
        _ = try cli.add(AddRequest(source: .path(second), from: "agent"))
        #expect(await eventually { model.library.drops.count == 2 })
        #expect(poster.posted.count == 1)
        await model.shutdown()
    }
}
