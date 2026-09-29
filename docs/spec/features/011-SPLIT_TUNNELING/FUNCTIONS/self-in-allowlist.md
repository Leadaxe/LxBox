[English](self-in-allowlist.md) · [Русский](self-in-allowlist.ru.md)

# Own app in the Allow-list

| Field | Value |
|-------|-------|
| Feature | [011-SPLIT_TUNNELING](../FEATURE.md) |
| Promises | P7 |
| State | ✅ written from code, 2026-09-28 |

## What it does

In the Allow-list everything not in the list goes around the tunnel —
including the app itself. So that the core's own traffic is guaranteed to go
predictably (parity with the reference sing-box client), on every tunnel
bring-up in the Allow-list the app adds itself to the allowed ones — without the
user's involvement and without writing to the saved config.

## Parameters

None: the decision is derived from the config — `include_package` on the first
tunnel input means Allow-list.

## Inputs / Outputs

**Input:** the saved config at core start and restart.

**Output:** the core start parameter `includePackage` = our own package (only
Allow-list); the core appends it to the end of the list of the first tunnel
input of the running config. The saved config and `GET /config` do not
contain it.

## Rules and invariants

- Allow-list — appended; Deny-list and Off — not: the OS rejects allowed and
  disallowed apps in one tunnel entirely.
- Appending is an append without sorting and deduplication: if the user added
  the app to the list themselves, it will be there twice, and that is normal.
- The comparison "is the running config stale?" reproduces the same append,
  otherwise the "restart" banner would always hang in the Allow-list.
- The core's traffic to nodes is additionally protected from getting into its
  own tunnel regardless of the mode; self-appending is a safety net, not the
  only protection.
- "Allow VPN bypass" (010-VPN_SERVICE) is unrelated: neither replaces nor
  cancels the other.

## Boundaries

- Self-appending is not shown to the user; one can add the app to the list
  manually, in Deny-list this has no effect on the core's tunnel.
- Depends on OS capabilities: the rule "allowed and disallowed apps are
  mutually exclusive", the behaviour of our own traffic with the Allow-list.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [124](../../../tasks/124-allowlist-self-package-investigation.md) | Code-complete + device smoke ✅ | Own app in the Allow-list via start parameters, not in the config; Allow only |
| 2 | [119](../../../tasks/119-default-network-not-vpn.md) | Code-complete (no device repro) | The default network for core traffic must not be its own tunnel |
| 3 | [324](../../../tasks/324-saved-vs-running-canonical-diff.md) | ✅ Implemented (DEVICE-PENDING) | The comparison with the running core repeats self-appending |
