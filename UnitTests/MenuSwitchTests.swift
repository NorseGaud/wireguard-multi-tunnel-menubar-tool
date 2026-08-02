import XCTest

class MenuSwitchTests: XCTestCase {
    private let testTunnels: [Tunnel] = [
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

    func testSwitchViewSetOnRevertsLabelAppearance() {
        let view = TunnelSwitchMenuItemView(
            title: "Enabled",
            isOn: false,
            tunnelName: "home",
            controlKind: "enabled",
            menuWidth: 200,
            target: nil,
            action: nil
        )
        view.setSwitchOn(true)
        XCTAssertEqual(view.menuSwitch.state, .on)
        XCTAssertTrue(view.isOnAppearance)

        view.setSwitchOn(false)
        XCTAssertEqual(view.menuSwitch.state, .off)
        XCTAssertFalse(view.isOnAppearance)
    }

    func testSyncOpenMenuDisablesSwitchesWhilePending() {
        var opts = MenuBuildOptions()
        opts.menuItemWidth = 200
        let items = buildMenu(tunnels: testTunnels, options: opts)
        let menu = NSMenu()
        for item in items {
            menu.addItem(item)
        }

        syncOpenMenuTunnelAppearance(
            in: menu,
            tunnelName: "1 Tunnel Name",
            connected: false,
            pendingTarget: true
        )

        let enabled = switchView(in: menu, tunnelName: "1 Tunnel Name", kind: "enabled")
        XCTAssertFalse(enabled.menuSwitch.isEnabled)
        XCTAssertEqual(enabled.menuSwitch.state, .on)
    }

    func testShouldRebuildStatusMenu() {
        XCTAssertTrue(shouldRebuildStatusMenu(isStatusItemHighlighted: false))
        XCTAssertTrue(shouldRebuildStatusMenu(isStatusItemHighlighted: nil))
        XCTAssertFalse(shouldRebuildStatusMenu(isStatusItemHighlighted: true))
    }

    private func switchView(in menu: NSMenu, tunnelName: String, kind: String) -> TunnelSwitchMenuItemView {
        for item in menu.items {
            if let view = item.view as? TunnelSwitchMenuItemView,
               view.menuSwitch.tunnelName == tunnelName,
               view.menuSwitch.controlKind == kind {
                return view
            }
        }
        XCTFail("Missing switch \(kind) for \(tunnelName)")
        return TunnelSwitchMenuItemView(
            title: kind,
            isOn: false,
            tunnelName: tunnelName,
            controlKind: kind,
            menuWidth: 200,
            target: nil,
            action: nil
        )
    }
}
