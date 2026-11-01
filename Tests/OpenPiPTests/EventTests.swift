import XCTest
@testable import OpenPiPCore

final class EventTests: XCTestCase {
    func testParsesFullStepEvent() throws {
        let line = #"{"v":1,"agent":"ocu","status":"step","text":"Clicking 'New Note'","app":"Notes","window":"Notes","pid":42,"x":412,"y":96}"#
        let e = try XCTUnwrap(Event.parse(line))
        XCTAssertEqual(e.agent, "ocu")
        XCTAssertEqual(e.status, .step)
        XCTAssertEqual(e.text, "Clicking 'New Note'")
        XCTAssertEqual(e.app, "Notes")
        XCTAssertEqual(e.window, "Notes")
        XCTAssertEqual(e.pid, 42)
        XCTAssertEqual(e.x, 412)
        XCTAssertEqual(e.y, 96)
    }

    func testOptionalFieldsMayBeMissing() throws {
        let e = try XCTUnwrap(Event.parse(#"{"v":1,"agent":"a","status":"end","text":"Done"}"#))
        XCTAssertEqual(e.status, .end)
        XCTAssertNil(e.app)
        XCTAssertNil(e.window)
        XCTAssertNil(e.pid)
    }

    func testUnknownFieldsAreIgnored() throws {
        let e = try XCTUnwrap(Event.parse(#"{"v":1,"agent":"a","status":"start","text":"Go","color":"red","nested":{"k":1}}"#))
        XCTAssertEqual(e.status, .start)
    }

    func testLongTextIsCutTo120Characters() throws {
        let long = String(repeating: "é", count: 300)
        let e = try XCTUnwrap(Event.parse(#"{"v":1,"agent":"a","status":"step","text":"\#(long)"}"#))
        XCTAssertEqual(e.text.count, 120)
    }

    func testTextNewlinesBecomeSpaces() throws {
        let e = try XCTUnwrap(Event.parse(#"{"v":1,"agent":"a","status":"step","text":"one\ntwo"}"#))
        XCTAssertEqual(e.text, "one two")
    }

    func testMissingTextDefaultsToEmpty() throws {
        let e = try XCTUnwrap(Event.parse(#"{"v":1,"agent":"a","status":"end"}"#))
        XCTAssertEqual(e.text, "")
    }

    func testGarbageIsDropped() {
        XCTAssertNil(Event.parse("not json"))
        XCTAssertNil(Event.parse(""))
        XCTAssertNil(Event.parse("[1,2,3]"))
    }

    func testWrongVersionIsDropped() {
        XCTAssertNil(Event.parse(#"{"v":2,"agent":"a","status":"step","text":"x"}"#))
    }

    func testUnknownStatusIsDropped() {
        XCTAssertNil(Event.parse(#"{"v":1,"agent":"a","status":"dance","text":"x"}"#))
    }

    func testMissingAgentIsDropped() {
        XCTAssertNil(Event.parse(#"{"v":1,"status":"step","text":"x"}"#))
    }

    func testOversizeLineIsDropped() {
        let pad = String(repeating: "a", count: Event.maxLineBytes)
        XCTAssertNil(Event.parse(#"{"v":1,"agent":"a","status":"step","text":"x","pad":"\#(pad)"}"#))
    }
}
