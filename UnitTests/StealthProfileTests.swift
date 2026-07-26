import XCTest

class StealthProfileTests: XCTestCase {
    func testEmptyProfileHasNoLayers() {
        let profile = StealthProfile()
        XCTAssertFalse(profile.hasAnyLayerEnabled)
        XCTAssertNoThrow(try profile.validate())
    }

    func testUdp2RawRequiresRemoteFields() {
        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        XCTAssertThrowsError(try profile.validate())
    }

    func testValidStackedProfileRoundTripsJSON() throws {
        var profile = StealthProfile()
        profile.amnezia.enabled = true
        profile.amnezia.jc = 4
        profile.amnezia.jmin = 40
        profile.amnezia.jmax = 70
        profile.amnezia.s1 = 0
        profile.amnezia.s2 = 0
        profile.amnezia.h1 = 1
        profile.amnezia.h2 = 2
        profile.amnezia.h3 = 3
        profile.amnezia.h4 = 4
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.1"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "secret"
        profile.udp2raw.rawMode = .faketcp
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        let json = try profile.jsonString()
        let parsed = try StealthProfile.parse(jsonString: json)
        XCTAssertEqual(parsed, profile)
    }

    func testWsTunnelRequiresURL() {
        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        XCTAssertThrowsError(try profile.validate())
    }

    func testRejectsNonEmptyExtraArgsInV1() {
        var udpProfile = StealthProfile()
        udpProfile.udp2raw.extraArgs = ["--foo"]
        XCTAssertThrowsError(try udpProfile.validate()) { error in
            XCTAssertEqual(error as? StealthValidationError, .extraArgsNotSupported)
        }

        var wsProfile = StealthProfile()
        wsProfile.wstunnel.extraArgs = ["--bar"]
        XCTAssertThrowsError(try wsProfile.validate()) { error in
            XCTAssertEqual(error as? StealthValidationError, .extraArgsNotSupported)
        }
    }
}
