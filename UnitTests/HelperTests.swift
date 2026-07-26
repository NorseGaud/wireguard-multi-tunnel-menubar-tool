// Helper unit tests

import XCTest

class HelperTests: XCTestCase {
    // test wg-quick is called and returns 1 as exitcode since it cannot sudo
    // TODO: mock out something or ditch test
//    func testSetTunnel() {
//        Helper().setTunnel(tunnelName: "test", enable: true, reply: { exitCode in
//            XCTAssertEqual(exitCode, 1)
//        })
//        Helper().setTunnel(tunnelName: "test", enable: false, reply: { exitCode in
//            XCTAssertEqual(exitCode, 1)
//        })
//    }

    /// invalid tunnel names should not be accepted
    func testTunnelNames() {
        XCTAssertTrue(WireGuard.validateTunnelName(tunnelName: "test"))
        XCTAssertTrue(WireGuard.validateTunnelName(tunnelName: "WireGuard-nathan"))
        XCTAssertFalse(WireGuard.validateTunnelName(tunnelName: ""))
        XCTAssertFalse(WireGuard.validateTunnelName(tunnelName: ";rm -rf *"))
    }

    func testWgQuickInterfaceNameUsesShortNamesDirectly() {
        XCTAssertEqual(WireGuard.wgQuickInterfaceName(for: "test"), "test")
        XCTAssertEqual(WireGuard.wgQuickInterfaceName(for: "WireGuard-nat"), "WireGuard-nat")
    }

    func testWgQuickInterfaceNameMapsLongNames() {
        let alias = WireGuard.wgQuickInterfaceName(for: "WireGuard-nathan")
        XCTAssertTrue(WireGuard.isWgQuickInterfaceName(alias))
        XCTAssertNotEqual(alias, "WireGuard-nathan")
        XCTAssertEqual(alias, WireGuard.wgQuickInterfaceName(for: "WireGuard-nathan"))
    }

    /// a version string should be returned
    func testGetVersion() {
        Helper().getVersion { version in
            XCTAssertNotEqual(version, "n/a")
        }
    }

    /// when reading configs don't expose the private keys over XPC
    func testDontExposePrivates() {
        for (name, config) in testConfigs {
            print("Testing config \(name)")
            let censoredConfigData = WireGuard.censorConfigurationData(config)
            XCTAssertFalse(censoredConfigData.contains(testPrivateKey))
        }
    }

    func testValidateDirectoryPathRejectsRelativePaths() {
        XCTAssertNil(PathSecurity.validateDirectoryPath("etc/wireguard"))
        XCTAssertNil(PathSecurity.validateDirectoryPath("/etc/../private/wireguard"))
    }

    func testValidateBinaryPathRequiresExpectedBasename() {
        XCTAssertNil(PathSecurity.validateBinaryPath("/bin/sh", expectedBasename: "wg-quick"))
    }

    func testValidateBinaryPathAcceptsExistingBinary() {
        XCTAssertEqual(PathSecurity.validateBinaryPath("/bin/sh", expectedBasename: "sh"), "/bin/sh")
    }

    func testStealthToolsStatusReturnsJSON() {
        let exp = expectation(description: "status")
        Helper().stealthToolsStatus { json in
            XCTAssertNotNil(try? JSONDecoder().decode(StealthToolsStatus.self, from: Data(json.utf8)))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testDisablePlanIgnoresInvalidAndIncompleteProfileJSON() throws {
        XCTAssertEqual(
            try StealthSetTunnelPlanner.plan(enable: false, stealthProfileJSON: "{not-json"),
            .down
        )
        let incomplete = #"{"schemaVersion":1,"udp2raw":{"enabled":true}}"#
        XCTAssertEqual(
            try StealthSetTunnelPlanner.plan(enable: false, stealthProfileJSON: incomplete),
            .down
        )
        XCTAssertEqual(
            try StealthSetTunnelPlanner.plan(enable: false, stealthProfileJSON: ""),
            .down
        )
    }

    func testEnablePlanRejectsInvalidProfileJSON() {
        XCTAssertThrowsError(
            try StealthSetTunnelPlanner.plan(enable: true, stealthProfileJSON: "{not-json")
        )
        let incomplete = #"{"schemaVersion":1,"udp2raw":{"enabled":true}}"#
        XCTAssertThrowsError(
            try StealthSetTunnelPlanner.plan(enable: true, stealthProfileJSON: incomplete)
        )
    }
}
