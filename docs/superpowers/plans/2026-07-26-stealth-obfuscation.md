# Stealth / Obfuscation Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-tunnel AmneziaWG + udp2raw + wstunnel obfuscation, configured in Preferences, orchestrated by the privileged helper.

**Architecture:** App stores `StealthProfile` JSON per tunnel under Application Support and passes it over XPC as a string (NSXPC cannot carry Swift structs). Helper validates tools under `brewPrefix`, starts wrappers outer→inner (`wstunnel` then `udp2raw`), rewrites ephemeral config `Endpoint` to localhost, runs `wg-quick` or `awg-quick`, and tears down tunnel→inner→outer.

**Tech Stack:** Swift / AppKit, NSXPC privileged helper, Homebrew-located CLIs (`wg-quick`, `awg-quick`, `wstunnel`, `udp2raw`, `amneziawg-go`), XCTest via `make test-unit`.

**Spec:** `docs/superpowers/specs/2026-07-26-stealth-obfuscation-design.md`

## Global Constraints

- Traffic obfuscation only — no UI camouflage (icons/labels stay as today).
- Tools resolved under configured `brewPrefix` (default `/opt/homebrew`); Amnezia has no reliable Homebrew formula — document building `awg-quick` / `amneziawg-go` into that prefix (or root-defaults overrides).
- Never modify the user’s on-disk `.conf`; only ephemeral copies under `/var/run/wireguard-multitunnel/`.
- No shell invocation for wrappers — argv arrays only; validate `extraArgs`.
- Never log udp2raw passwords, private keys, or full stealth profiles.
- Packet path: WG/Amnezia → udp2raw → wstunnel → network. Start: outer→inner→tunnel. Stop: tunnel→inner→outer.
- Default `make test-unit` must not require Amnezia/wstunnel/udp2raw installed.
- XPC profile payload is JSON `String` (empty = plain tunnel). Keep existing `setTunnel(tunnelName:enable:reply:)` and add an overload that accepts JSON so older call sites keep compiling during the transition.
- After adding any Swift file, register it in `WireGuardMultiTunnel.xcodeproj/project.pbxproj` for every target that compiles similar files (mirror `Const.swift` / `SecurityValidation.swift` membership: App, Helper, UnitTests, IntegrationTests as applicable).

---

## File map

| File | Role |
|------|------|
| `Shared/StealthTypes.swift` | Codable profiles, tool status, JSON encode/decode, validation |
| `Shared/StealthArgSecurity.swift` | Validate wrapper `extraArgs` (no shell metacharacters) |
| `Shared/HelperProtocol.swift` | XPC: `setTunnel(..., stealthProfileJSON:)`, `stealthToolsStatus` |
| `Shared/Const.swift` | Run-dir constants, default binary basenames |
| `Shared/SecurityValidation.swift` | Reuse `PathSecurity` (no change unless needed) |
| `WireGuardMultiTunnel/StealthSettingsStore.swift` | Application Support JSON persistence |
| `WireGuardMultiTunnel/StealthPreferencesView.swift` | Programmatic Stealth tab UI |
| `WireGuardMultiTunnel/PreferencesController.swift` | Host tab view (General + Stealth) |
| `WireGuardMultiTunnel/PreferencesController.xib` | Resize / embed container if needed |
| `WireGuardMultiTunnel/AppDelegate.swift` | Pass profile JSON on toggle |
| `WireGuardMultiTunnelHelper/EphemeralConfig.swift` | Inject Amnezia keys + rewrite Endpoint |
| `WireGuardMultiTunnelHelper/StealthProcessRunner.swift` | Protocol + real Process launcher |
| `WireGuardMultiTunnelHelper/StealthOrchestrator.swift` | Ports, lifecycle, bookkeeping |
| `WireGuardMultiTunnelHelper/WireGuard.swift` | Support `awg-quick` path when Amnezia enabled |
| `WireGuardMultiTunnelHelper/Helper.swift` | Wire XPC → orchestrator |
| `UnitTests/StealthProfileTests.swift` | Profile/validation/JSON |
| `UnitTests/StealthArgSecurityTests.swift` | Arg allow rules |
| `UnitTests/StealthSettingsStoreTests.swift` | Persistence |
| `UnitTests/EphemeralConfigTests.swift` | Config rewrite |
| `UnitTests/StealthOrchestratorTests.swift` | Ordering + rollback with mock runner |
| `README.md` / `SECURITY.md` | Install docs + security notes |

---

