// Application unit tests

import XCTest

class AppTests: XCTestCase {
    let testTunnels: [Tunnel] = [
        Tunnel(
            name: "1 Tunnel Name",
            config: TunnelConfig(
                address: "192.0.2.0/32",
                peers: [Peer(
                    endpoint: "192.0.2.1/32:51820",
                    allowedIps: ["198.51.100.0/24"]
                )]
            )
        ),
        Tunnel(name: "2 Invalid Config", config: nil),
    ]

    /// menu image should properly represent state of tunnels
    func testMenuImage() {
        var tunnels = testTunnels

        XCTAssertEqual(menuImage(tunnels: tunnels).name(), "dragon")
        tunnels[0].interface = "utun1"
        let connectedIcon = menuImage(tunnels: tunnels)
        XCTAssertFalse(connectedIcon.isTemplate)
        XCTAssertGreaterThan(connectedIcon.size.width, 0)
    }

    func testMenu() {
        let items = buildMenu(tunnels: testTunnels)
        XCTAssertEqual(items[0].title, "1 Tunnel Name")
        XCTAssertNotNil(items[0].view)
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertEqual(switchTitles(in: items, after: 0), ["Enabled", "Amnezia", "udp2raw", "wstunnel"])
    }

    func testMenuEnabledTunnel() {
        var tunnels = testTunnels
        tunnels[0].interface = "utun1"

        let items = buildMenu(tunnels: tunnels)
        XCTAssertEqual(items[0].title, "1 Tunnel Name")
        XCTAssertNotNil(items[0].view)
        XCTAssertEqual(switchTitles(in: items, after: 0), ["Enabled", "Amnezia", "udp2raw", "wstunnel"])
        XCTAssertEqual(items[5].title, "Interface: utun1")
        XCTAssertEqual(items[6].title, "Address: 192.0.2.0/32")
        XCTAssertEqual(items[7].title, "Endpoint: 192.0.2.1/32:51820")
        XCTAssertEqual(items[8].title, "Allowed IPs: 198.51.100.0/24")
    }

    func testMenuEnabledTunnelNoDetails() {
        var tunnels = testTunnels
        tunnels[0].interface = "utun1"

        var opts = MenuBuildOptions()
        opts.connectedTunnelDetails = false
        let items = buildMenu(tunnels: tunnels, options: opts)
        // first tunnel: name + 4 switches; second tunnel starts next
        XCTAssertEqual(items[5].title, "2 Invalid Config")
    }

    func testMenuDetails() {
        var tunnels = testTunnels
        tunnels[0].interface = "utun1"

        var opts = MenuBuildOptions()
        opts.allTunnelDetails = true
        let items = buildMenu(tunnels: tunnels, options: opts)
        XCTAssertEqual(items[0].title, "1 Tunnel Name")
        XCTAssertNotNil(items[0].view)
        XCTAssertEqual(items[5].title, "Interface: utun1")
        XCTAssertEqual(items[5].indentationLevel, 1)
        XCTAssertEqual(items[6].title, "Address: 192.0.2.0/32")
        XCTAssertEqual(items[6].indentationLevel, 1)
        XCTAssertEqual(items[7].title, "Endpoint: 192.0.2.1/32:51820")
        XCTAssertEqual(items[7].indentationLevel, 1)
        XCTAssertEqual(items[8].title, "Allowed IPs: 198.51.100.0/24")
        XCTAssertEqual(items[8].indentationLevel, 1)
    }

    func testMenuDetailsInvalidConfig() {
        var tunnels = testTunnels
        tunnels[1].interface = "utun1"

        var opts = MenuBuildOptions()
        opts.allTunnelDetails = true
        let items = buildMenu(tunnels: tunnels, options: opts)
        // tunnel 1 (disconnected): name + 4 switches + 3 config details = 8; then tunnel 2
        let offset = 8
        XCTAssertEqual(items[0 + offset].title, "2 Invalid Config")
        XCTAssertNotNil(items[0 + offset].view)
        XCTAssertEqual(items[5 + offset].title, "Interface: utun1")
        XCTAssertEqual(items[6 + offset].title, "Could not parse tunnel configuration!")
    }

    func testMenuNoTunnels() {
        let items = buildMenu(tunnels: Tunnels())
        XCTAssertEqual(items[0].title, "No tunnel configurations found")
    }

    func testMenuPendingTunnel() {
        var opts = MenuBuildOptions()
        opts.pendingTunnels = ["1 Tunnel Name": true]
        let items = buildMenu(tunnels: testTunnels, options: opts)
        XCTAssertEqual(items[0].title, "1 Tunnel Name")
        XCTAssertNotNil(items[0].view)
        // Name rows stay enabled so AppKit does not dim custom-view labels.
        XCTAssertTrue(items[0].isEnabled)
    }

    func testResolvePendingTunnelOperations() {
        var pending: PendingTunnelOperations = ["1 Tunnel Name": true]
        var tunnels = testTunnels
        resolvePendingTunnelOperations(&pending, tunnels: tunnels)
        XCTAssertEqual(pending.count, 1)

        tunnels[0].interface = "utun1"
        resolvePendingTunnelOperations(&pending, tunnels: tunnels)
        XCTAssertTrue(pending.isEmpty)
    }

    func testMenuSorting() {
        let tunnels: [Tunnel] = [
            Tunnel(name: "Z Tunnel Name"),
            Tunnel(name: "A Tunnel Name"),
        ]
        let items = buildMenu(tunnels: tunnels)
        XCTAssertEqual(items[0].title, "A Tunnel Name")
    }

    func testConfigParsing() {
        for (name, config) in testConfigs {
            print("Testing config \(name)")
            if let config = TunnelConfig(fromConfig: config) {
                XCTAssertEqual(config.address, "192.0.2.0/32")
                XCTAssertEqual(config.peers[0].endpoint, "192.0.2.1/32:51820")
                XCTAssertEqual(config.peers[0].allowedIps, ["198.51.100.0/24"])
            } else {
                XCTFail("Config \(name) could not be parsed")
            }
        }
    }

    private func switchTitles(in items: [NSMenuItem], after nameIndex: Int) -> [String] {
        (1 ... 4).map { items[nameIndex + $0].title }
    }
}
