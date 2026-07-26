# Security model

WireGuardMultiTunnel is a menubar application that controls WireGuard tunnels through `wg-quick`. Privileged work runs in a separate helper installed with Apple's privileged-helper mechanism. This document describes how the two processes trust each other, what the helper is allowed to do, and what to expect from release builds versus self-built binaries.

The app targets **macOS 12+**. Code-signing enforcement details differ slightly on macOS 13 and later (see [Code signing and XPC trust](#code-signing-and-xpc-trust)).

## Architecture

The project splits into two Mach-O binaries:

| Component | Role |
|-----------|------|
| **WireGuardMultiTunnel** (app) | Menubar UI, user interaction, XPC client |
| **WireGuardMultiTunnelHelper** (privileged helper) | Runs `wg-quick`, reads tunnel configs and runtime state, watches config directories |

The app does not invoke `wg-quick` directly. When a tunnel must be brought up or down, or when configuration or state must be read, the app calls the helper over [XPC](https://developer.apple.com/documentation/xpc). The helper runs with elevated privileges granted at install time via [`SMJobBless`](https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless).

Relevant source:

- App XPC client: `WireGuardMultiTunnel/HelperXPC.swift`
- Helper XPC listener: `WireGuardMultiTunnelHelper/AppXPC.swift`
- Shared protocols: `Shared/HelperProtocol.swift`, `Shared/AppProtocol.swift`
- Signing and path checks: `Shared/SecurityValidation.swift`

## Privileged helper installation

On launch, the app checks whether the installed helper's `CFBundleVersion` matches the helper embedded in the app bundle. If not, it calls `SMJobBless`, which prompts the user for administrator credentials and installs or updates the launchd-managed helper.

The helper Mach service name is `WireGuardMultiTunnelHelper` (`HelperConstants.machServiceName`).

## XPC interfaces

Communication uses simple, typed primitives (no arbitrary shell commands from the app). All XPC methods are asynchronous (`void` return type with reply blocks).

**App → helper** (`HelperProtocol`):

| Method | Purpose |
|--------|---------|
| `getTunnels` | Tunnel names, interface names, and censored config text |
| `setTunnel(tunnelName:enable:)` | Bring a tunnel up or down via `wg-quick` |
| `setTunnel(tunnelName:enable:stealthProfileJSON:)` | Same, with an optional JSON-encoded stealth profile (Amnezia / udp2raw / wstunnel layers) |
| `getVersion` | Helper bundle version (for update detection) |
| `wireguardInstalled` | Whether validated `wg` and `wg-quick` binaries exist |
| `stealthToolsStatus` | JSON map of which stealth binaries exist under `brewPrefix/bin` |

**Helper → app** (`AppProtocol`):

| Method | Purpose |
|--------|---------|
| `updateState` | Notify the app that configs or runtime state may have changed (menubar refresh) |

The helper watches WireGuard config directories and `/var/run/wireguard` (via `SKQueue`) and debounces filesystem events before calling `updateState`.

## Code signing and XPC trust

Helper installation and ongoing XPC connections rely on **matching code-signing requirements** in three places:

1. `SMPrivilegedExecutables` in `WireGuardMultiTunnel/Info.plist` (app blesses only a helper signed like this)
2. `SMAuthorizedClients` in `WireGuardMultiTunnelHelper/Info.plist` (helper accepts only clients signed like this)
3. `XPCSecurity` in `Shared/SecurityValidation.swift` (runtime checks; must stay in sync with the plists)

Current requirement strings (team **OU `4JD8RUCQ2W`**, signed with **Apple Development: Nathan Pierce (9W52V85K8R)**):

- **App (client):** `anchor apple generic and identifier "WireGuardMultiTunnel" and certificate leaf[subject.OU] = "4JD8RUCQ2W"`
- **Helper:** `anchor apple generic and identifier "WireGuardMultiTunnelHelper" and certificate leaf[subject.OU] = "4JD8RUCQ2W"`

Behavior:

- **Helper** rejects new XPC connections that do not satisfy the app requirement (`AppXPC` / `isAuthorizedAppConnection`).
- **App** applies the helper requirement when connecting (`HelperXPC` / `applyHelperRequirement`) and invalidates the connection if validation fails.
- **macOS 13+:** requirements are applied with `setConnectionCodeSigningRequirement` / `setCodeSigningRequirement`.
- **macOS 12:** the same strings are checked with `SecCodeCheckValidity` on the peer process.

### Release builds vs self-signed builds

Published releases are **not** signed with a notarized Developer ID in the maintainer's current workflow; users may need to allow the app via System Settings (Gatekeeper). That is separate from the **privileged-helper trust model**: `SMJobBless` and XPC validation expect the app and helper to be signed with identities that satisfy the plist requirements above. Ad-hoc or mismatched signing can cause helper install or XPC connection to fail even after Gatekeeper allows the app to open.

To ship or run with your own team ID, sign **both** targets with the same Developer ID Application certificate and update the OU in:

- `WireGuardMultiTunnel/Info.plist` (`SMPrivilegedExecutables`)
- `WireGuardMultiTunnelHelper/Info.plist` (`SMAuthorizedClients`)
- `Shared/SecurityValidation.swift` (`authorizedAppRequirement`, `authorizedHelperRequirement`)

CI builds with `CODE_SIGNING_ALLOWED=NO`; that disables this trust chain and is only suitable for unit tests, not for installing the helper on a real system.

## Path hardening

The helper executes external tools only after path validation (`PathSecurity`):

- **`brewPrefix`** — must be an absolute directory path; symlinks are resolved; `..` segments are rejected. Default: `/opt/homebrew`. Configs are read from `${brewPrefix}/etc/wireguard`.
- **`wgquickBinPath`** — optional override via root `defaults`; must be an absolute path whose last component is exactly `wg-quick`, must exist as a non-directory file, and must be executable when checked by `wireguardInstalled`.
- **`wg`** — derived as `${brewPrefix}/bin/wg` (same validation rules for executables).
- **Stealth tools** — `awg-quick`, `amneziawg-go`, `udp2raw`, and `wstunnel` are resolved only as `${brewPrefix}/bin/<basename>`. Each path must pass the same absolute-path and basename checks as `wg-quick` (`PathSecurity.validateExecutableBinaryPath`). Symlinks are resolved; `..` segments are rejected.

Invalid `defaults` values are logged and the helper falls back to defaults rather than using an unsafe path.

Example overrides (require root; domain `WireGuardMultiTunnelHelper`):

```bash
sudo defaults write WireGuardMultiTunnelHelper brewPrefix /opt/local/
sudo defaults write WireGuardMultiTunnelHelper wgquickBinPath /opt/local/bin/wg-quick
```

The menubar app does not read these helper `defaults`; it may still warn that WireGuard is missing if paths differ from what the app assumes—see comments in `WireGuardMultiTunnelHelper/Helper.swift`.

## Configuration privacy over XPC

Tunnel configuration files on disk contain private keys. Before config text is sent to the app, the helper runs `WireGuard.censorConfigurationData`, which redacts `PrivateKey` and `PresharedKey` lines. Unit tests assert that raw key material does not appear in censored output (`UnitTests/HelperTests.swift`). Error messages from `wg-quick` are also passed through the same censoring where applicable.

## Stealth / obfuscation security

When a tunnel is brought up with stealth layers enabled, the helper:

- Accepts a **JSON stealth profile** over XPC (`setTunnel(..., stealthProfileJSON:)`). The app stores profiles per tunnel; they are not written into the user's on-disk `.conf` files.
- Writes **ephemeral configs** under `/var/run/wireguard-multitunnel/stealth/` (`stealthRunPath`). These are rewritten copies (local endpoint injection, optional Amnezia keys) used only for the current session and removed on tear-down.
- Starts wrapper processes with **argv only** — no shell invocation. Free-form per-layer `extraArgs` are rejected in v1 (`StealthValidationError.extraArgsNotSupported`).
- **Does not log** udp2raw passwords, Amnezia secrets, or full stealth profile payloads. Logs are limited to layer names, ports, PIDs, and exit codes.

Stealth obfuscation changes transport appearance; it does not replace WireGuard's cryptographic trust model. Endpoint trust and key verification remain the user's responsibility.

## Helper lifecycle

- The helper process starts when the app establishes XPC and stays alive while connections exist.
- When the app quits, XPC connections close; the helper shuts down connected tunnels, then stops its run loop.
- To avoid launchd throttling when the helper restarts too quickly, shutdown is delayed by up to **10 seconds** after helper start (`Helper.shutdown`). The helper can remain running briefly after the app exits; a new app launch can cancel a pending shutdown (`abortShutdown`).

## Design goals and limits

The helper keeps a narrow surface: WireGuard paths, `wg` / `wg-quick`, validated stealth wrapper binaries under `brewPrefix`, filesystem notifications, and the XPC API above. It is not a general-purpose root executor.

What this model **does** enforce:

- Only appropriately signed app bundles should connect to the installed helper (when signing is enabled).
- Only vetted absolute paths are used for `wg`, `wg-quick`, and config roots.
- Sensitive key material is not sent verbatim over XPC.

What it **does not** guarantee:

- Protection against a malicious user who already has admin rights (they can edit configs, `defaults`, or binaries the helper will execute).
- That unsigned or incorrectly signed release downloads will install or retain a working privileged helper without aligning signing requirements.

Report security issues through the repository's normal issue tracker or contact the maintainer privately if you prefer responsible disclosure.
