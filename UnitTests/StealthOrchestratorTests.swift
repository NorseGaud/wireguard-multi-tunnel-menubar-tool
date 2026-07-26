import XCTest

final class MockStealthRunner: StealthProcessRunning {
    var started: [(String, [String])] = []
    var stopped: [Int32] = []
    var deadPids: Set<Int32> = []
    /// After this many `isAlive` calls, subsequent calls return false (nil = never).
    var failAliveAfterCall: Int?
    private(set) var aliveCallCount = 0
    private var nextPid: Int32 = 1000

    func start(executable: String, arguments: [String]) throws -> Int32 {
        started.append((executable, arguments))
        nextPid += 1
        return nextPid
    }

    func stop(pid: Int32) {
        stopped.append(pid)
    }

    func isAlive(pid: Int32) -> Bool {
        aliveCallCount += 1
        if let threshold = failAliveAfterCall, aliveCallCount > threshold {
            return false
        }
        return !deadPids.contains(pid)
    }
}

enum StealthOrchestratorTestFixtures {
    static let sampleConfig = """
    [Interface]
    PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
    Address = 10.0.0.2/32
    [Peer]
    PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 0.0.0.0/0
    """

    static func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    static func writeConfig(in tmp: URL, name: String = "home.conf") throws -> URL {
        let configURL = tmp.appendingPathComponent(name)
        try sampleConfig.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    static func stackedProfile() -> StealthProfile {
        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.9"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "pw"
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        return profile
    }

    static func stackedPaths() -> StealthToolPaths {
        StealthToolPaths(
            awgQuick: nil,
            amneziaGo: nil,
            udp2raw: "/usr/local/bin/udp2raw",
            wstunnel: "/usr/local/bin/wstunnel"
        )
    }

    static func makeOrchestrator(
        runner: StealthProcessRunning,
        runDirectory: String,
        toolPaths: StealthToolPaths? = nil,
        readinessTimeout: TimeInterval = 0.2,
        pollInterval: TimeInterval = 0.01,
        isPortReady: @escaping (UInt16) -> Bool = { _ in true }
    ) -> StealthOrchestrator {
        StealthOrchestrator(
            runner: runner,
            toolPaths: toolPaths ?? stackedPaths(),
            runDirectory: runDirectory,
            brewPrefix: "/opt/homebrew",
            readinessTimeout: readinessTimeout,
            pollInterval: pollInterval,
            isPortReady: isPortReady
        )
    }
}

class StealthOrchestratorTests: XCTestCase {
    func testStartsOuterThenInnerThenTunnel() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let runDir = tmp.appendingPathComponent("run")

        var wgCalls: [String] = []
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: runDir.path
        )
        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { path in
                wgCalls.append(path)
                return (true, "")
            }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(runner.started.map(\.0), ["/usr/local/bin/wstunnel", "/usr/local/bin/udp2raw"])
        XCTAssertEqual(wgCalls.count, 1)

