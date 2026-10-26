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

    /// Lines of the upstream Darwin wg-quick that `WireGuard.wgQuickScriptEdits` anchor on
    let upstreamWgQuickExcerpt = """
    \t[[ ${#DNS[@]} -gt 0 ]] && trap set_dns ALRM
    \twhile read -u 19 -r event; do
    \t\t[[ $event == RTM_* ]] || continue
    \t\tifconfig "$REAL_INTERFACE" >/dev/null 2>&1 || break
    \t\tif [[ ${#DNS[@]} -gt 0 ]]; then
    \t\t\tset_dns
    \t\t\tsleep 2 && kill -ALRM $bpid 2>/dev/null &
    \t\tfi
    \tdone
    # ~~ function override insertion point ~~

    """

    func testPatchWgQuickScriptAppliesEveryEdit() throws {
        let patched = try XCTUnwrap(WireGuard.patchWgQuickScript(upstreamWgQuickExcerpt))
        XCTAssertEqual(patched, """
        \t[[ ${#DNS[@]} -gt 0 ]] && trap 'dns_alarm_pending=0; set_dns' ALRM
        \twhile read -u 19 -r event; do
        \t\t[[ $event == RTM_* ]] || continue; [[ $event == RTM_MISS* ]] && continue
        \t\tifconfig "$REAL_INTERFACE" >/dev/null 2>&1 || break
        \t\tif [[ ${#DNS[@]} -gt 0 ]]; then
        \t\t\tif [[ $dns_alarm_pending != 1 ]]; then
        \t\t\t\tdns_alarm_pending=1
        \t\t\t\tsleep 2 && kill -ALRM $bpid 2>/dev/null &
        \t\t\tfi
        \t\tfi
        \tdone
        # ~~ function override insertion point ~~

        \(WireGuard.wgQuickSetDnsWhenChanged)


        """)
    }

    func testPatchWgQuickScriptSkipsScriptsMissingAnAnchor() {
        XCTAssertNil(WireGuard.patchWgQuickScript("#!/bin/sh\nexit 0\n"))
        let withoutInsertionPoint = upstreamWgQuickExcerpt
            .replacingOccurrences(of: WireGuard.wgQuickOverrideInsertionPoint, with: "")
        XCTAssertNil(WireGuard.patchWgQuickScript(withoutInsertionPoint))
    }

    func testPatchWgQuickScriptSkipsAlreadyPatchedScripts() throws {
        let patched = try XCTUnwrap(WireGuard.patchWgQuickScript(upstreamWgQuickExcerpt))
        XCTAssertNil(WireGuard.patchWgQuickScript(patched))
    }

    func testGetConfigDirectory() {
        let expectation = XCTestExpectation(description: "config directory")
        Helper().getConfigDirectory { path in
            XCTAssertTrue(path.hasPrefix("/"))
            XCTAssertTrue(path.hasSuffix("/etc/wireguard"))
            XCTAssertFalse(path.contains(".."))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
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

    /// wg-quick stderr may echo config contents; replies must be censored
    func testWgQuickErrorMessageIsCensored() {
        let leaked = """
        [#] wg-quick up failed
        PrivateKey = \(testPrivateKey)
        PresharedKey = \(testPrivateKey)
        """
        let censored = WireGuard.censorConfigurationData(leaked)
        XCTAssertFalse(censored.contains(testPrivateKey))
        XCTAssertTrue(censored.contains("PrivateKey = ***"))
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
}
