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
}