### Task 1: Shared `StealthProfile` types + validation

**Files:**
- Create: `Shared/StealthTypes.swift`
- Create: `UnitTests/StealthProfileTests.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj` (add both files to correct targets; `StealthTypes.swift` like `Const.swift`)

**Interfaces:**
- Consumes: none
- Produces:
  - `struct StealthProfile: Codable, Equatable` with nested `AmneziaSettings`, `Udp2RawSettings`, `WsTunnelSettings`
  - `struct StealthToolsStatus: Codable, Equatable` with `amnezia`, `udp2raw`, `wstunnel` Bools
  - `enum StealthValidationError: Error, Equatable`
  - `StealthProfile.validate() throws`
  - `StealthProfile.hasAnyLayerEnabled: Bool`
  - `StealthProfile.jsonString() throws -> String`
  - `StealthProfile.parse(jsonString:) throws -> StealthProfile`
  - `Udp2RawSettings.RawMode` enum: `faketcp`, `udp`, `icmp`

- [ ] **Step 1: Write the failing tests**

Create `UnitTests/StealthProfileTests.swift`:

```swift
import XCTest

class StealthProfileTests: XCTestCase {
    func testEmptyProfileHasNoLayers() {
        let profile = StealthProfile()
        XCTAssertFalse(profile.hasAnyLayerEnabled)
        XCTAssertNoThrow(try profile.validate())
    }

    func testUdp2RawRequiresRemoteFields() {
        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        XCTAssertThrowsError(try profile.validate())
    }

    func testValidStackedProfileRoundTripsJSON() throws {
        var profile = StealthProfile()
        profile.amnezia.enabled = true
        profile.amnezia.jc = 4
        profile.amnezia.jmin = 40
        profile.amnezia.jmax = 70
        profile.amnezia.s1 = 0
        profile.amnezia.s2 = 0
        profile.amnezia.h1 = 1
        profile.amnezia.h2 = 2
        profile.amnezia.h3 = 3
        profile.amnezia.h4 = 4
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.1"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "secret"
        profile.udp2raw.rawMode = .faketcp
        profile.wstunnel.enabled = true
        profile.wstunnel.serverURL = "wss://example.com/ws"
        let json = try profile.jsonString()
        let parsed = try StealthProfile.parse(jsonString: json)
        XCTAssertEqual(parsed, profile)
    }

    func testWsTunnelRequiresURL() {
        var profile = StealthProfile()
        profile.wstunnel.enabled = true
        XCTAssertThrowsError(try profile.validate())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-unit`

Expected: FAIL — `StealthProfile` undeclared (or file not in target)

- [ ] **Step 3: Implement `Shared/StealthTypes.swift`**

```swift
import Foundation

struct AmneziaSettings: Codable, Equatable {
    var enabled: Bool = false
    var jc: Int = 0
    var jmin: Int = 0
    var jmax: Int = 0
    var s1: Int = 0
    var s2: Int = 0
    var h1: UInt32 = 1
    var h2: UInt32 = 2
    var h3: UInt32 = 3
    var h4: UInt32 = 4
}

struct Udp2RawSettings: Codable, Equatable {
    enum RawMode: String, Codable, Equatable {
        case faketcp
        case udp
        case icmp
    }

    var enabled: Bool = false
    var remoteHost: String = ""
    var remotePort: UInt16 = 0
    var password: String = ""
    var rawMode: RawMode = .faketcp
    var extraArgs: [String] = []
}

struct WsTunnelSettings: Codable, Equatable {
    var enabled: Bool = false
    var serverURL: String = ""
    var tlsSkipVerify: Bool = false
    var extraArgs: [String] = []
}

struct StealthProfile: Codable, Equatable {
    var schemaVersion: Int = 1
    var amnezia: AmneziaSettings = AmneziaSettings()
    var udp2raw: Udp2RawSettings = Udp2RawSettings()
    var wstunnel: WsTunnelSettings = WsTunnelSettings()

    var hasAnyLayerEnabled: Bool {
        amnezia.enabled || udp2raw.enabled || wstunnel.enabled
    }

    func validate() throws {
        if amnezia.enabled {
            guard amnezia.jmin >= 0, amnezia.jmax >= amnezia.jmin, amnezia.jc >= 0 else {
                throw StealthValidationError.invalidAmneziaParams
            }
        }
        if udp2raw.enabled {
            guard !udp2raw.remoteHost.isEmpty, udp2raw.remotePort > 0, !udp2raw.password.isEmpty else {
                throw StealthValidationError.incompleteUdp2Raw
            }
            try StealthArgSecurity.validateExtraArgs(udp2raw.extraArgs)
        }
        if wstunnel.enabled {
            guard let url = URL(string: wstunnel.serverURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "ws" || scheme == "wss"
            else {
                throw StealthValidationError.incompleteWsTunnel
            }
            try StealthArgSecurity.validateExtraArgs(wstunnel.extraArgs)
        }
    }

    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw StealthValidationError.invalidJSON
        }
        return string
    }

    static func parse(jsonString: String) throws -> StealthProfile {
        if jsonString.isEmpty {
            return StealthProfile()
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw StealthValidationError.invalidJSON
        }
        return try JSONDecoder().decode(StealthProfile.self, from: data)
    }
}

struct StealthToolsStatus: Codable, Equatable {
    var amnezia: Bool = false
    var udp2raw: Bool = false
    var wstunnel: Bool = false
}

enum StealthValidationError: Error, Equatable {
    case invalidAmneziaParams
    case incompleteUdp2Raw
    case incompleteWsTunnel
    case invalidJSON
    case invalidExtraArgs(String)
}
```

