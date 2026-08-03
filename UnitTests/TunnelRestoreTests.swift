import XCTest

class TunnelRestoreTests: XCTestCase {
    var defaultsSuiteName: String!
    var defaults: UserDefaults!
    var store: TunnelRestoreStore!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "TunnelRestoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        store = TunnelRestoreStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    func testLoadEmptyByDefault() {
        XCTAssertEqual(store.load(), [])
    }

    func testSaveAndLoad() {
        store.save(["alpha", "beta"])
        XCTAssertEqual(store.load(), ["alpha", "beta"])
    }

    func testSaveOverwrites() {
        store.save(["alpha"])
        store.save([])
        XCTAssertEqual(store.load(), [])
    }

    func testSaveConnectedTunnels() {
        var tunnels: Tunnels = [
            Tunnel(name: "up", config: nil),
            Tunnel(name: "down", config: nil),
        ]
        tunnels[0].interface = "utun1"
        store.saveConnectedTunnels(tunnels)
        XCTAssertEqual(store.load(), ["up"])
    }

    func testPlanEnablesDownRememberedTunnels() {
        var tunnels: Tunnels = [
            Tunnel(name: "a", config: nil),
            Tunnel(name: "b", config: nil),
        ]
        tunnels[0].interface = "utun1"
        let plan = planTunnelRestore(storedNames: ["a", "b"], tunnels: tunnels)
        XCTAssertEqual(plan.namesToEnable, ["b"])
        XCTAssertEqual(plan.namesToDrop, [])
    }

    func testPlanDropsUnknownNames() {
        let tunnels: Tunnels = [Tunnel(name: "a", config: nil)]
        let plan = planTunnelRestore(storedNames: ["a", "gone"], tunnels: tunnels)
        XCTAssertEqual(plan.namesToEnable, ["a"])
        XCTAssertEqual(plan.namesToDrop, ["gone"])
    }

    func testPlanNoOpWhenAlreadyConnected() {
        var tunnels: Tunnels = [Tunnel(name: "a", config: nil)]
        tunnels[0].interface = "utun1"
        let plan = planTunnelRestore(storedNames: ["a"], tunnels: tunnels)
        XCTAssertEqual(plan.namesToEnable, [])
        XCTAssertEqual(plan.namesToDrop, [])
    }
}
