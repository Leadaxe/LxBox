[English](send-files.md) · [Русский](send-files.ru.md)

# Send files — from "Share" or a device page to an own tailnet device

Files leave the phone through Taildrop to one of the user's own online
devices, either from the system "Share" menu of any app or from the device
page on the Network tab of a Tailscale node.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P1–P3, P7 |
| State | ✅ implemented, 2026-11-02 ([707](../../../tasks/707-taildrop-send-receive-files.md)); not verified on a device |

## What it does

Two entries, one transfer:

1. **Share.** LxBox is a target of the system "Share" menu. The share screen
   asks for a Tailscale node when the running config has more than one, then
   for a peer, then starts the transfer and closes; progress goes on in a
   notification.
2. **Network tab.** A tap on a device on the node's Network tab opens the
   device page with "Send file…". It opens the system file picker; the chosen
   files go to that device.

Several files can go in one share or one pick.

## Parameters

| What | Value |
|------|-------|
| Node choice | only running Tailscale nodes of the running config; asked only when there are several |
| Peer list | online devices of the same owner as this device; shared-in machines and other users' devices are not listed |
| "Send file…" | on the device page, always shown; disabled with the reason when the device does not qualify (see Rules) |
| LxBox in "Share" | listed only while the VPN is up and the running config has a Tailscale node with Allow Taildrop |
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
- "Send file…" on the device page is disabled with the reason under the
  buttons, the first that applies: Taildrop of the node is off, the tailnet
  does not let this node share files, the device is offline, the device
  belongs to another user, the device cannot receive files. Allow Taildrop
  switched off on the receiving side is not visible in advance: it shows up
  as a refusal when sending.
- LxBox appears in "Share" only while the VPN is up and the running config
  has a Tailscale node with Allow Taildrop; the entry is switched on and off
  with the VPN start, stop and a config reload, and is off after a process
  restart until the VPN is up again. If a share still arrives with the VPN
  down or no running Tailscale node (P7), the share screen does not offer a
  peer and explains that the VPN and a Tailscale node are needed; nothing is
  queued for later.
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
| 1 | [707](../../../tasks/707-taildrop-send-receive-files.md) | Implemented | Share target (system dialogs: node, device) and "Send file…" on a peer row; streamed from `content://`, progress notification with Cancel |
| 2 | [707](../../../tasks/707-taildrop-send-receive-files.md) iterations 6–7 | Implemented, device page emulator-verified | 2026-11-03: "Send file…" moved to the device page and is disabled with the reason; LxBox is in "Share" only while the VPN is up with a Tailscale node that allows Taildrop |