Note: Task 1 references `StealthArgSecurity` — implement a temporary stub in the same file that accepts empty `extraArgs` and rejects non-empty until Task 2, **or** implement Task 2 immediately after Step 3 before running tests. Preferred: do Task 2 Steps 1–3 next in the same commit batch if tests fail on missing type.

- [ ] **Step 4: Add files to the Xcode project**

Add `Shared/StealthTypes.swift` to App, Helper, UnitTests, IntegrationTests (same membership as `Const.swift`). Add `UnitTests/StealthProfileTests.swift` to UnitTests only. Use unique 24-hex IDs in `project.pbxproj` (PBXBuildFile + PBXFileReference + group children + Sources build phases).

- [ ] **Step 5: Run tests**

Run: `make test-unit`

Expected: PASS for `StealthProfileTests` (after Task 2 arg security exists)

- [ ] **Step 6: Commit**

```bash
git add Shared/StealthTypes.swift UnitTests/StealthProfileTests.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add StealthProfile shared types and validation tests.

EOF
)"
```

---

### Task 2: Extra-arg security helper

**Files:**
- Create: `Shared/StealthArgSecurity.swift`
- Create: `UnitTests/StealthArgSecurityTests.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StealthValidationError.invalidExtraArgs`
- Produces: `enum StealthArgSecurity { static func validateExtraArgs(_ args: [String]) throws }`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest

class StealthArgSecurityTests: XCTestCase {
    func testAcceptsSimpleFlags() throws {
        try StealthArgSecurity.validateExtraArgs(["--foo", "bar", "-v"])
    }

