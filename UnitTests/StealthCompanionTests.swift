import XCTest

class StealthCompanionTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let confPath = dir.appendingPathComponent("home.conf").path
        try "[Interface]\n".write(toFile: confPath, atomically: true, encoding: .utf8)

        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        try StealthCompanion.save(profile: profile, tunnelName: "home", configFilePath: confPath)

        let loaded = StealthCompanion.load(tunnelName: "home", configFilePath: confPath)
        XCTAssertEqual(loaded.wstunnel.serverURL, "wss://example.com/ws")
        XCTAssertTrue(loaded.wstunnel.enabled)

        let expectedPath = dir.appendingPathComponent("home.stealth.json").path
        XCTAssertEqual(StealthCompanion.filePath(for: "home", configFilePath: confPath), expectedPath)
    }

    func testMissingCompanionReturnsEmptyProfile() {
        let confPath = "/tmp/does-not-exist-\(UUID().uuidString).conf"
        let loaded = StealthCompanion.load(tunnelName: "x", configFilePath: confPath)
        XCTAssertFalse(loaded.hasAnyLayerEnabled)
    }
}
