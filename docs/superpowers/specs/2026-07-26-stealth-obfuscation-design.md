# Stealth / Obfuscation Mode — Design

**Date:** 2026-07-26  
**Status:** Approved for implementation planning  
**Scope:** Traffic obfuscation only (no UI camouflage)

## Summary

Add per-tunnel stealth / obfuscation support so a connection can enable one or more of:

1. **AmneziaWG** — obfuscated WireGuard protocol parameters (junk packets / header masking)
2. **udp2raw** — UDP cloaking transport wrapper
3. **wstunnel** — WebSocket/TLS transport wrapper

Configuration is edited in-app (Preferences), stored by the app, and executed by the privileged helper. Obfuscation tools are expected from Homebrew (same dependency model as `wireguard-tools` today).

## Goals

- Enable any compatible combination of the three layers **per tunnel**
- Keep plain (non-stealth) tunnels on the existing `wg-quick` path unchanged
- Own process lifecycle in the helper: start wrappers → bring tunnel up; tear down cleanly on disconnect or failure
- Surface missing Homebrew tools clearly in the UI
- Validate tool paths with the same hardening approach used for `wg` / `wg-quick`

## Non-goals

- UI camouflage (generic icons, renamed menu labels, hiding VPN cues)
- Bundling obfuscation binaries inside the app
- Editing or replacing the user’s on-disk WireGuard `.conf` permanently
- Server-side provisioning (user must already run matching Amnezia / udp2raw / wstunnel endpoints)
- Automatic circumvention / “best obfuscation” heuristics

## Architecture

Stealth is a **per-tunnel stack** owned by the privileged helper, configured from the app.

```text
App (Preferences UI)
  └─ StealthSettingsStore (per tunnel name)
  └─ XPC: setTunnel(name, enable, stealthProfile?)
  └─ XPC: stealthToolsStatus → which binaries exist
        │
        ▼
Helper
  ├─ PathSecurity validation for awg/wstunnel/udp2raw under brewPrefix
  ├─ StealthOrchestrator
  │    ├─ allocate localhost ports
  │    ├─ start wrappers outer → inner (wstunnel, then udp2raw) so each hop has a listener
  │    ├─ write ephemeral WG/Amnezia config (Endpoint → 127.0.0.1)
  │    ├─ run wg-quick or Amnezia equivalent
  │    └─ on down/failure: tunnel down, then wrappers inner → outer
  └─ existing WireGuard path when profile has no layers enabled
```

**Data path (packets):** WireGuard/Amnezia → udp2raw (if on) → wstunnel (if on) → network  

**Process start order:** wstunnel (if on) → udp2raw (if on) → WireGuard/Amnezia  

**Process stop order:** WireGuard/Amnezia → udp2raw (if on) → wstunnel (if on)

### Roles

| Component | Responsibility |
|-----------|----------------|
| App | Preferences editor, persistence, missing-tool UI, pass profile on connect |
| Helper | Only place that starts/stops privileged processes and rewrites endpoints |
| Plain tunnels | Unchanged when no stealth layers are enabled |

## Data model

### `StealthProfile` (keyed by tunnel name)

Stored by the app; sent to the helper on connect. Localhost ports are **not** persisted — allocated at connect time.

```text
StealthProfile
├─ amnezia: AmneziaSettings
│   ├─ enabled: Bool
│   └─ Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4 (AmneziaWG params)
├─ udp2raw: Udp2RawSettings
│   ├─ enabled: Bool
│   ├─ remoteHost: String
│   ├─ remotePort: UInt16
│   ├─ password: String
│   ├─ rawMode: String          # e.g. faketcp / udp / icmp (validated enum)
│   └─ extraArgs: [String]      # optional, tightly validated
└─ wstunnel: WsTunnelSettings
    ├─ enabled: Bool
    ├─ serverURL: String        # wss://… or ws://…
    ├─ tlsSkipVerify: Bool      # default false
    └─ extraArgs: [String]      # optional, tightly validated
```

Persistence: single Codable JSON store under Application Support, keyed by tunnel name, with a schema version field for migrations. Do not split the source of truth across UserDefaults.

Sensitive fields (`password`, and any future keys) stay in the app store; they are sent to the helper only over the existing XPC channel at connect time and must not be logged.

### Compatibility / stacking rules

| Layers | Behavior |
|--------|----------|
| None | Today’s `wg-quick` path |
| Amnezia only | Amnezia tools + params; peer `Endpoint` from original `.conf` |
| udp2raw and/or wstunnel | WireGuard/Amnezia `Endpoint` forced to localhost chain |
| Amnezia + wrappers | Amnezia engine + localhost chain to wrappers |
| Both wrappers | **WireGuard/Amnezia → udp2raw → wstunnel → network** (inner → outer) |

Invalid or incomplete profiles (enabled layer missing required fields) → refuse connect with a clear error; do not partially start.

## Components

### App

1. **`StealthSettingsStore`** — load/save/delete profiles by tunnel name; migrate safely if schema version bumps.
2. **Preferences UI** — tunnel picker + per-layer toggles and fields; disable a layer’s controls when its binary is missing; show install hints (`brew install …`).
3. **Connect path** — when enabling a tunnel, attach the stored `StealthProfile` (or `nil`/empty for plain).
4. **Capability probe** — query helper for which stealth tools are installed; refresh when Preferences opens.

### Helper