    func testRejectsShellMetacharacters() {
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs([";rm"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs(["$(id)"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs(["a|b"]))
        XCTAssertThrowsError(try StealthArgSecurity.validateExtraArgs([""]))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `xcodebuild -scheme WireGuardMultiTunnel test -only-testing:UnitTests/StealthArgSecurityTests 2>&1 | tail -40`

Expected: FAIL — missing type

- [ ] **Step 3: Implement**

```swift
import Foundation

enum StealthArgSecurity {
    // Allowlist: letters, digits, and common flag/value punctuation. No whitespace or shell ops.
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=+.:/@")

    static func validateExtraArgs(_ args: [String]) throws {
        for arg in args {
            guard !arg.isEmpty else {
                throw StealthValidationError.invalidExtraArgs(arg)
            }
            guard arg.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw StealthValidationError.invalidExtraArgs(arg)
            }
        }
    }
}
```

If Task 1 temporarily inlined a stub, delete that stub and call this type instead.

- [ ] **Step 4: Run tests — expect PASS**

Run: `make test-unit`

- [ ] **Step 5: Commit**

```bash
git add Shared/StealthArgSecurity.swift UnitTests/StealthArgSecurityTests.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj Shared/StealthTypes.swift
git commit -m "$(cat <<'EOF'
Add stealth wrapper extraArgs validation.

EOF
)"
```

---

### Task 3: `StealthSettingsStore` (Application Support JSON)

**Files:**
- Create: `WireGuardMultiTunnel/StealthSettingsStore.swift`
- Create: `UnitTests/StealthSettingsStoreTests.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StealthProfile`
- Produces:
  - `final class StealthSettingsStore`
  - `init(directoryURL: URL)`
  - `func profile(for tunnelName: String) -> StealthProfile`
  - `func save(profile: StealthProfile, for tunnelName: String) throws`
  - `func removeProfile(for tunnelName: String) throws`
  - File: `<directory>/stealth-profiles.json` with shape `{ "schemaVersion": 1, "profiles": { "<tunnel>": StealthProfile } }`

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement store**

```swift
import Foundation

struct StealthProfilesFile: Codable {
    var schemaVersion: Int = 1
    var profiles: [String: StealthProfile] = [:]
}

final class StealthSettingsStore {
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "StealthSettingsStore.io")

    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent("stealth-profiles.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WireGuardMultiTunnel", isDirectory: true)
    }

    func profile(for tunnelName: String) -> StealthProfile {
        ioQueue.sync { load().profiles[tunnelName] ?? StealthProfile() }
    }

    func save(profile: StealthProfile, for tunnelName: String) throws {
        try ioQueue.sync {
            var file = load()
            file.profiles[tunnelName] = profile
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    func removeProfile(for tunnelName: String) throws {
        try ioQueue.sync {
            var file = load()
            file.profiles.removeValue(forKey: tunnelName)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() -> StealthProfilesFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StealthProfilesFile.self, from: data)
        else {
            return StealthProfilesFile()
        }
        return file
    }
}
```

Add to App + UnitTests targets only (not Helper).

- [ ] **Step 4: Run `make test-unit` — PASS**

- [ ] **Step 5: Commit**

```bash
git add WireGuardMultiTunnel/StealthSettingsStore.swift UnitTests/StealthSettingsStoreTests.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add Application Support store for per-tunnel stealth profiles.

EOF
)"
```

---

### Task 4: Ephemeral config rewrite

**Files:**
- Create: `WireGuardMultiTunnelHelper/EphemeralConfig.swift`
- Create: `UnitTests/EphemeralConfigTests.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj` (Helper + UnitTests)

**Interfaces:**
- Consumes: `StealthProfile`
- Produces:
  - `enum EphemeralConfig`
  - `static func rewrite(configText: String, profile: StealthProfile, localEndpoint: String?) throws -> String`
  - `localEndpoint` format `"127.0.0.1:PORT"` when any wrapper enabled; `nil` keeps original Endpoint
  - When `profile.amnezia.enabled`, ensure `[Interface]` contains `Jc/Jmin/Jmax/S1/S2/H1/H2/H3/H4` (replace existing keys if present)

- [ ] **Step 1: Write failing tests**

```swift
import XCTest

class EphemeralConfigTests: XCTestCase {
    let base = """
    [Interface]
    PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
    Address = 10.0.0.2/32

    [Peer]
    PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 0.0.0.0/0
    """

    func testRewritesEndpointWhenWrapperEnabled() throws {
        var profile = StealthProfile()
        profile.udp2raw.enabled = true
        profile.udp2raw.remoteHost = "203.0.113.9"
        profile.udp2raw.remotePort = 4096
        profile.udp2raw.password = "x"
        let out = try EphemeralConfig.rewrite(configText: base, profile: profile, localEndpoint: "127.0.0.1:51821")
        XCTAssertTrue(out.contains("Endpoint = 127.0.0.1:51821"))
        XCTAssertFalse(out.contains("203.0.113.9:51820"))
    }

    func testInjectsAmneziaKeys() throws {
        var profile = StealthProfile()
        profile.amnezia.enabled = true
        profile.amnezia.jc = 3
        let out = try EphemeralConfig.rewrite(configText: base, profile: profile, localEndpoint: nil)
        XCTAssertTrue(out.contains("Jc = 3"))
        XCTAssertTrue(out.contains("Endpoint = 203.0.113.9:51820"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement rewrite**

Implement line-oriented INI editing in `EphemeralConfig.swift`:

- Split into lines; track current section (`Interface` / `Peer`).
- On `Endpoint =` inside Peer when `localEndpoint != nil`, replace value.
- When Amnezia enabled, after `[Interface]` header (or before first blank after Interface keys), upsert `Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`–`H4` from profile.
- Preserve `PrivateKey` unchanged (do not censor in ephemeral file — that file is helper-local and required to connect).
- Throw `StealthValidationError.incompleteUdp2Raw` style errors only via profile.validate() called by orchestrator; rewrite may throw a local `EphemeralConfigError.missingPeerEndpoint` if wrappers on and no Endpoint line exists when localEndpoint set is still applied by inserting under first `[Peer]`.

- [ ] **Step 4: Run `make test-unit` — PASS**

- [ ] **Step 5: Commit**

```bash
git add WireGuardMultiTunnelHelper/EphemeralConfig.swift UnitTests/EphemeralConfigTests.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add ephemeral WireGuard/Amnezia config rewriting for stealth endpoints.

EOF
)"
```

---

### Task 5: Process runner + orchestrator (mocked)

**Files:**
- Create: `WireGuardMultiTunnelHelper/StealthProcessRunner.swift`
- Create: `WireGuardMultiTunnelHelper/StealthOrchestrator.swift`
- Create: `UnitTests/StealthOrchestratorTests.swift`
- Modify: `Shared/Const.swift` — add `stealthRunPath` sibling constant
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StealthProfile`, `EphemeralConfig`, `PathSecurity`
- Produces:
  - `protocol StealthProcessRunning` with `func start(executable: String, arguments: [String]) throws -> Int32` (returns pid) and `func stop(pid: Int32)`
  - `struct StealthToolPaths` with resolved absolute paths (optional Strings)
  - `final class StealthOrchestrator`
  - `func bringUp(tunnelName: String, sourceConfigPath: String, profile: StealthProfile, runWgQuick: (String) -> (Bool, String)) -> (Bool, String)`
  - `func bringDown(tunnelName: String, runWgQuickDown: () -> (Bool, String)) -> (Bool, String)`
  - Start order when both wrappers: allocate ports → start wstunnel → start udp2raw → write ephemeral → `runWgQuick`
  - On failure after any start: stop started pids reverse, delete ephemeral files

**Const addition:**

```swift
let stealthRunPath = "/var/run/wireguard-multitunnel/stealth"
```

- [ ] **Step 1: Write failing orchestrator tests with a mock runner**

```swift
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
        let (ok, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: profile,
            useAmnezia: false,
            runWgQuick: { path in
                wgCalls.append(path)
                return (true, "")
            }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.started.map(\.0), ["/usr/local/bin/wstunnel", "/usr/local/bin/udp2raw"])
        XCTAssertEqual(wgCalls.count, 1)
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
        let (ok, _) = orch.bringUp(
            tunnelName: "home",
            sourceConfigPath: configURL.path,
            profile: profile,
            useAmnezia: false,
            runWgQuick: { _ in (false, "boom") }
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(runner.stopped.count, 1)
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement runner + orchestrator**

`StealthProcessRunner.swift`:

```swift
import Foundation

protocol StealthProcessRunning {
    func start(executable: String, arguments: [String]) throws -> Int32
    func stop(pid: Int32)
}

struct StealthToolPaths {
    var awgQuick: String?
    var amneziaGo: String?
    var udp2raw: String?
    var wstunnel: String?
}

enum RealStealthProcessRunner: StealthProcessRunning {
    case shared

    func start(executable: String, arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task.processIdentifier
    }

    func stop(pid: Int32) {
        kill(pid, SIGTERM)
    }
}
```

`StealthOrchestrator.swift` responsibilities:

1. `try profile.validate()`
2. If wrappers enabled, require corresponding tool paths non-nil; else return `(false, "… not installed")`
3. If Amnezia, require `awgQuick` (and document `amneziaGo` must exist for awg-quick)
4. `allocatePort()` using `1024...65535` bind probe on `127.0.0.1`
5. Build argv:
   - **wstunnel client** (adjust to current CLI during implementation; pin in README): local UDP listen + server URL. Example shape to verify against `wstunnel --help` at impl time:
     - `["client", "-L", "udp://127.0.0.1:\(wgPort):\(originalHost):\(originalPort)", profile.wstunnel.serverURL]` when wstunnel-only
     - When stacked with udp2raw: wstunnel provides outer hop; udp2raw remote becomes `127.0.0.1:<wstunnelLocalUdp>` **or** the inverse per verified CLI — **must match packet path WG→udp2raw→wstunnel**. Concrete argv must be verified with installed binaries; unit tests assert call **order** and that passwords are not logged, not exact upstream CLI forever.
6. Persist per-tunnel state file `runDirectory/<tunnel>.json` with pids + ports (no passwords)
7. Write ephemeral conf via `EphemeralConfig.rewrite` into `runDirectory/<alias>.conf`
8. Call `runWgQuick` with that path
9. `bringDown` reads state, runs wg down, stops pids udp2raw then wstunnel, deletes state/ephemeral

Expose `original Endpoint` host/port parser from source config for wrapper targeting when only one wrapper is used.

- [ ] **Step 4: Run `make test-unit` — PASS**

- [ ] **Step 5: Commit**

```bash
git add WireGuardMultiTunnelHelper/StealthProcessRunner.swift WireGuardMultiTunnelHelper/StealthOrchestrator.swift UnitTests/StealthOrchestratorTests.swift Shared/Const.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add stealth process orchestrator with mocked lifecycle tests.

EOF
)"
```

---

### Task 6: XPC protocol + helper tool probe

**Files:**
- Modify: `Shared/HelperProtocol.swift`
- Modify: `WireGuardMultiTunnelHelper/Helper.swift`
- Modify: `UnitTests/HelperTests.swift` (add tools-status smoke if constructible)

**Interfaces:**
- Consumes: `StealthToolsStatus`, `PathSecurity`, `brewPrefix`
- Produces XPC:
  - `func setTunnel(tunnelName: String, enable: Bool, stealthProfileJSON: String, reply: @escaping (Bool, String) -> Void)`
  - `func stealthToolsStatus(_ reply: @escaping (String) -> Void)` — JSON-encoded `StealthToolsStatus`
  - Keep existing `setTunnel(tunnelName:enable:reply:)` delegating to new method with `stealthProfileJSON: ""`

- [ ] **Step 1: Extend protocol**

```swift
@objc(HelperProtocol)
protocol HelperProtocol {
    func getTunnels(reply: @escaping (TunnelInfo) -> Void)
    func setTunnel(tunnelName: String, enable: Bool, reply: @escaping (_ success: Bool, _ errorMessage: String) -> Void)
    func setTunnel(tunnelName: String, enable: Bool, stealthProfileJSON: String,
                   reply: @escaping (_ success: Bool, _ errorMessage: String) -> Void)
    func getVersion(_ reply: @escaping (String) -> Void)
    func wireguardInstalled(_ reply: @escaping (Bool) -> Void)
    func stealthToolsStatus(_ reply: @escaping (String) -> Void)
}
```

- [ ] **Step 2: Implement in `Helper.swift`**

Resolve defaults:

```swift
// under brewPrefix/bin:
// awg-quick, amneziawg-go, udp2raw, wstunnel
```

`stealthToolsStatus` uses `PathSecurity.validateExecutableBinaryPath` for each basename and returns JSON string of `StealthToolsStatus`.

Old `setTunnel(tunnelName:enable:reply:)` calls `setTunnel(tunnelName:enable:stealthProfileJSON:reply:)` with `""`.

New method for now: if JSON empty / profile has no layers → existing `wireguard.setTunnel`. If layers enabled → return `(false, "Stealth orchestration not wired")` until Task 7 (or wire Task 7 in the same change set). **Prefer completing Task 7 in the same working session before commit if you want no dead XPC path.**

- [ ] **Step 3: Unit test basename probe with `/bin/sh` pattern already used in HelperTests — add:**

```swift
func testStealthToolsStatusReturnsJSON() {
    let exp = expectation(description: "status")
    Helper().stealthToolsStatus { json in
        XCTAssertNotNil(try? JSONDecoder().decode(StealthToolsStatus.self, from: Data(json.utf8)))
        exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
}
```

- [ ] **Step 4: `make test-unit` — PASS**

- [ ] **Step 5: Commit**

```bash
git add Shared/HelperProtocol.swift WireGuardMultiTunnelHelper/Helper.swift UnitTests/HelperTests.swift
git commit -m "$(cat <<'EOF'
Extend helper XPC with stealth profile JSON and tools status.

EOF
)"
```

---

### Task 7: Wire orchestrator into helper up/down + Amnezia `awg-quick`

**Files:**
- Modify: `WireGuardMultiTunnelHelper/Helper.swift`
- Modify: `WireGuardMultiTunnelHelper/WireGuard.swift`
- Modify: `WireGuardMultiTunnelHelper/StealthOrchestrator.swift` (if needed)

**Interfaces:**
- Consumes: Task 5 orchestrator, Task 4 rewrite
- Produces: real connect/disconnect path for stealth profiles

- [ ] **Step 1: Add WireGuard helpers**

In `WireGuard.swift`:

- Add optional `awgquickBinPath: String` to `WireGuard` (or pass into orchestrator closure from Helper).
- Add method:

```swift
func setTunnel(tunnelName: String, enable: Bool, quickBinPath: String) -> (Bool, String)
```

that is the existing `setTunnel` body but uses `quickBinPath` instead of `wgquickBinPath` for the Process launch. Refactor current `setTunnel` to call it with `wgquickBinPath`.

- [ ] **Step 2: Helper owns a `StealthOrchestrator`**

On `setTunnel(... stealthProfileJSON:)`:

1. Parse + `validate()` profile; on error reply false with message.
2. If `!enable`: if stealth state exists for tunnel, `orchestrator.bringDown` then ensure interface down; else plain `wireguard.setTunnel`.
3. If `enable` && `!profile.hasAnyLayerEnabled`: plain path.
4. If `enable` && layers: resolve tool paths; `orchestrator.bringUp` with `useAmnezia: profile.amnezia.enabled` and `runWgQuick` closure calling `wireguard.setTunnel` / ephemeral file up via `awg-quick` or `wg-quick`.

Important: for stealth, prefer bringing up using the **ephemeral config path** produced by the orchestrator (like long-name alias path today), not the original basename — extend `WireGuard` with `wgQuick(["up", ephemeralConfPath])` already supported by `wg-quick` when passed a path.

- [ ] **Step 3: Ensure `shutdownConnectedTunnels` also clears stealth stacks**

Before/after each tunnel down, call orchestrator bringDown when state file exists.

- [ ] **Step 4: Manual sanity (no new CI dependency)**

If tools missing, enabling a stealth profile must reply with a clear “not installed” error. Cover with a unit test that uses nil tool paths:

```swift
func testBringUpFailsWhenWsTunnelMissingBinary() {
    // orchestrator with wstunnel path nil, profile.wstunnel.enabled = true → false
}
```

Add to `StealthOrchestratorTests`.

- [ ] **Step 5: `make test-unit` — PASS**

- [ ] **Step 6: Commit**

```bash
git add WireGuardMultiTunnelHelper/Helper.swift WireGuardMultiTunnelHelper/WireGuard.swift WireGuardMultiTunnelHelper/StealthOrchestrator.swift UnitTests/StealthOrchestratorTests.swift
git commit -m "$(cat <<'EOF'
Wire stealth orchestrator into helper tunnel up/down paths.

EOF
)"
```

---

### Task 8: App connect path + Preferences Stealth UI

**Files:**
- Create: `WireGuardMultiTunnel/StealthPreferencesView.swift`
- Modify: `WireGuardMultiTunnel/PreferencesController.swift`
- Modify: `WireGuardMultiTunnel/PreferencesController.xib` (increase window size; add container view outlet **or** replace content programmatically in `windowDidLoad`)
- Modify: `WireGuardMultiTunnel/AppDelegate.swift`
- Modify: `WireGuardMultiTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StealthSettingsStore`, `HelperProtocol.stealthToolsStatus`, `setTunnel(..., stealthProfileJSON:)`
- Produces: user-editable per-tunnel stealth settings; connect uses stored profile

- [ ] **Step 1: AppDelegate — pass JSON on toggle**

Hold `let stealthStore = StealthSettingsStore(directoryURL: StealthSettingsStore.defaultDirectoryURL)`.

In `toggleTunnel`, when `enabling`:

```swift
let profile = stealthStore.profile(for: tunnelName)
let json = (try? profile.jsonString()) ?? ""
xpcService?.setTunnel(tunnelName: tunnelName, enable: enabling, stealthProfileJSON: json, reply: { ... })
```

When disabling, still pass stored JSON (or `""`) so helper can find state; helper should not require profile fields on down.

- [ ] **Step 2: Build Stealth preferences UI in code**

`StealthPreferencesView`: `NSView` subclass with:

- `NSPopUpButton` tunnel list (filled from `AppDelegate.tunnels` or a callback)
- Checkboxes: Amnezia / udp2raw / wstunnel
- Fields for each layer (NSTextField); password field `isSecureText = true` for udp2raw
- Labels for tool install status
- On change: validate + `store.save`
- `reloadToolsStatus(json:)` from helper

`Preferences` window: in `windowDidLoad`, build `NSTabView` with “General” (existing checkbox content) and “Stealth” (`StealthPreferencesView`). Easiest path: abandon editing the tiny xib layout and construct the window content in `Preferences.windowDidLoad` while keeping the xib window shell, **or** enlarge xib and add an `NSTabView` outlet.

Wire Preferences to ask AppDelegate/helper for tunnel names + `stealthToolsStatus` on `showWindow`.

- [ ] **Step 3: Install hints copy**

When a tool is missing, show:

```text
brew install wstunnel
brew install udp2raw
# Amnezia: build awg-quick + amneziawg-go into $(brew --prefix)/bin
```

Exact Amnezia build one-liner in README (Task 9).

- [ ] **Step 4: Run `make test-unit` — PASS**

- [ ] **Step 5: Manual UI check**

Run the app, open Preferences → Stealth, select a tunnel, enable wstunnel with incomplete URL, confirm save still allowed but connect fails with validation error (or disable Save until valid — prefer save always, fail on connect).

- [ ] **Step 6: Commit**

```bash
git add WireGuardMultiTunnel/StealthPreferencesView.swift WireGuardMultiTunnel/PreferencesController.swift WireGuardMultiTunnel/PreferencesController.xib WireGuardMultiTunnel/AppDelegate.swift WireGuardMultiTunnel.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add Preferences Stealth tab and pass profiles on tunnel toggle.

EOF
)"
```

---

### Task 9: Docs + roadmap cleanup

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/superpowers/specs/2026-07-26-stealth-obfuscation-design.md` only if implementation pinned different binary names (keep in sync)

- [ ] **Step 1: README — Features + install**

Add feature bullet: per-tunnel stealth (AmneziaWG / udp2raw / wstunnel).

Add section **Stealth / obfuscation**:

- Preferences → Stealth
- Stacking order
- Homebrew: `brew install wstunnel udp2raw` (verify formula names; if `udp2raw` formula differs, document the working one)
- Amnezia: no stable Homebrew formula; build [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) (`awg-quick`) and [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) into `$(brew --prefix)/bin`, or set root defaults overrides analogous to `wgquickBinPath`
- Server must already speak the matching protocols
- Obfuscation is not a substitute for WireGuard crypto / endpoint trust

- [ ] **Step 2: SECURITY.md**

Document: ephemeral configs under stealth run dir; argv-only wrappers; secrets not logged; XPC JSON profile; path basename checks for new tools.

- [ ] **Step 3: Commit**

```bash
git add README.md SECURITY.md
git commit -m "$(cat <<'EOF'
Document stealth obfuscation setup and security model.

EOF
)"
```

---

### Task 10: End-to-end verification

**Files:** none required unless fixes

- [ ] **Step 1: `make test-unit` — all PASS**

- [ ] **Step 2: `make fix` then `make check` — clean**

- [ ] **Step 3: Manual matrix (local, when tools available)**

| Profile | Expected |
|---------|----------|
| No stealth | Identical to today |
| Amnezia only | Uses `awg-quick`; Endpoint unchanged |
| wstunnel only | Wrapper up; Endpoint localhost |
| udp2raw only | Wrapper up; Endpoint localhost |
| udp2raw + wstunnel | Start wstunnel then udp2raw; WG last |
| Missing binary | Connect error, no orphan utun |
| Quit with stealth up | Wrappers stop |

- [ ] **Step 4: Final commit only if fixes landed**

```bash
git add -A
git commit -m "$(cat <<'EOF'
Fix stealth edge cases found in verification.

EOF
)"
```

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|------------------|------|
| Per-tunnel Amnezia + udp2raw + wstunnel | 1, 3, 7, 8 |
| Preferences UI | 8 |
| App Support JSON store | 3 |
| Homebrew / brewPrefix tools | 6, 7, 9 |
| Helper orchestration + order | 5, 7 |
| Ephemeral config, no user `.conf` mutation | 4, 7 |
| XPC profile + tools status | 6 |
| Error rollback / no orphan iface | 5, 7 |
| No secret logging | 5, 7, 9 |
| Path/arg hardening | 2, 6 |
| Unit tests without tools installed | 1–5, 7 |
| No UI camouflage | Global constraint / Task 8 |
| Docs | 9 |

**Placeholder scan:** CLI argv for `wstunnel`/`udp2raw` must be verified against `--help` at Task 5/7 implementation time — tests lock ordering and failure rollback, not eternal upstream flag strings. Amnezia install is source/build-into-prefix, not a fake Homebrew formula.

**Type consistency:** `StealthProfile`, `StealthToolsStatus`, `StealthValidationError`, `StealthArgSecurity`, `StealthSettingsStore`, `EphemeralConfig.rewrite`, `StealthProcessRunning`, `StealthOrchestrator.bringUp/bringDown`, XPC `stealthProfileJSON: String` — used consistently across tasks.
