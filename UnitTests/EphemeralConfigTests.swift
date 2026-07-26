import XCTest

class EphemeralConfigTests: XCTestCase {
    let base = """
    [Interface]
    PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
    Address = 10.0.0.2/32

    [Peer]
    PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 0.0.0.0/0
    """

    func testRewritesEndpointWhenWrapperEnabled() throws {
        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.9"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "x"
        let out = try EphemeralConfig.rewrite(configText: base, profile: profile, localEndpoint: "127.0.0.1:51821")
        XCTAssertTrue(out.contains("Endpoint = 127.0.0.1:51821"))
        XCTAssertFalse(out.contains("203.0.113.9:51820"))
    }

    func testInjectsAmneziaKeys() throws {
        var profile = StealthProfile()
        profile.amnezia.enabled = true
        profile.amnezia.jc = 3
        let out = try EphemeralConfig.rewrite(configText: base, profile: profile, localEndpoint: nil)
        XCTAssertTrue(out.contains("Jc = 3"))
        XCTAssertTrue(out.contains("Endpoint = 203.0.113.9:51820"))
    }
}