1. **`StealthOrchestrator`** — port allocation, process table per tunnel, ordered up/down, ephemeral config directory under `/var/run/wireguard-multitunnel/` (or sibling path).
2. **Tool resolution** — default paths under `brewPrefix` (e.g. `bin/wstunnel`, `bin/udp2raw`, Amnezia `awg-quick` / `amneziawg-go` as determined during implementation against current Homebrew formulae); allow root-defaults overrides consistent with `wgquickBinPath`.
3. **Ephemeral config** — copy/censor-safe rewrite of the user’s `.conf`: inject Amnezia keys when needed; replace `Endpoint` with `127.0.0.1:<innerPort>` when wrappers are enabled. Never modify the user’s source `.conf`.
4. **XPC API extensions**
   - Extend `setTunnel` (or add an overload/sibling) to accept a serialized stealth profile.
   - Add `stealthToolsStatus` returning install presence for each tool.
   - Keep async void-return XPC style (`reply:` callbacks).

### Shared

- Codable types for `StealthProfile` and tool status (Shared target).
- Path basename allowlists for new binaries in `PathSecurity` / related validation.

## Connect / disconnect flow

### Up

1. App loads `StealthProfile` for tunnel name.
2. App calls helper `setTunnel(name, enable: true, profile)`.
3. Helper validates profile + required binaries.
4. If wrappers enabled: allocate free localhost ports; start **wstunnel** (if on), then **udp2raw** (if on), waiting until each local listener is ready (timeout → fail). udp2raw’s remote side points at the next hop (wstunnel local UDP when both are on, else the real remote).
5. Write ephemeral config with correct engine (WireGuard vs Amnezia) and rewritten `Endpoint` if needed.
6. Bring interface up via `wg-quick` or Amnezia equivalent (reuse existing long-name alias logic).
7. On any failure after step 4: best-effort teardown of started wrappers (inner → outer) and ephemeral files; reply with sanitized error.

### Down

1. Bring tunnel interface down.
2. Stop wrappers inner → outer: **udp2raw** (if on), then **wstunnel** (if on).
3. Remove ephemeral config / alias files for that tunnel.
4. Reply success/failure (tunnel down should still attempt wrapper cleanup).

### App quit

Existing “shutdown connected tunnels” behavior must also tear down stealth stacks for those tunnels.

## Error handling

- Missing binary → fail before starting anything; app shows install instructions for that tool.
- Wrapper fails to bind/connect → fail connect; no orphan WireGuard interface.
- WireGuard/Amnezia up fails after wrappers started → stop wrappers; report censored error (reuse private-key redaction).
- Stale processes after crash → on next up for that tunnel, helper cleans known pid/port bookkeeping files under the run directory before retrying.
- Logging → never log udp2raw passwords, Amnezia secrets, or full stealth profiles; log layer names, ports, and exit codes only.

## Security

- Privileged helper remains the only process launching wrappers / Amnezia tools.
- Validate absolute paths and expected basenames (extend existing path hardening).
- Reject `extraArgs` that introduce shell metacharacters or unexpected flags (allowlist or strict argv construction — no shell).
- XPC trust model unchanged (`SMAuthorizedClients` / code-signing checks).
- Ephemeral configs in a helper-owned run directory with restrictive permissions.
- Document that obfuscation is not a substitute for endpoint trust or WireGuard cryptography.

## Preferences UX (minimum)

- Preferences window gains a **Stealth** section (or tab).
- Select tunnel → toggles for Amnezia / udp2raw / wstunnel.
- Fields appear when a layer is enabled.
- Status row per tool: Installed / Missing (+ brew hint).
- Save persists immediately or via explicit Save (match existing Preferences patterns; prefer autosave on edit end).
- No menubar camouflage changes.

## Testing

- **Unit:** profile Codable round-trip; validation (required fields, stacking rules); endpoint rewrite; arg construction without shell; censorship of secrets in log helpers.
- **Helper/unit:** orchestrator up/down ordering with mocked process runner; failure rollback.
- **Integration (optional / gated):** only when tools are installed in CI or locally; otherwise skip with clear message. Do not require Amnezia/wstunnel/udp2raw in default `make test-unit`.

## Homebrew expectations

Verified during implementation (see README **Stealth / obfuscation**):

- `wireguard-tools` (existing) — `wg`, `wg-quick`
- `wstunnel` — `brew install wstunnel` → `$(brewPrefix)/bin/wstunnel`
- `udp2raw` — **no** formula named `udp2raw`. Helper probes `$(brewPrefix)/bin/udp2raw`. Homebrew's `udp2raw-multiplatform` installs `udp2raw_mp` instead; build or install a binary named `udp2raw` into the prefix manually.
- AmneziaWG — **no** stable Homebrew formula. Build [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) (`awg-quick`) and [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) into `$(brewPrefix)/bin`; both are required when Amnezia is enabled.

Binaries are always resolved under the configured `brewPrefix` (default `/opt/homebrew`), same as today.

## Implementation notes

- Prefer extending `HelperProtocol.setTunnel` with an optional profile payload for fewer round-trips; keep a backward-compatible path when profile is nil/empty.
- Reuse `WireGuard.wgQuickInterfaceName` / alias symlink behavior for long tunnel names.
- Track running stealth state in helper memory + small state files so disconnect/quit can clean up after app relaunch if needed.
- UI camouflage explicitly deferred; do not add icon/label stealth in this work.

## Open decisions resolved in this spec

| Topic | Decision |
|-------|----------|
| UI camouflage | Out of scope |
| Which traffic layers | AmneziaWG + udp2raw + wstunnel |
| Selection UX | In-app Preferences per tunnel |
| Tool distribution | Homebrew only |
| Settings storage | App-stored per-tunnel profiles (not in `.conf`) |
| Delivery | Full v1 (all three layers) |
| Orchestration | Helper-owned process stack |
| Packet path | WG/Amnezia → udp2raw → wstunnel → network |
| Process start / stop | Start outer→inner→tunnel; stop tunnel→inner→outer |
| Settings storage format | Application Support Codable JSON (schema versioned) |
