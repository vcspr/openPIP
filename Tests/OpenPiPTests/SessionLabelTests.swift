import XCTest
@testable import OpenPiPCore

final class SessionLabelTests: XCTestCase {
    let home = "/Users/test"

    func testOpenBotAgentFolder() {
        let l = SessionLabel(projectDir: "-Users-test-OpenBot-Agents-agent-142ae87e-6909-48b0-933d-125a162a9f35", home: home)
        XCTAssertEqual(l.openBotAgentID, "agent-142ae87e-6909-48b0-933d-125a162a9f35")
        XCTAssertEqual(l.text, "OpenBot agent")
    }

    func testOpenBotNameWhenKnown() {
        let l = SessionLabel(projectDir: "-Users-test-OpenBot-Agents-agent-abc", home: home,
                             openBotNames: ["agent-abc": "Crate Digger"])
        XCTAssertEqual(l.text, "OpenBot · Crate Digger")
    }

    func testFolderUnderHome() {
        XCTAssertEqual(SessionLabel(projectDir: "-Users-test-Design-Brain", home: home).text, "Design Brain")
        XCTAssertNil(SessionLabel(projectDir: "-Users-test-Design-Brain", home: home).openBotAgentID)
    }

    func testHomeItself() {
        XCTAssertEqual(SessionLabel(projectDir: "-Users-test", home: home).text, "Home")
    }

    func testFolderOutsideHome() {
        XCTAssertEqual(SessionLabel(projectDir: "-private-tmp-work", home: home).text, "private tmp work")
    }

    func testHomeWithDotsIsMatched() {
        XCTAssertEqual(SessionLabel(projectDir: "-Users-j-doe-Code", home: "/Users/j.doe").text, "Code")
    }

    func testWorkFolderGivesTheLastFolderName() {
        let l = SessionLabel(projectDir: "-Users-test-Documents-Notes-Work-shop-app", home: home,
                             cwd: "/Users/test/Documents/Notes/Work/shop-app")
        XCTAssertEqual(l.text, "shop-app")
    }

    func testWorktreeUsesTheRepoName() {
        let l = SessionLabel(projectDir: "-x", home: home,
                             cwd: "/Users/test/Code/app/.claude/worktrees/keen-ardinghelli-cfff41")
        XCTAssertEqual(l.text, "app")
    }

    func testWorkFolderAtHomeIsHome() {
        XCTAssertEqual(SessionLabel(projectDir: "-Users-test", home: home, cwd: "/Users/test").text, "Home")
    }

    func testOpenMausBotBackgroundRun() {
        let l = SessionLabel(projectDir: "-private-var-folders-60-x-T-omb-claude-background-AADUVM", home: home,
                             cwd: "/private/var/folders/60/x/T/omb-claude-background-AADUVM")
        XCTAssertEqual(l.text, "OpenMausBot agent")
    }

    func testOpenBotNameWinsOverWorkFolder() {
        let l = SessionLabel(projectDir: "-Users-test-OpenBot-Agents-agent-abc", home: home,
                             openBotNames: ["agent-abc": "Crate Digger"], cwd: "/Users/test/OpenBot/Agents/agent-abc")
        XCTAssertEqual(l.text, "OpenBot · Crate Digger")
    }
}
