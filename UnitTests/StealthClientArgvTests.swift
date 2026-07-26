import XCTest

class StealthClientArgvTests: XCTestCase {
    func testWstunnelArgvTlsVerifyCertificateSemantics() throws {
        let runner = MockStealthRunner()
        let tmp = try StealthOrchestratorTestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = try StealthOrchestratorTestFixtures.writeConfig(in: tmp)
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

        var verifyProfile = StealthProfile()
        verifyProfile.wstunnel.enabled = true
        verifyProfile.wstunnel.serverURL = "wss://example.com/ws"
        verifyProfile.wstunnel.tlsSkipVerify = false
        XCTAssertTrue(orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: verifyProfile,
            useAmnezia: false,
            runWgQuick: { _ in (true, "") }
        ).0)
        XCTAssertTrue(runner.started[0].1.contains("--tls-verify-certificate"))
        XCTAssertFalse(runner.started[0].1.contains("--tls-skip-verify"))

        _ = orch.bringDown(tunnelName: "home", runWgQuickDown: { (true, "") })
        runner.started.removeAll()

        var skipProfile = verifyProfile
        skipProfile.wstunnel.tlsSkipVerify = true
        XCTAssertTrue(orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: skipProfile,
            useAmnezia: false,
            runWgQuick: { _ in (true, "") }
        ).0)
        XCTAssertFalse(runner.started[0].1.contains("--tls-verify-certificate"))
        XCTAssertFalse(runner.started[0].1.contains("--tls-skip-verify"))
    }

    func testWstunnelAndUdp2rawArgvShapes() {
        var wsSettings = WsTunnelSettings()
        wsSettings.serverURL = "wss://example.com/ws"
        wsSettings.tlsSkipVerify = false
        let verifyArgs = StealthClientArgv.wstunnel(
            localPort: 1234,
            exitHost: "203.0.113.9",
            exitPort: 51820,
            profile: wsSettings
        )
        XCTAssertEqual(verifyArgs.first, "client")
        XCTAssertEqual(verifyArgs[1], "-L")
        XCTAssertEqual(verifyArgs[2], "udp://127.0.0.1:1234:203.0.113.9:51820")
        XCTAssertTrue(verifyArgs.contains("--tls-verify-certificate"))
        XCTAssertEqual(verifyArgs.last, "wss://example.com/ws")

        wsSettings.tlsSkipVerify = true
        let skipArgs = StealthClientArgv.wstunnel(
            localPort: 1234,
            exitHost: "203.0.113.9",
            exitPort: 51820,
            profile: wsSettings
        )
        XCTAssertFalse(skipArgs.contains("--tls-verify-certificate"))

        var udpSettings = Udp2RawSettings()
        udpSettings.password = "pw"
        udpSettings.rawMode = .faketcp
        let udpArgs = StealthClientArgv.udp2raw(
            localPort: 2345,
            remoteHost: "127.0.0.1",
            remotePort: 1234,
            profile: udpSettings
        )
        XCTAssertEqual(
            udpArgs,
            ["-c", "-l", "127.0.0.1:2345", "-r", "127.0.0.1:1234", "-k", "pw", "--raw-mode", "faketcp"]
        )
    }
}
