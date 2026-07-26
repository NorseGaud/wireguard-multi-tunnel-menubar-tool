# Task 9 Report: Docs + roadmap cleanup

## Status

**Complete.** README, SECURITY, design spec, and roadmap updated; committed.

## Changes

### README.md
- Feature bullet: per-tunnel stealth (AmneziaWG / udp2raw / wstunnel).
- New **Stealth / obfuscation** section: Preferences → Stealth, stacking order table, install guidance pinned to helper probes under `$(brewPrefix)/bin`, server/trust note.
- Roadmap: stealth moved to **Recently completed**.

### SECURITY.md
- XPC table: `setTunnel(..., stealthProfileJSON:)`, `stealthToolsStatus`.
- Path hardening: stealth basenames (`awg-quick`, `amneziawg-go`, `udp2raw`, `wstunnel`).
- New **Stealth / obfuscation security**: ephemeral configs, argv-only wrappers, secret non-logging, JSON profile over XPC, trust limits.

### docs/superpowers/specs/2026-07-26-stealth-obfuscation-design.md
- **Homebrew expectations** synced with verified formula/binary names.

## Homebrew verification

| Tool | Helper probe | Homebrew |
|------|--------------|----------|
| wstunnel | `$(brewPrefix)/bin/wstunnel` | `brew install wstunnel` ✓ |
| udp2raw | `$(brewPrefix)/bin/udp2raw` | No formula `udp2raw`; `udp2raw-multiplatform` → `udp2raw_mp` only |
| Amnezia | `awg-quick` + `amneziawg-go` | No stable formula; build from source |

## Concerns

- **Preferences UI** still hints `brew install udp2raw` when missing (`StealthPreferencesView.swift`); that formula does not exist. README/docs are accurate; UI hint is a follow-up.
- Users relying on `udp2raw-multiplatform` must install/symlink a binary named exactly `udp2raw` for the helper to detect it.

## Commit

```
Document stealth obfuscation setup and security model.
```
