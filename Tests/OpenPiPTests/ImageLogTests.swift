import XCTest
@testable import OpenPiPCore

/// Log lines with a work folder, like the ones Claude Code writes.
private func use(_ name: String, _ input: String, cwd: String = "/w/proj",
                 at time: String = "2026-11-02T10:00:00.000Z") -> String {
    #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"\#(time)","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"\#(name)","input":\#(input)}]}}"#
}

final class ImageLogTests: XCTestCase {
    func testReadOfAnImageCountsAsLookedAt() {
        var log = ImageLog(home: "/Users/me")
        XCTAssertTrue(log.apply(use("Read", #"{"file_path":"/w/proj/render.png"}"#)))
        XCTAssertEqual(log.images.map(\.path), ["/w/proj/render.png"])
        XCTAssertEqual(log.images.first?.kind, .looked)
    }

    func testReadOfOtherFilesIsIgnored() {
        var log = ImageLog(home: "/Users/me")
        XCTAssertFalse(log.apply(use("Read", #"{"file_path":"/w/proj/notes.md"}"#)))
        XCTAssertFalse(log.apply(use("Bash", #"{"command":"open /w/proj/render.png"}"#)))
        XCTAssertTrue(log.images.isEmpty)
    }

    func testRelativeAndHomePathsAreResolved() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"out/a.JPG"}"#, cwd: "/Users/me/Art Work/projects"))
        log.apply(use("Read", #"{"file_path":"~/Downloads/b.webp"}"#))
        XCTAssertEqual(log.images.map(\.path),
                       ["/Users/me/Art Work/projects/out/a.JPG", "/Users/me/Downloads/b.webp"])
    }

    func testRelativeAndAbsolutePathsToTheSameFileMatch() throws {
        // /private/tmp also answers to /tmp. A relative path must not turn into the short form.
        let dir = "/private/tmp/openpip-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/r", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/r/a.png", contents: Data())
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"r/../r/a.png"}"#, cwd: dir))
        log.apply(use("SendUserFile", "{\"files\":[\"\(dir)/r/a.png\"]}", cwd: dir))
        XCTAssertEqual(log.images.map(\.path), [dir + "/r/a.png"])
        XCTAssertEqual(log.images.first?.kind, .shared)
    }

        func testSharedFilesFromSendUserFileAndOpenBot() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("SendUserFile", #"{"files":["/w/p/SHEET.jpg","/w/p/report.md"],"caption":"x.png is great"}"#))
        // OpenBot sometimes sends the list as a JSON string.
        log.apply(use("mcp__openbot__attach_files_to_response", #"{"paths":"[\"/w/p/B A.jpg\"]"}"#))
        XCTAssertEqual(log.images.map(\.path), ["/w/p/SHEET.jpg", "/w/p/B A.jpg"])
        XCTAssertEqual(log.images.map(\.kind), [.shared, .shared])
    }

    func testWriteCountsAsWrote() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Write", #"{"file_path":"/w/p/icon.svg.png","content":"..."}"#))
        XCTAssertEqual(log.images.first?.kind, .wrote)
    }

    func testSeeingAnImageAgainMovesItToTheEndAndKeepsTheStrongestKind() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"/w/a.png"}"#))
        log.apply(use("SendUserFile", #"{"files":["/w/a.png"]}"#))
        log.apply(use("Read", #"{"file_path":"/w/b.png"}"#))
        log.apply(use("Read", #"{"file_path":"/w/a.png"}"#))
        XCTAssertEqual(log.images.map(\.path), ["/w/b.png", "/w/a.png"])
        XCTAssertEqual(log.images.last?.kind, .shared)
    }

    func testKeepsOnlyTheNewest30() {
        var log = ImageLog(home: "/Users/me")
        for i in 0..<35 { log.apply(use("Read", #"{"file_path":"/w/\#(i).png"}"#)) }
        XCTAssertEqual(log.images.count, ImageLog.limit)
        XCTAssertEqual(log.images.first?.path, "/w/5.png")
        XCTAssertEqual(log.images.last?.path, "/w/34.png")
    }

    func testTimestampIsKept() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"/w/a.png"}"#, at: "2026-11-02T10:00:05.000Z"))
        XCTAssertEqual(log.images.first?.time, ISO8601DateFormatter().date(from: "2026-11-02T10:00:05Z"))
    }

    func testWorkFolderIsTheLatestCwd() {
        var log = ImageLog(home: "/Users/me")
        log.apply(#"{"type":"user","cwd":"/w/one","message":{"content":"hi"}}"#)
        log.apply(#"{"type":"user","cwd":"/w/two","message":{"content":"hi"}}"#)
        XCTAssertEqual(log.cwd, "/w/two")
    }

    func testFoundFilesAreAddedInTimeOrderWithoutDuplicates() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"/w/a.png"}"#, at: "2026-11-02T10:00:00.000Z"))
        log.apply(use("Read", #"{"file_path":"/w/c.png"}"#, at: "2026-11-02T10:02:00.000Z"))
        let t = ISO8601DateFormatter().date(from: "2026-11-02T10:01:00Z")!
        XCTAssertTrue(log.addFound("/w/b.png", at: t))
        XCTAssertFalse(log.addFound("/w/a.png", at: t))
        XCTAssertEqual(log.images.map(\.path), ["/w/a.png", "/w/b.png", "/w/c.png"])
        XCTAssertEqual(log.images[1].kind, .found)
        XCTAssertEqual(log.images[0].kind, .looked)
    }

    func testRemoveDropsMissingFiles() {
        var log = ImageLog(home: "/Users/me")
        log.apply(use("Read", #"{"file_path":"/w/a.png"}"#))
        XCTAssertTrue(log.remove("/w/a.png"))
        XCTAssertFalse(log.remove("/w/a.png"))
        XCTAssertTrue(log.images.isEmpty)
    }

    func testCheapSkimCheck() {
        XCTAssertTrue(ImageLog.isImageRelated(use("Read", #"{"file_path":"/w/a.PNG"}"#)))
        XCTAssertFalse(ImageLog.isImageRelated(use("Read", #"{"file_path":"/w/a.md"}"#)))
        XCTAssertFalse(ImageLog.isImageRelated(#"{"type":"user","message":{"content":"look at a.png"}}"#))
    }

    func testSessionStateCollectsImages() {
        var s = SessionState()
        XCTAssertTrue(s.apply(use("Read", #"{"file_path":"/w/a.png"}"#)))
        XCTAssertEqual(s.images.images.map(\.path), ["/w/a.png"])
    }
}