        let stateText = try String(contentsOf: runDir.appendingPathComponent("home.json"), encoding: .utf8)
        XCTAssertFalse(stateText.contains("pw"))
        XCTAssertFalse(stateText.lowercased().contains("password"))
    }

    func testStackedUdp2rawRemotePointsAtLocalWstunnelPort() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: tmp.appendingPathComponent("run").path
        )

        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in (true, "") }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(runner.started.count, 2)

        let wstunnelArgs = runner.started[0].1
        let listenFlag = wstunnelArgs.first { $0.hasPrefix("udp://127.0.0.1:") }
        XCTAssertNotNil(listenFlag)
        let wstunnelPort = try XCTUnwrap(listenFlag?.split(separator: ":")[2])
        XCTAssertFalse(wstunnelPort.isEmpty)

        let udp2rawArgs = runner.started[1].1
        guard let remoteIdx = udp2rawArgs.firstIndex(of: "-r"),
              udp2rawArgs.index(after: remoteIdx) < udp2rawArgs.endIndex else {
            return XCTFail("udp2raw missing -r")
        }
        XCTAssertEqual(udp2rawArgs[udp2rawArgs.index(after: remoteIdx)], "127.0.0.1:\(wstunnelPort)")
    }

    func testRollbackStopsWrappersInReverseStartOrderOnWgFailure() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        var downCalled = false
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: tmp.appendingPathComponent("run").path
        )

        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in (false, "boom") },
            runWgQuickDown: {
                downCalled = true
                return (true, "")
            }
        )
        XCTAssertFalse(succeeded)
        XCTAssertTrue(downCalled)
        // Start: wstunnel(1001), udp2raw(1002). Reverse stop: udp2raw then wstunnel.
        XCTAssertEqual(runner.stopped, [1002, 1001])
    }

    func testRollbackDeletesStateAndEphemeralFiles() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let runDir = tmp.appendingPathComponent("run")
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: runDir.path
        )

        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in (false, "boom") },
            runWgQuickDown: { (true, "") }
        )
        XCTAssertFalse(succeeded)

        let alias = WireGuard.wgQuickInterfaceName(for: "home")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("home.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("\(alias).conf").path))
    }

    func testBringDownStopsWgThenUdp2rawThenWstunnel() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let runDir = tmp.appendingPathComponent("run")
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: runDir.path
        )

        let (upOk, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in (true, "") }
        )
        XCTAssertTrue(upOk)

        var sequence: [String] = []
        let (downOk, _) = orch.bringDown(tunnelName: "home", runWgQuickDown: {
            sequence.append("wg-down")
            return (true, "")
        })
        XCTAssertTrue(downOk)
        for pid in runner.stopped {
            sequence.append("stop:\(pid)")
        }
        XCTAssertEqual(sequence, ["wg-down", "stop:1002", "stop:1001"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("home.json").path))
    }

    func testBringUpCleansStaleStateBeforeStarting() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let runDir = tmp.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let alias = WireGuard.wgQuickInterfaceName(for: "home")
        let staleState = StealthOrchestrator.TunnelState(
            tunnelName: "home",
            aliasName: alias,
            wstunnelPid: 42,
            udp2rawPid: 43,
            wstunnelLocalPort: 1111,
            udp2rawLocalPort: 2222,
            wgLocalPort: 2222
        )
        try JSONEncoder().encode(staleState).write(to: runDir.appendingPathComponent("home.json"))
        try "stale".write(
            to: runDir.appendingPathComponent("\(alias).conf"),
            atomically: true,
            encoding: .utf8
        )

        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: runDir.path
        )
        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in (true, "") }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(Array(runner.stopped.prefix(2)), [43, 42])
        XCTAssertEqual(runner.started.map(\.0), ["/usr/local/bin/wstunnel", "/usr/local/bin/udp2raw"])
    }

    func testFailsWhenWrapperDiesBeforeWgQuick() throws {
        let runner = MockStealthRunner()
        // Two wrappers each get one successful readiness alive-check, then pre-wg checks fail.
        runner.failAliveAfterCall = 2
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: tmp.appendingPathComponent("run").path
        )

        var wgCalled = false
        let (succeeded, message) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: StealthOrchestratorTestFixtures.stackedProfile(),
            useAmnezia: false,
            runWgQuick: { _ in
                wgCalled = true
                return (true, "")
            }
        )
        XCTAssertFalse(succeeded)
        XCTAssertFalse(wgCalled)
        let lower = message.lowercased()
        XCTAssertTrue(
            lower.contains("alive") || lower.contains("ready")
                || lower.contains("exited") || lower.contains("wrapper")
        )
    }

    func testRollbackStopsStartedWrappersWhenTunnelFails() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        var downCalled = false
        let orch = StealthOrchestratorTestFixtures.makeOrchestrator(
            runner: runner,
            runDirectory: tmp.appendingPathComponent("run").path,
            toolPaths: StealthToolPaths(
                awgQuick: nil,
                amneziaGo: nil,
                udp2raw: nil,
                wstunnel: "/usr/local/bin/wstunnel"
            )
        )
        let (succeeded, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: profile,
            useAmnezia: false,
            runWgQuick: { _ in (false, "boom") },
            runWgQuickDown: {
                downCalled = true
                return (true, "")
            }
        )
        XCTAssertFalse(succeeded)
        XCTAssertTrue(downCalled)
        XCTAssertEqual(runner.stopped.count, 1)
    }
}
