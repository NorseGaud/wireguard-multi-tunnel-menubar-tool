import XCTest

final class FakeLoginItemService: LoginItemControlling {
    var isAvailable = true
    var isEnabled = false
    var setEnabledError: Error?
    var lastSetEnabled: Bool?

    func setEnabled(_ enabled: Bool) throws {
        lastSetEnabled = enabled
        if let setEnabledError {
            throw setEnabledError
        }
        isEnabled = enabled
    }
}

class LoginItemServiceTests: XCTestCase {
    func testSyncEnablesCheckboxFromService() {
        let fake = FakeLoginItemService()
        fake.isEnabled = true
        let prefs = Preferences(loginItemService: fake)
        prefs.loadWindowIfNeeded()
        prefs.syncLaunchAtLoginCheckbox()
        XCTAssertEqual(prefs.launchAtLoginCheckbox.state, .on)
        XCTAssertTrue(prefs.launchAtLoginCheckbox.isEnabled)
    }

    func testSyncDisablesCheckboxWhenUnavailable() {
        let fake = FakeLoginItemService()
        fake.isAvailable = false
        let prefs = Preferences(loginItemService: fake)
        prefs.loadWindowIfNeeded()
        prefs.syncLaunchAtLoginCheckbox()
        XCTAssertFalse(prefs.launchAtLoginCheckbox.isEnabled)
        XCTAssertEqual(prefs.launchAtLoginCheckbox.state, .off)
    }

    func testToggleCallsService() {
        let fake = FakeLoginItemService()
        let prefs = Preferences(loginItemService: fake)
        prefs.loadWindowIfNeeded()
        prefs.launchAtLoginCheckbox.state = .on
        prefs.launchAtLoginChanged(prefs.launchAtLoginCheckbox)
        XCTAssertEqual(fake.lastSetEnabled, true)
        XCTAssertTrue(fake.isEnabled)
    }

    func testLoginItemServiceAvailabilityMatchesOS() {
        let service = LoginItemService()
        if #available(macOS 13.0, *) {
            XCTAssertTrue(service.isAvailable)
        } else {
            XCTAssertFalse(service.isAvailable)
        }
    }
}

private extension Preferences {
    func loadWindowIfNeeded() {
        _ = window
    }
}
