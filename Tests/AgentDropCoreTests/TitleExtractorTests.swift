import Foundation
import Testing
@testable import AgentDropCore

struct TitleExtractorTests {
    private func title(_ data: Data, name: String = "doc.md") throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return TitleExtractor.title(for: url, isFolder: false)
    }

    @Test func headingBeyondThePrefixIsNotFound() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: TitleExtractor.maxScanBytes + 10)
        data.append(Data("\n# Late\n".utf8))
        #expect(try title(data) == nil)
    }

    @Test func headingNearTheTopIsFoundInALargeFile() throws {
        var data = Data("intro\n# Early\n".utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: TitleExtractor.maxScanBytes * 4))
        #expect(try title(data) == "Early")
    }

    @Test func longHeadingIsCapped() throws {
        let long = String(repeating: "x", count: TitleExtractor.maxTitleLength + 50)
        #expect(try title(Data("# \(long)\n".utf8)) == String(repeating: "x", count: TitleExtractor.maxTitleLength))
    }

    @Test func multibyteSequenceCutAtThePrefixBoundaryStillParses() throws {
        var data = Data("# Héllo\n".utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: TitleExtractor.maxScanBytes - data.count - 1))
        data.append(Data("é".utf8))  // straddles the boundary
        data.append(Data("\n".utf8))
        #expect(try title(data) == "Héllo")
    }

    @Test func newlineOnlyFileFallsBackWithoutReadingItAll() throws {
        let data = Data(repeating: UInt8(ascii: "\n"), count: 8 * 1_048_576)
        #expect(try title(data) == nil)
    }
}
