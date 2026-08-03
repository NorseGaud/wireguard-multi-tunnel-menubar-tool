# Login Start and Tunnel Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the app at login (Preferences toggle) and always restore the last connected tunnel set on every launch.

**Architecture:** Persist connected tunnel names in app `UserDefaults`. After the first `getTunnels` reply, bring up remembered tunnels that are down. Preferences uses `SMAppService.mainApp` (macOS 13+) for start at login; macOS 12 keeps the checkbox disabled.

**Tech Stack:** AppKit, `UserDefaults`, `ServiceManagement` (`SMAppService`), XCTest, existing helper XPC `setTunnel`.

## Global Constraints

- Deployment target remains macOS 12.0
- Restore is always on; no Preferences toggle for restore
- UserDefaults key: `lastConnectedTunnelNames` (`[String]`)
- Start at login has no UserDefaults mirror; live `SMAppService` status is source of truth on macOS 13+
- Reuse `setTunnelEnabled(_:enabling:)` and `notifyError` for bring-up failures
- ASD-STE100 for user-facing docs and alerts; do not apply to code identifiers
- Spec: `docs/superpowers/specs/2026-08-03-login-start-and-tunnel-restore-design.md`

## File structure

| File | Responsibility |
|---|---|
| `WireGuardMultiTunnel/TunnelRestore.swift` | `TunnelRestoreStore` + pure `planTunnelRestore` |
| `WireGuardMultiTunnel/LoginItemService.swift` | Login-item protocol + `SMAppService` wrapper |
| `UnitTests/TunnelRestoreTests.swift` | Store and planner unit tests |
| `UnitTests/LoginItemServiceTests.swift` | Fake-backed Preferences wiring tests (optional thin) |
| `WireGuardMultiTunnel/AppDelegate.swift` | Persist after restore; run restore once |
| `WireGuardMultiTunnel/PreferencesController.swift` | Start-at-login checkbox actions |
| `WireGuardMultiTunnel/PreferencesController.xib` | New checkbox + window height |
| `WireGuardMultiTunnel.xcodeproj/project.pbxproj` | Add new Swift files to App + UnitTests targets |
| `README.md` | Move features from Planned to Recently completed |

---

### Task 1: Tunnel restore store and planner

**Files:**
- Create: `WireGuardMultiTunnel/TunnelRestore.swift`
- Create: `UnitTests/TunnelRestoreTests.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Foundation.UserDefaults`, `Tunnel` / `Tunnels`
- Produces:
  - `enum TunnelRestoreKeys { static let lastConnectedTunnelNames = "lastConnectedTunnelNames" }`
  - `struct TunnelRestoreStore` with `init(defaults: UserDefaults = .standard)`, `func load() -> [String]`, `func save(_ names: [String])`, `func saveConnectedTunnels(_ tunnels: Tunnels)`
  - `struct TunnelRestorePlan { let namesToEnable: [String]; let namesToDrop: [String] }`
  - `func planTunnelRestore(storedNames: [String], tunnels: Tunnels) -> TunnelRestorePlan`

- [ ] **Step 1: Add files to the Xcode project**

Add `TunnelRestore.swift` under the `WireGuardMultiTunnel` group and compile it in both the app target and `UnitTests` (same pattern as `DisableAllMenu.swift`: one `PBXFileReference`, two `PBXBuildFile` entries, both Sources build phases).

Use IDs in the `A101000021CD90000001F6xx` range (or any unused hex IDs):

- FileRef: `A101000021CD90000001F601` → `TunnelRestore.swift`
- App Sources: `A101000021CD90000001F602`
- UnitTests Sources: `A101000021CD90000001F603`

Add `TunnelRestoreTests.swift` under `UnitTests` group, UnitTests target only:

- FileRef: `A101000021CD90000001F611`
- UnitTests Sources: `A101000021CD90000001F612`

- [ ] **Step 2: Write the failing tests**

Create `UnitTests/TunnelRestoreTests.swift`:

```swift
import XCTest

class TunnelRestoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: TunnelRestoreStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TunnelRestoreTests.\(UUID().uuidString)")
        store = TunnelRestoreStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.suiteName!)
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `rm -f .test-unit && make test-unit`

Expected: compile failure or test failure because `TunnelRestoreStore` / `planTunnelRestore` are missing.

- [ ] **Step 4: Implement store and planner**

Create `WireGuardMultiTunnel/TunnelRestore.swift`:

```swift
import Foundation

enum TunnelRestoreKeys {
    static let lastConnectedTunnelNames = "lastConnectedTunnelNames"
}

struct TunnelRestoreStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: TunnelRestoreKeys.lastConnectedTunnelNames) ?? []
    }

    func save(_ names: [String]) {
        defaults.set(names, forKey: TunnelRestoreKeys.lastConnectedTunnelNames)
    }

    func saveConnectedTunnels(_ tunnels: Tunnels) {
        save(tunnels.filter(\.connected).map(\.name))
    }
}

struct TunnelRestorePlan {
    let namesToEnable: [String]
    let namesToDrop: [String]
}

func planTunnelRestore(storedNames: [String], tunnels: Tunnels) -> TunnelRestorePlan {
    var namesToEnable: [String] = []
    var namesToDrop: [String] = []

    for name in storedNames {
        guard let tunnel = tunnels.first(where: { $0.name == name }) else {
            namesToDrop.append(name)
            continue
        }
        if !tunnel.connected {
            namesToEnable.append(name)
        }
    }

    return TunnelRestorePlan(namesToEnable: namesToEnable, namesToDrop: namesToDrop)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `rm -f .test-unit && make test-unit`

Expected: `TunnelRestoreTests` all pass.

- [ ] **Step 6: Commit**

```bash
git add WireGuardMultiTunnel/TunnelRestore.swift \
  UnitTests/TunnelRestoreTests.swift \
  WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add tunnel restore store and planner.

EOF
)"
```

---

### Task 2: Persist and restore in AppDelegate

**Files:**
- Modify: `WireGuardMultiTunnel/AppDelegate.swift`

**Interfaces:**
- Consumes: `TunnelRestoreStore`, `planTunnelRestore(storedNames:tunnels:)`, `setTunnelEnabled(_:enabling:)`
- Produces: launch restore once; persist connected names only after restore has run

**Critical ordering:** Do not save connected names from the first `getTunnels` reply before restore runs. That reply is often all-down and would wipe the stored list.

- [ ] **Step 1: Add restore state on AppDelegate**

Near other instance properties in `AppDelegate.swift`:

```swift
let tunnelRestoreStore = TunnelRestoreStore()
private var didRunLaunchTunnelRestore = false
```

- [ ] **Step 2: Persist only after restore has run**

Change `applyTunnelStateUpdate()` to:

```swift
func applyTunnelStateUpdate() {
    resolvePendingTunnelOperations(&pendingTunnelOperations, tunnels: tunnels)
    refreshStatusBarAppearance()
    syncOpenMenuForAllTunnels()
    rebuildStatusMenuIfAllowed()

    if !didRunLaunchTunnelRestore {
        didRunLaunchTunnelRestore = true
        restoreLastConnectedTunnels()
    } else {
        tunnelRestoreStore.saveConnectedTunnels(tunnels)
    }
}
```

- [ ] **Step 3: Implement restore helper**

Add to `AppDelegate` (same file or a small extension in the same file):

```swift
func restoreLastConnectedTunnels() {
    let stored = tunnelRestoreStore.load()
    let plan = planTunnelRestore(storedNames: stored, tunnels: tunnels)

    if !plan.namesToDrop.isEmpty {
        let remaining = stored.filter { !plan.namesToDrop.contains($0) }
        tunnelRestoreStore.save(remaining)
    }

    for name in plan.namesToEnable {
        setTunnelEnabled(name, enabling: true)
    }
}
```

Keep `setTunnelEnabled` in `AppDelegate+TunnelMenu.swift` as the only bring-up path.

- [ ] **Step 4: Run unit tests**

Run: `rm -f .test-unit && make test-unit`

Expected: PASS (no new AppDelegate unit tests required; restore planner already covered).

- [ ] **Step 5: Manual smoke check notes (do not skip when implementing)**

After a local build/run:

1. Connect one or more tunnels, quit the app, relaunch → tunnels come up.
2. Disable All, quit, relaunch → no tunnels come up.

- [ ] **Step 6: Commit**

```bash
git add WireGuardMultiTunnel/AppDelegate.swift
git commit -m "$(cat <<'EOF'
Restore last connected tunnels on launch.

EOF
)"
```

---

### Task 3: Start at login Preferences control

**Files:**
- Create: `WireGuardMultiTunnel/LoginItemService.swift`
- Create: `UnitTests/LoginItemServiceTests.swift`
- Modify: `WireGuardMultiTunnel/PreferencesController.swift`
- Modify: `WireGuardMultiTunnel/PreferencesController.xib`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ServiceManagement.SMAppService` (macOS 13+)
- Produces:
  - `protocol LoginItemControlling { var isAvailable: Bool { get }; var isEnabled: Bool { get }; func setEnabled(_ enabled: Bool) throws }`
  - `final class LoginItemService: LoginItemControlling`
  - Preferences checkbox wired to that protocol

- [ ] **Step 1: Add files to the Xcode project**

Same pbxproj pattern as Task 1:

- `LoginItemService.swift` → App + UnitTests (`A101000021CD90000001F621` / `F622` / `F623`)
- `LoginItemServiceTests.swift` → UnitTests only (`A101000021CD90000001F631` / `F632`)

Link `ServiceManagement.framework` on the app target if the build fails to find `SMAppService` (Xcode often auto-links via `import ServiceManagement`).

- [ ] **Step 2: Write failing LoginItemService / Preferences tests**

Create `UnitTests/LoginItemServiceTests.swift`:

```swift
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

    func testToggleCallsService() throws {
        let fake = FakeLoginItemService()
        let prefs = Preferences(loginItemService: fake)
        prefs.loadWindowIfNeeded()
        prefs.launchAtLoginCheckbox.state = .on
        prefs.launchAtLoginChanged(prefs.launchAtLoginCheckbox)
        XCTAssertEqual(fake.lastSetEnabled, true)
        XCTAssertTrue(fake.isEnabled)
    }
}

