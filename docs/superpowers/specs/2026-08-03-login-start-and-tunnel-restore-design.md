# Start at login and restore last tunnels design

Date: 2026-08-03  
Status: approved for planning (pending file review)

## Problem

The app does not start at login. When the user quits or the helper tears tunnels down on XPC close, the next launch leaves all tunnels down. The user must turn tunnels on again by hand.

README lists both behaviors as Planned:

- Auto-start selected tunnels when the app launches
- Launch WireGuardMultiTunnel at login

## Goal

1. The user can turn **Start at login** on or off in Preferences.
2. On every app launch (login start or manual open), the app brings up the tunnels that were connected when the connected set last changed.

## Non-goals

- A Preferences toggle for restore (restore is always on).
- Per-tunnel “auto-start” flags or a fixed single-tunnel pick.
- Helper-owned restore while the GUI app is not running.
- Keep tunnels up across app quit without restore (helper still tears them down on XPC close).
- A separate login-item helper app for macOS 12.

## Chosen approach

App-side restore plus `SMAppService` login item.

- Store connected tunnel names in app `UserDefaults`.
- After the helper is ready and the first `getTunnels` reply lands, bring up remembered tunnels that are down.
- Preferences has one new checkbox for start at login via `SMAppService.mainApp` (macOS 13+).

Rejected alternatives:

- Persist only in `applicationWillTerminate` — misses force-quit and crash.
- LaunchAgent for login — heavier and a poor fit for a menubar app.
- Helper owns restore — out of scope; more privilege and security risk.

## Behavior

### Start at login

- Preferences checkbox title: **Start at login**.
- Default: off.
- On: register the main app as a login item.
- Off: unregister that login item.
- macOS 13+: use `SMAppService.mainApp`.
- macOS 12: checkbox stays off and disabled (no separate login-item helper). Tooltip or short label explains that macOS 13+ is required.
- On Preferences open, sync the checkbox to the real login-item status when the API is available.
- Register or unregister failure: show an alert; set the checkbox to match real status.

### Restore last tunnels

- Always on. No Preferences control.
- Stored value: array of tunnel config names (`lastConnectedTunnelNames` in app `UserDefaults`).
- Default: empty array.
- Update the stored list whenever the connected set changes (connect, disconnect, Disable All, state refresh after settle).
- Empty connected set writes an empty array.
- On every launch, after helper success and the first `getTunnels` reply:
  - For each stored name that exists in current tunnels and is down, call existing `setTunnelEnabled(_:enabling: true)`.
  - Skip names with no matching config; remove them from the store.
- Restore runs once per launch. Later helper reconnects do not re-run restore.
- Bring-up failures use the existing `notifyError` path. Other tunnels continue.
- Pending operations and status spinner reuse the existing path.

## Architecture

| Piece | Role |
|---|---|
| `LoginItemService` | Register / unregister / status for start at login. Injectable seam for tests. |
| `TunnelRestoreStore` | Read / write `lastConnectedTunnelNames` in `UserDefaults`. |
| Pure restore planner | Given stored names + current tunnels, return names to bring up and names to drop. |
| `AppDelegate` | Persist on connected-set change; run restore once after first `getTunnels`. |
| Preferences | New checkbox wired in code to `LoginItemService`. Existing detail checkboxes stay. |

### Data flow

```text
User toggles tunnel
  → setTunnelEnabled / helper
  → state update
  → TunnelRestoreStore.save(connected names)

App launch
  → helper ready
  → getTunnels (first reply)
  → plan restore
  → setTunnelEnabled(true) for tunnels to bring up
  → prune missing names from store

Preferences “Start at login”
  → LoginItemService register / unregister
```

## UI

- Add **Start at login** to `PreferencesController.xib`.
- Grow the Preferences window enough for the new control.
- Keep the two existing detail checkboxes and the Option-key tip.

## Defaults and docs

- Restore key: `lastConnectedTunnelNames` (`[String]`). Empty array is the default. Document the key in code. Do not add it to `DefaultSettings.App` unless registration is required for bindings.
- Start at login has no `UserDefaults` mirror. On macOS 13+, live `SMAppService` status is the source of truth for the checkbox.
- README: move both Planned items into shipped features. State that restore is always on and remembers the last connected set.
- DEBUG `RESET_CONFIGURATION=1` already clears the app defaults domain, so the restore list clears for UI tests.

## Testing

### Unit

- `TunnelRestoreStore`: save, load, empty list, overwrite.
- Restore planner: bring-up set, drop unknown names, no-op when already connected.
- `LoginItemService`: fake backend; no real `SMAppService` in unit tests.

### Manual / integration

- Connect tunnels → quit → relaunch → same tunnels come up.
- Disable All → quit → relaunch → no tunnels come up.
- Start at login on/off matches System Settings → General → Login Items (macOS 13+).
- Delete a remembered `.conf` → launch skips it and cleans the store.

## Success criteria

- Preferences can enable and disable start at login on macOS 13+.
- On macOS 12, the control is disabled and does not register a login item.
- Every app launch restores the last connected tunnel set when those configs still exist.
- Disable All then quit leaves the next launch with no auto-connected tunnels.
- Restore failures do not block other tunnel bring-ups.
- Existing tunnel toggle, Disable All, and Preferences detail options still work.

## Out of scope follow-ups

- Start-at-login support on macOS 12 via a nested login-item helper.
- Keep tunnels up without tearing down on app quit.
- Peer handshake checks before or after restore.
