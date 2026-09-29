[English](source-detour-policy.md) · [Русский](source-detour-policy.ru.md)

# Source detour and jump servers

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P2 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Sets with a single decision how all nodes of a subscription or folder go
out: through the provider's native detour chains (jump servers), through an
outbound chosen by the user on top of them or instead of them, or directly.
It also decides link visibility: by default jump servers work only as hops
and do not get into node selection.

## Parameters

The subscription/folder settings tab, the **Detour servers** block (present
when there are native chains or personal detours of folder members):

| Mode | Storage | What is in the config |
|---|---|---|
| Use subscription detour servers / Use servers' own detours | use=on, no override | the native chain as is |
| Add detour → Outbound + **Fill missing** | use=on, override, replace=off | node → native chain → override as the tail; without a chain — node → override |
| Add detour → Outbound + **Replace all** | use=on, override, replace=on | native chain discarded, node → override |
| Don't use detour servers | use=off | `detour` removed, override ignored |

The "Add detour" caption reflects the choice: "Append an outbound to the end
of the chain" / "Fill missing → X" / "Replace all → X".

With Use and Fill missing — toggles (stored independently of the mode):

| Knob | Default | Effect |
|---|---|---|
| Register detour servers | off | links get into Direction selectors (visible in the node list) |
| Register detour in auto group | off | links get into `<tag>-auto` |

A source without native chains shows a single **Detour server** row ("None —
nodes connect directly" or `Phone → X → Nodes → Internet`) — the same
override, append mode on an empty chain.

## Inputs / Outputs

**Inputs:** source nodes with native links (Xray `dialerProxy`, sing-box
`detour`), the policy, the chosen reference.
**Outputs:** `detour` on nodes and on the last link; links as separate
outbounds; the membership of selectors and `<tag>-auto`.

## Rules and invariants

- "Don't use" wins over the override (P2).
- A jump server's name is the link's own tag from the provider config with
  the source prefix, without decorations; links are made unique by the
  shared tag allocator.
- An Xray `dialerProxy` link may itself go through the next one; service
  `freedom`/`blackhole`/`dns` are never links; an invalid link in the middle
  brings down its owner — a truncated path is not built.
- A node whose tag starts with `⚙ ` and a folder member that another
  member's personal detour points to behave as a link: into node selection
  and auto-select — only via the register toggles.
- Folder: a member's personal detour is kept with Use and Fill missing; with
  Replace all it is overridden by the folder's. If the folder override
  points to its own member X, X and everything reachable from it via
  personal detours behave as Use — otherwise the path would loop onto X.
- Auto-select nodes and nodes that cannot be an exit (Tailscale without an
  exit node) do not go into the Direction pool under any policy.
- An unresolved override — see P1 in [node-detour.md](node-detour.md).

## Boundaries

- "Hide detour servers / Show only detour servers" on the main screen (a
  link = a node someone references as a detour) —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Parsing `dialerProxy`/`detour` from a subscription — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).
- A subscription has no personal detour of an individual node — only a
  standalone server and a folder member do.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Policy in 026 | Subscription detour policy, jump servers |
| 2 | [073](../../../tasks/073-detour-append-vs-replace.md) | Released v1.9.0 | Append (default) vs Replace |
| 3 | [079](../../../tasks/079-detour-prefix-aware-tag-detection.md) | ✅ Implemented | The link marker is recognized after the source prefix too |
| 4 | [093](../../../tasks/093-detour-by-isdetour.md) | Done | A link is determined by actual references, ⚙ is visual only; register policies kept |
| 5 | [096](../../../tasks/096-unified-negate-toggle.md) | DONE | Three-position detour filter on the main screen |
| 6 | [111](../../../tasks/111-subscription-detour-without-native-chain.md) | Done | Detour for a subscription without native chains |
| 7 | [239](../../../tasks/239-folder-detour-symmetry.md) | implemented | Folder symmetric to subscription: intra-chains, exempt |
| 8 | [245](../../../tasks/245-detour-mode-wording.md) | implemented | "Replace all" / "Fill missing" instead of a toggle |
| 9 | [404](../../../tasks/404-dialer-proxy-signature.md) | Code ready | Link name is the provider's tag, without `⚙` |
| 10 | [488](../../../tasks/488-xray-dialer-proxy-freedom-fragment.md) | Released v2.25.0 | `dialerProxy` to freedom — end of the chain |
