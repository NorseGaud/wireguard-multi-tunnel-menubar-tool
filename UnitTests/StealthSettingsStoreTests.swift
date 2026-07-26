import XCTest

class StealthSettingsStoreTests: XCTestCase {
    func testSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StealthSettingsStore(directoryURL: dir)
        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        try store.save(profile: profile, for: "home")
        XCTAssertEqual(store.profile(for: "home").wstunnel.serverURL, "wss://example.com/ws")
        XCTAssertFalse(store.profile(for: "other").hasAnyLayerEnabled)
    }
}
