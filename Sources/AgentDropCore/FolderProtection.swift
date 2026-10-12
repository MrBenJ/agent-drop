import Foundation

/// Spec §3 "Protected-folder confirmation": locations where macOS asks before an app
/// reads them, plus removable and network volumes.
public enum FolderProtection {
    public static func isProtected(_ folder: URL, homeDir: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let home = homeDir.standardizedFileURL.path
        let protectedRoots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { home + "/" + $0 }
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return isOnRemovableOrNetworkVolume(folder.standardizedFileURL)
    }

    /// The folder may not exist yet, so ask about its nearest existing ancestor.
    private static func isOnRemovableOrNetworkVolume(_ folder: URL) -> Bool {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsLocal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true
    }
}

extension ConfigStore {
    /// True when the configured folder is protected and hasn't been confirmed in the app.
    /// Until then the app's server and watcher stay off and `drop watch` exits 1.
    public func folderNeedsConfirmation(_ config: AgentDropConfig) -> Bool {
        let folder = folderURL(config).standardizedFileURL
        guard FolderProtection.isProtected(folder, homeDir: homeDir) else { return false }
        return config.confirmedFolder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } != folder.path
    }

    /// Written by the app when first-run setup finishes (spec §2).
    public func setSetupComplete(_ complete: Bool) throws {
        var dict = try readDict()
        dict["setupComplete"] = complete
        try writeDict(dict)
    }

    /// Written by the app when the user confirms a protected folder (spec §3).
    public func setConfirmedFolder(_ url: URL?) throws {
        var dict = try readDict()
        dict["confirmedFolder"] = url?.standardizedFileURL.path
        try writeDict(dict)
    }
}
