# Task 5 Report: Process runner + orchestrator (mocked)

## Status

DONE

## What was implemented

- `Shared/Const.swift`: added `stealthRunPath = "/var/run/wireguard-multitunnel/stealth"`
- `WireGuardMultiTunnelHelper/StealthProcessRunner.swift`:
  - `protocol StealthProcessRunning` (`start` → pid, `stop`)
  - `struct StealthToolPaths`
  - `enum RealStealthProcessRunner` (`Process` + `SIGTERM`)
- `WireGuardMultiTunnelHelper/StealthOrchestrator.swift`:
  - `bringUp(... useAmnezia: ..., runWgQuick:)` / `bringDown`
  - Start order: wstunnel → udp2raw → wg; stop: wg → udp2raw → wstunnel
  - Packet path: WG → udp2raw → wstunnel (udp2raw remote → local wstunnel when stacked)
  - Port bind probe on `127.0.0.1` (`1024...65535`)
  - State file `runDirectory/<tunnel>.json` (pids/ports only; no passwords)
  - Ephemeral conf via `EphemeralConfig.rewrite`
  - Rollback: stop started pids reverse + delete runtime files
- `UnitTests/StealthOrchestratorTests.swift`: MockStealthRunner order + rollback (+ state password assert)
- `project.pbxproj`: Helper + UnitTests membership

## Argv note

`wstunnel` / `udp2raw` not installed locally. Used documented reasonable client argv (no shell):

- wstunnel: `client -L udp://127.0.0.1:<local>:<exitHost>:<exitPort> [--tls-skip-verify] <extra> <serverURL>`
- udp2raw: `-c -l 127.0.0.1:<local> -r <host>:<port> -k <password> --raw-mode <mode> <extra>`

Unit tests assert start **order** and rollback, not frozen upstream CLI forever. Re-verify with `wstunnel --help` / `udp2raw --help` when pinning README.

## TDD evidence

### RED

1. Wrote `StealthOrchestratorTests` + Const + pbxproj refs; no implementation files.
2. `xcodebuild … -only-testing:UnitTests/StealthOrchestratorTests` failed: missing `StealthProcessRunner.swift` / `StealthOrchestrator.swift`.

### GREEN

1. Implemented runner + orchestrator; fixed swiftlint (`identifier_name`, complexity, type body length).
2. `make test-unit` passed: **30 tests, 0 failures**, including both `StealthOrchestratorTests`.

## Files changed

| File | Action |
|------|--------|
| `Shared/Const.swift` | Modified |
| `WireGuardMultiTunnelHelper/StealthProcessRunner.swift` | Created |
| `WireGuardMultiTunnelHelper/StealthOrchestrator.swift` | Created |
| `UnitTests/StealthOrchestratorTests.swift` | Created |
| `WireGuardMultiTunnel.xcodeproj/project.pbxproj` | Modified |

## Commit

`ce48c73` — Add stealth process orchestrator with mocked lifecycle tests.

## Self-review

- Interfaces match brief (`StealthProcessRunning`, `StealthToolPaths`, `bringUp` with `useAmnezia` + `runWgQuick`).
- Missing tools return `… not installed` before starting.
- Amnezia path requires `awgQuick` and `amneziaGo` (documented).
- Helper + UnitTests only; App unchanged.
- `Info.plist` bumps from helper build script left unstaged/restored.

## Concerns

- Client argv not verified against installed binaries (none present); pin in README later.
- `brewPrefix` stored for future resolution; tool paths are injected today.

---

## Review fixes (Critical / Important)

### Status

FIXED

### What was fixed

1. **Stale-state cleanup on bringUp (Critical):** If `runDirectory/<tunnel>.json` exists, stop recorded pids (udp2raw then wstunnel, best-effort), delete state + ephemeral files, then continue.
2. **Listener readiness (Important):** After each wrapper start, poll up to `readinessTimeout` (default 2s) for process alive (`isAlive` / `kill(pid,0)`) **and** local UDP port in use (bind-probe EADDRINUSE). Injectable `isPortReady` for unit tests. Timeout → rollback + fail.
3. **Liveness before wg success (Important):** Immediately before `runWgQuick`, re-check wrapper pids still alive; else rollback + fail.
4. **WG failure rollback (Important):** Optional `runWgQuickDown` on `bringUp`; invoked best-effort when `runWgQuick` returns false, before stopping wrappers / deleting runtime files.
5. **Stronger tests:** reverse stop order on stacked wg failure; bringDown order `wg-down → udp2raw → wstunnel`; rollback deletes state/ephemeral; stacked udp2raw `-r` points at `127.0.0.1:<wstunnelPort>`; stale cleanup; pre-wg death.

### Supporting changes

- `StealthProcessRunning.isAlive(pid:)`
- Extracted `StealthSupport.swift` (`StealthClientArgv`, endpoint parser, `StealthLocalUdp`, `StealthRuntimeStore`, errors) for lint limits / xargs 255-byte path constraint
- `Info.plist` restored after helper version bump

### Test evidence

```
make test-unit  # unsandboxed
Executed 36 tests, with 0 failures (0 unexpected)
StealthOrchestratorTests: 8 tests, all passed
```

### Fix commit

Harden StealthOrchestrator lifecycle for crash re-up and readiness.
