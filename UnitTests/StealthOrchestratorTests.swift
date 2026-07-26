import XCTest

final class MockStealthRunner: StealthProcessRunning {
    var started: [(String, [String])] = []
    var stopped: [Int32] = []
    private var nextPid: Int32 = 1000

    func start(executable: String, arguments: [String]) throws -> Int32 {
        started.append((executable, arguments))
        nextPid += 1
        return nextPid
    }

    func stop(pid: Int32) {
        stopped.append(pid)
    }
}

class StealthOrchestratorTests: XCTestCase {
    func testStartsOuterThenInnerThenTunnel() throws {
        let runner = MockStealthRunner()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configURL = tmp.appendingPathComponent("home.conf")
        try """
        [Interface]
        PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
        Endpoint = 203.0.113.9:51820
        AllowedIPs = 0.0.0.0/0
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.9"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "pw"
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"

        let paths = StealthToolPaths(
            awgQuick: nil,
            amneziaGo: nil,
            udp2raw: "/usr/local/bin/udp2raw",
            wstunnel: "/usr/local/bin/wstunnel"
        )
        var wgCalls: [String] = []
        let orch = StealthOrchestrator(
            runner: runner,
            toolPaths: paths,
            runDirectory: tmp.appendingPathComponent("run").path,
            brewPrefix: "/opt/homebrew"
        )
        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: profile,
            useAmnezia: false,
            runWgQuick: { path in
                wgCalls.append(path)
                return (true, "")
            }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(runner.started.map(\.0), ["/usr/local/bin/wstunnel", "/usr/local/bin/udp2raw"])
        XCTAssertEqual(wgCalls.count, 1)

        // State file must not contain passwords
        let stateURL = tmp.appendingPathComponent("run").appendingPathComponent("home.json")
        let stateText = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(stateText.contains("pw"))
        XCTAssertFalse(stateText.lowercased().contains("password"))
    }

    func testRollbackStopsStartedWrappersWhenTunnelFails() throws {
        let runner = MockStealthRunner()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("home.conf")
        try """
        [Interface]
        PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
        Endpoint = 203.0.113.9:51820
        AllowedIPs = 0.0.0.0/0
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        let paths = StealthToolPaths(awgQuick: nil, amneziaGo: nil, udp2raw: nil, wstunnel: "/usr/local/bin/wstunnel")
        let orch = StealthOrchestrator(
            runner: runner,
            toolPaths: paths,
            runDirectory: tmp.appendingPathComponent("run").path,
            brewPrefix: "/opt/homebrew"
        )
        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: profile,
            useAmnezia: false,
            runWgQuick: { _ in (false, "boom") }
        )
        XCTAssertFalse(succeeded)
        XCTAssertEqual(runner.stopped.count, 1)
    }
}
