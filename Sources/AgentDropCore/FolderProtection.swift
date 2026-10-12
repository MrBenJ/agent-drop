import Foundation

/// Spec §3 "Protected-folder confirmation": locations where macOS asks before an app
/// reads them, plus removable and network volumes.
public enum FolderProtection {
    public static func isProtected(_ folder: URL, homeDir: URL) -> Bool {
        // The path as written first, without touching the disk: looking inside a protected
        // folder (even a stat) can make macOS ask for access, and the app must explain
        // that prompt before it appears (spec §2). The app's setup screen asks this.
        if isUnderProtectedRoot(folder.standardizedFileURL.path.lowercased(),
                                home: homeDir.standardizedFileURL.path.lowercased()) { return true }
        // Then real paths, case-insensitively: `~/desktop` and a symlink to ~/Desktop
        // reach the same protected folder on a default (case-insensitive) APFS volume.
        if isUnderProtectedRoot(canonical(folder), home: canonical(homeDir)) { return true }
        return isOnRemovableOrNetworkVolume(folder.standardizedFileURL)
    }

    private static func isUnderProtectedRoot(_ path: String, home: String) -> Bool {
        ["desktop", "documents", "downloads", "library/mobile documents"]
            .map { home + "/" + $0 }
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// realpath(3) of the nearest existing ancestor plus the rest, lowercased.
    static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path
        if let resolved = realpath(existing.path, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        let joined = ([base == "/" ? "" : base] + rest).joined(separator: "/")
        return (joined.isEmpty ? "/" : joined).lowercased()
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
