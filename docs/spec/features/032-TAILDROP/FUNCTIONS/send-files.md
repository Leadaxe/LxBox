[English](send-files.md) · [Русский](send-files.ru.md)

# Send files — from "Share" or a peer row to an own tailnet device

Files leave the phone through Taildrop to one of the user's own online
devices, either from the system "Share" menu of any app or from a peer row on
the Network tab of a Tailscale node.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P1–P3, P7 |
| State | ✍ Draft, 2026-11-01 — not implemented |

## What it does

Two entries, one transfer:

1. **Share.** LxBox is a target of the system "Share" menu. The share screen
   asks for a Tailscale node when the running config has more than one, then
   for a peer, then starts the transfer and closes; progress goes on in a
   notification.
2. **Network tab.** A peer row on the node's Network tab has "Send file…". It
   opens the system file picker; the chosen files go to that peer.

Several files can go in one share or one pick.

## Parameters

| What | Value |
|------|-------|
| Node choice | only running Tailscale nodes of the running config; asked only when there are several |
| Peer list | online devices of the same owner as this device; shared-in machines and other users' devices are not listed |
| "Send file…" | on peer rows that qualify for the peer list |
| Files per transfer | one or more |
| Progress | a notification per transfer: peer name, progress, then done or failed |

## Inputs / Outputs

**Inputs:** a share intent with one or more files (any type); the system file
picker's result; the core's tailnet state (peers, online, owner); the VPN and
node state.

**Outputs:** a Taildrop transfer to the peer; a progress notification; a
result in that notification.

## Rules and invariants

- The peer list and "Send file…" follow the same rule: own and online. A
  peer that goes offline during the choice is not sent to; the transfer fails
  with a notification.
- With the VPN down or no running Tailscale node (P7) the share screen does
  not offer a peer and explains that the VPN and a Tailscale node are needed;
  nothing is queued for later.
- The content is read straight from the shared source and streamed to the
  core; nothing is copied on the phone.
- Without Taildrop enabled in the tailnet's admin console the screen says so
  instead of offering peers.
- A share that carries text and no files is not handled here — see
  [share text](share-text.md).

## Boundaries

- No sending to shared-in machines or other users' devices (Taildrop itself
  does not allow it).
- No queue while the VPN is off; no retry by itself.
- Sending needs the service running with this node, that is the VPN up
  ([Maintenance notes](../FEATURE.md#maintenance-notes)).
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | Owner decisions 2026-11-01; no task yet |
