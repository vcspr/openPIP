import XCTest
@testable import OpenPiPCore

/// Made-up lines in the shape of Claude Code session logs (~/.claude/projects/<dir>/<session>.jsonl).
enum Lines {
    static func toolUse(_ id: String, _ name: String, _ input: String, at time: String = "2026-11-01T18:00:00.000Z") -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    static func result(_ id: String, content: String = "\"ok\"", toolUseResult: String? = nil, isError: Bool = false) -> String {
        let tur = toolUseResult.map { #","toolUseResult":\#($0)"# } ?? ""
        return #"{"type":"user","timestamp":"2026-11-01T18:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":\#(content),"is_error":\#(isError)}]}\#(tur)}"#
    }

    static func text(_ s: String) -> String {
        #"{"type":"assistant","timestamp":"2026-11-01T18:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(s)"}]}}"#
    }

    static func title(_ s: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(s)","sessionId":"s1"}"#
    }
}

final class SessionStateTests: XCTestCase {
    func testTitleComesFromLatestAiTitle() {
        var s = SessionState()
        s.apply(Lines.title("First"))
        s.apply(Lines.title("Build the bike sheet"))
        XCTAssertEqual(s.title, "Build the bike sheet")
    }

    func testCustomTitleFromTheDesktopAppWinsOverAiTitle() {
        var s = SessionState()
        s.apply(Lines.title("Auto title"))
        s.apply(#"{"type":"custom-title","customTitle":"Cord guides on R3","sessionId":"s1"}"#)
        s.apply(Lines.title("Later auto title"))
        XCTAssertEqual(s.title, "Cord guides on R3")
        XCTAssertTrue(SessionState.isTaskRelated(#"{"type":"custom-title","customTitle":"x"}"#))
    }

    func testTaskCreateThenUpdateByReturnedId() {
        var s = SessionState()
        s.apply(Lines.toolUse("t1", "TaskCreate", #"{"subject":"Back up originals","description":"x"}"#))
        s.apply(Lines.result("t1", toolUseResult: #"{"task":{"id":"1","subject":"Back up originals"}}"#))
        s.apply(Lines.toolUse("t2", "TaskCreate", #"{"subject":"Run gates","description":"y"}"#))
        s.apply(Lines.result("t2", toolUseResult: #"{"task":{"id":"2","subject":"Run gates"}}"#))
        s.apply(Lines.toolUse("u1", "TaskUpdate", #"{"taskId":"1","status":"completed"}"#))
        s.apply(Lines.toolUse("u2", "TaskUpdate", #"{"taskId":"2","status":"in_progress"}"#))
        XCTAssertEqual(s.tasks.map(\.title), ["Back up originals", "Run gates"])
        XCTAssertEqual(s.tasks.map(\.status), [.completed, .inProgress])
        XCTAssertEqual(s.progress.done, 1)
        XCTAssertEqual(s.progress.total, 2)
    }

    func testNumericTaskIdsMatchToo() {
        var s = SessionState()
        s.apply(Lines.toolUse("t1", "TaskCreate", #"{"subject":"A"}"#))
        s.apply(Lines.result("t1", toolUseResult: #"{"task":{"id":7,"subject":"A"}}"#))
        s.apply(Lines.toolUse("u1", "TaskUpdate", #"{"taskId":7,"status":"completed"}"#))
        XCTAssertEqual(s.tasks.first?.status, .completed)
    }

    func testDeletedTaskIsRemoved() {
        var s = SessionState()
        s.apply(Lines.toolUse("t1", "TaskCreate", #"{"subject":"A"}"#))
        s.apply(Lines.result("t1", toolUseResult: #"{"task":{"id":"1","subject":"A"}}"#))
        s.apply(Lines.toolUse("u1", "TaskUpdate", #"{"taskId":"1","status":"deleted"}"#))
        XCTAssertTrue(s.tasks.isEmpty)
    }

    func testTodoWriteReplacesTheList() {
        var s = SessionState()
        s.apply(Lines.toolUse("w1", "TodoWrite", #"{"todos":[{"content":"One","status":"completed"},{"content":"Two","status":"in_progress"},{"content":"Three","status":"pending"}]}"#))
        XCTAssertEqual(s.tasks.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(s.tasks.map(\.status), [.completed, .inProgress, .pending])
    }

    func testDesktopPlanItemsAndAdvance() {
        var s = SessionState()
        s.apply(Lines.toolUse("p1", "mcp__ccd_turn__update_plan", #"{"items":[{"content":"Read","status":"in_progress"},{"content":"Fix","status":"pending"}]}"#))
        s.apply(Lines.toolUse("p2", "mcp__ccd_turn__update_plan", #"{"advance":true}"#))
        XCTAssertEqual(s.tasks.map(\.status), [.completed, .inProgress])
    }

    func testBashCommandAndItsOutput() throws {
        var s = SessionState()
        s.apply(Lines.toolUse("b1", "Bash", #"{"command":"swift test","timeout":600}"#))
        var entry = try XCTUnwrap(s.terminal.last)
        XCTAssertEqual(entry.command, "swift test")
        XCTAssertTrue(entry.running)
        s.apply(Lines.result("b1", toolUseResult: #"{"stdout":"one\ntwo\nthree","stderr":"","interrupted":false}"#))
        entry = try XCTUnwrap(s.terminal.last)
        XCTAssertFalse(entry.running)
        XCTAssertFalse(entry.failed)
        XCTAssertEqual(entry.output, ["one", "two", "three"])
    }

    func testFailedCommandIsMarked() {
        var s = SessionState()
        s.apply(Lines.toolUse("b1", "Bash", #"{"command":"false"}"#))
        s.apply(Lines.result("b1", content: #""Exit code 1""#, isError: true))
        XCTAssertEqual(s.terminal.last?.failed, true)
        XCTAssertEqual(s.terminal.last?.output, ["Exit code 1"])
    }

    func testOutputKeepsLastLinesAndDropsColorCodes() {
        var s = SessionState()
        let many = (1...30).map { "line \($0)" }.joined(separator: "\\n")
        s.apply(Lines.toolUse("b1", "Bash", #"{"command":"seq"}"#))
        s.apply(Lines.result("b1", toolUseResult: #"{"stdout":"\u001b[32m\#(many)\u001b[0m","stderr":""}"#))
        XCTAssertEqual(s.terminal.last?.output.count, TerminalEntry.maxLines)
        XCTAssertEqual(s.terminal.last?.output.last, "line 30")
    }

    func testOutputSkipsBlankLinesAndCwdNotices() {
        var s = SessionState()
        s.apply(Lines.toolUse("b1", "Bash", #"{"command":"run"}"#))
        s.apply(Lines.result("b1", toolUseResult: #"{"stdout":"started\n\n   \nShell cwd was reset to /Users/x\ndone","stderr":""}"#))
        XCTAssertEqual(s.terminal.last?.output, ["started", "done"])
    }

    func testTerminalKeepsOnlyRecentCommands() {
        var s = SessionState()
        for i in 1...9 { s.apply(Lines.toolUse("b\(i)", "Bash", #"{"command":"echo \#(i)"}"#)) }
        XCTAssertEqual(s.terminal.count, SessionState.maxTerminalEntries)
        XCTAssertEqual(s.terminal.last?.command, "echo 9")
    }

    func testLastActionDescribesTheLatestStep() {
        var s = SessionState()
        s.apply(Lines.toolUse("r1", "Read", #"{"file_path":"/Users/x/Sources/App.swift"}"#))
        XCTAssertEqual(s.lastAction, "Read · App.swift")
        s.apply(Lines.toolUse("m1", "mcp__open-computer-use__click", #"{"app":"Notes"}"#))
        XCTAssertEqual(s.lastAction, "click · Notes")
        s.apply(Lines.toolUse("b1", "Bash", #"{"command":"swift build\nswift test"}"#))
        XCTAssertEqual(s.lastAction, "$ swift build")
        s.apply(Lines.text(#"All 79 tests pass.\nNext I build."#))
        XCTAssertEqual(s.lastAction, "All 79 tests pass.")
    }

    func testTimestampIsRead() throws {
        var s = SessionState()
        s.apply(Lines.toolUse("r1", "Read", #"{"file_path":"a"}"#, at: "2026-11-01T18:30:15.250Z"))
        let t = try XCTUnwrap(s.lastTimestamp)
        XCTAssertEqual(t.timeIntervalSince1970, 1_793_557_815.25, accuracy: 0.01)
    }

    func testIrrelevantAndBrokenLinesChangeNothing() {
        var s = SessionState()
        XCTAssertFalse(s.apply(#"{"type":"api-request","x":1}"#))
        XCTAssertFalse(s.apply("not json"))
        XCTAssertFalse(s.apply(""))
        XCTAssertEqual(s, SessionState())
    }

    func testTaskFilterFindsOnlyTaskAndTitleLines() {
        XCTAssertTrue(SessionState.isTaskRelated(Lines.toolUse("t", "TaskCreate", "{}")))
        XCTAssertTrue(SessionState.isTaskRelated(Lines.toolUse("t", "TodoWrite", "{}")))
        XCTAssertTrue(SessionState.isTaskRelated(Lines.title("x")))
        XCTAssertTrue(SessionState.isTaskRelated(Lines.result("t", toolUseResult: #"{"task":{"id":"1"}}"#)))
        XCTAssertFalse(SessionState.isTaskRelated(Lines.toolUse("b", "Bash", #"{"command":"ls"}"#)))
    }
}