private extension Preferences {
    func loadWindowIfNeeded() {
        _ = window
    }
}
```

If loading the nib in unit tests is brittle, keep only a focused test on `LoginItemService` availability gating via a small pure helper, and rely on manual check for the checkbox. Prefer the Fake + Preferences tests when the nib loads cleanly under `UnitTests`.

- [ ] **Step 3: Implement LoginItemService**

Create `WireGuardMultiTunnel/LoginItemService.swift`:

```swift
import Foundation
import ServiceManagement

protocol LoginItemControlling {
    var isAvailable: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

final class LoginItemService: LoginItemControlling {
    var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 4: Wire PreferencesController**

Replace/extend `PreferencesController.swift`:

```swift
import Cocoa

class Preferences: NSWindowController {
    @IBOutlet var launchAtLoginCheckbox: NSButton!

    var loginItemService: LoginItemControlling = LoginItemService()

    convenience init(loginItemService: LoginItemControlling) {
        self.init(windowNibName: NSNib.Name("PreferencesController"))
        self.loginItemService = loginItemService
    }

    override var windowNibName: String {
        return "PreferencesController"
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        syncLaunchAtLoginCheckbox()
    }

    override func showWindow(_: Any?) {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncLaunchAtLoginCheckbox()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.characters == "w" {
            window?.close()
        }
    }

    @objc func cancel(_: Any?) {
        window?.close()
    }

    func syncLaunchAtLoginCheckbox() {
        guard launchAtLoginCheckbox != nil else { return }
        launchAtLoginCheckbox.isEnabled = loginItemService.isAvailable
        if loginItemService.isAvailable {
            launchAtLoginCheckbox.state = loginItemService.isEnabled ? .on : .off
            launchAtLoginCheckbox.toolTip = nil
        } else {
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.toolTip = "Requires macOS 13 or later."
        }
    }

    @IBAction func launchAtLoginChanged(_ sender: NSButton) {
        do {
            try loginItemService.setEnabled(sender.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to update start at login."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        syncLaunchAtLoginCheckbox()
    }
}
```

Keep `AppDelegate.preferences()` creating `Preferences()` with the default `LoginItemService`.

- [ ] **Step 5: Update PreferencesController.xib**

In `WireGuardMultiTunnel/PreferencesController.xib`:

1. Grow window `contentRect` / content view height from `99` to about `150`.
2. Move the two existing detail checkboxes and tip text up (or keep them and place the new control above them).
3. Add a checkbox:

- Title: `Start at login`
- Connect `value` is **not** bound to UserDefaults
- Connect action `launchAtLoginChanged:` to File's Owner
- Connect outlet `launchAtLoginCheckbox` to File's Owner

Suggested frames (adjust in IB if needed):

- Start at login: `x=18 y=110 width=200 height=18`
- Show details on all tunnels: `y=72`
- Show details on connected tunnels: `y=52`
- Tip label: `y=20`
- Window height: `150`

If editing XML by hand, mirror the existing checkbox `button` / `buttonCell` structure and add:

```xml
<connections>
    <action selector="launchAtLoginChanged:" target="-2" id="NEW-ACTION-ID"/>
    <outlet property="launchAtLoginCheckbox" destination="NEW-BUTTON-ID" id="NEW-OUTLET-ID"/>
</connections>
```

(Use unique Interface Builder IDs.)

- [ ] **Step 6: Run unit tests**

Run: `rm -f .test-unit && make test-unit`

Expected: PASS.

- [ ] **Step 7: Manual check for login item (macOS 13+)**

1. Open Preferences → turn on Start at login.
2. Confirm System Settings → General → Login Items lists the app.
3. Turn it off → confirm removal.
4. On macOS 12 (if available): checkbox disabled with tooltip.

- [ ] **Step 8: Commit**

```bash
git add WireGuardMultiTunnel/LoginItemService.swift \
  UnitTests/LoginItemServiceTests.swift \
  WireGuardMultiTunnel/PreferencesController.swift \
  WireGuardMultiTunnel/PreferencesController.xib \
  WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add start at login preference.

EOF
)"
```

---

### Task 4: README roadmap update

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: shipped behavior from Tasks 1–3
- Produces: roadmap reflects completed features

- [ ] **Step 1: Update Recently completed / Planned**

In `README.md` under Recently completed, add:

```markdown
- Start at login from Preferences (macOS 13+; disabled on macOS 12)
- Restore last connected tunnels on every app launch
```

Under Planned, remove:

```markdown
- Auto-start selected tunnels when the app launches
- Launch WireGuardMultiTunnel at login
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
Document start at login and tunnel restore.

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|---|---|
| Persist last connected names in UserDefaults | Task 1 |
| Pure restore planner drops missing configs | Task 1 |
| Restore on every launch after first getTunnels | Task 2 |
| Restore once per launch | Task 2 (`didRunLaunchTunnelRestore`) |
| Do not wipe store before restore | Task 2 ordering |
| Bring-up via existing setTunnelEnabled / notifyError | Task 2 |
| Start at login Preferences checkbox | Task 3 |
| SMAppService on macOS 13+ | Task 3 |
| macOS 12 checkbox disabled | Task 3 |
| Alert on register/unregister failure | Task 3 |
| README roadmap update | Task 4 |

## Manual acceptance (after all tasks)

1. Connect tunnels → quit → relaunch → same tunnels up.
2. Disable All → quit → relaunch → none up.
3. Preferences Start at login on/off matches Login Items (macOS 13+).
4. Delete a remembered `.conf` → launch skips it and cleans the store.
5. Detail checkboxes and Option-key tip still work.
