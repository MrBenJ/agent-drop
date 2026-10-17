import Foundation
import Testing

struct SkillFilesTests {
    static let root: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path),
              dir.path != "/" {
            dir.deleteLastPathComponent()
        }
        return dir
    }()

    static let openclaw = root.appendingPathComponent("skills/openclaw/agent-drop-send/SKILL.md")
    static let hermes = root.appendingPathComponent("skills/hermes/agent-drop-send/SKILL.md")
    static let installer = root.appendingPathComponent("Scripts/install-agent-skills.sh")

    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func bothSkillsExistWithFrontMatter() throws {
        for url in [Self.openclaw, Self.hermes] {
            #expect(try Self.text(url).hasPrefix("---\nname: agent-drop-send\n"))
        }
    }

    @Test func skillsUseTheRealCLISurface() throws {
        for url in [Self.openclaw, Self.hermes] {
            // The mandated homepage URL contains the repo owner's handle; ignore it.
            let t = try Self.text(url).replacingOccurrences(of: "https://github.com/MrBenJ/agent-drop", with: "")
            for needle in ["--to laptop", "--from", "drop remote list", "--json"] {
                #expect(t.contains(needle), "\(url.path) missing \(needle)")
            }
            #expect(!t.contains("Ben"))
            #expect(!t.contains("Aria"))
        }
    }

    @Test func hermesHasPrerequisites() throws {
        let t = try Self.text(Self.hermes)
        #expect(t.contains("commands: [drop]"))
        #expect(t.contains("platforms: [macos]"))
    }

    struct Result { var code: Int32; var out: String }

    static func runInstaller(_ args: [String], openclaw: URL, hermes: URL) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [installer.path] + args
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": openclaw.deletingLastPathComponent().path,
            "OPENCLAW_SKILLS_DIR": openclaw.path,
            "HERMES_SKILLS_DIR": hermes.path,
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    static func tempDirs() throws -> (base: URL, openclaw: URL, hermes: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("openclaw-skills"), base.appendingPathComponent("hermes-skills"))
    }

    @Test func installerDryRunPrintsBothDestinations() throws {
        let d = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: d.base) }
        let r = try Self.runInstaller(["--openclaw", "--hermes", "--dry-run"], openclaw: d.openclaw, hermes: d.hermes)
        #expect(r.code == 0)
        #expect(r.out.contains(d.openclaw.appendingPathComponent("agent-drop-send").path))
        #expect(r.out.contains(d.hermes.appendingPathComponent("agent-drop-send").path))
        #expect(!FileManager.default.fileExists(atPath: d.openclaw.path))
        #expect(!FileManager.default.fileExists(atPath: d.hermes.path))
    }

    @Test func installerCopies() throws {
        let d = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: d.base) }
        let first = try Self.runInstaller(["--openclaw", "--hermes"], openclaw: d.openclaw, hermes: d.hermes)
        #expect(first.code == 0)
        // A second run replaces the existing copy.
        let stale = d.openclaw.appendingPathComponent("agent-drop-send/stale.txt")
        try "x".write(to: stale, atomically: true, encoding: .utf8)
        let second = try Self.runInstaller(["--openclaw", "--hermes"], openclaw: d.openclaw, hermes: d.hermes)
        #expect(second.code == 0)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        for dir in [d.openclaw, d.hermes] {
            let f = dir.appendingPathComponent("agent-drop-send/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: f.path))
        }
        #expect(try Self.text(d.hermes.appendingPathComponent("agent-drop-send/SKILL.md")) == Self.text(Self.hermes))
    }

    @Test func installerWithoutFlagsExits2() throws {
        let d = try Self.tempDirs()
        defer { try? FileManager.default.removeItem(at: d.base) }
        let r = try Self.runInstaller([], openclaw: d.openclaw, hermes: d.hermes)
        #expect(r.code == 2)
        #expect(r.out.contains("Usage"))
    }
}
