import XCTest
@testable import OpenPiPCore

final class DenyListTests: XCTestCase {
    func testPasswordManagersAreDenied() {
        XCTAssertTrue(DenyList.default.isDenied(bundleID: "com.1password.1password"))
        XCTAssertTrue(DenyList.default.isDenied(bundleID: "com.apple.keychainaccess"))
        XCTAssertTrue(DenyList.default.isDenied(bundleID: "com.apple.Passwords"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(DenyList.default.isDenied(bundleID: "COM.APPLE.KEYCHAINACCESS"))
    }

    func testNormalAppsAreAllowed() {
        XCTAssertFalse(DenyList.default.isDenied(bundleID: "com.apple.Notes"))
        XCTAssertFalse(DenyList.default.isDenied(bundleID: nil))
    }

    func testExtraEntriesAreAdded() {
        let list = DenyList(extra: ["com.example.secret"])
        XCTAssertTrue(list.isDenied(bundleID: "com.example.secret"))
        XCTAssertTrue(list.isDenied(bundleID: "com.1password.1password"))
    }
}
