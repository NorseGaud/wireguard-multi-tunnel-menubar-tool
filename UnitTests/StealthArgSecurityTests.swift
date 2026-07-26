import XCTest

class StealthArgSecurityTests: XCTestCase {
    func testAcceptsSimpleFlags() throws {
        try StealthArgSecurity.validateExtraArgs(["--foo", "bar", "-v"])
    }

    func testRejectsShellMetacharacters() {
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs([";rm"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs(["$(id)"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs(["a|b"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs([""]))
    }
}
