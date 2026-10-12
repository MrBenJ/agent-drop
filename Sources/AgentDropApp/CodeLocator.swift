import Foundation

/// Spec §6 **Open in VS Code**: `code <path>`. Apps started from Finder or at login get
/// a minimal PATH, so the usual install locations are checked too.
public enum CodeLocator {
    public static func find(path: String? = ProcessInfo.processInfo.environment["PATH"],
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let directories = (path ?? "").split(separator: ":").map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"]
        let bundled = "Visual Studio Code.app/Contents/Resources/app/bin/code"
        let candidates = directories.map { $0 + "/code" }
            + ["/Applications/" + bundled, home.appendingPathComponent("Applications/" + bundled).path]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Starts `code` without waiting for it. A folder drop opens as a workspace.
    public static func open(_ item: URL, with code: URL) throws {
        let process = Process()
        process.executableURL = code
        process.arguments = [item.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
