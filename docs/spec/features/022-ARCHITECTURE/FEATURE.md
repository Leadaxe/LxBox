[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Architecture — code layers, domain facades and structural audits

LxBox keeps each behaviour in one place: the code is split into four layers, every domain exposes one facade,
and data has one source of truth. The app grows task by task, and every task has its own local "quicker to
put it here"; the rules on this page counter that, and audits find structural debt before it turns into a
class of bugs. Unlike the product features, this page makes no promises to the user: it lists the rules that
keep the product cheap to change and a registry of checks of those rules.

| Field | Value |
|------|----------|
| Feature | 022-ARCHITECTURE |
| Type | Process feature (ongoing work on the structure of the code) |
| Absorbed | `§291F` |
| Sources | [ARCHITECTURE.md](../../../ARCHITECTURE.md) (the principles; the source tree is not carried over), [DEVELOPMENT_GUIDE.md](../../../DEVELOPMENT_GUIDE.md), `AGENTS.md` |
| State | ✅ written from code, 2026-09-29 · living registry |

## Principles it protects

| # | Rule | What breaks without it | Origin |
|---|---------|-----------------------|--------|
| A1 | **Four layers with one-directional dependencies:** UI → State → Services → Platform. No logic in building a screen; the UI reaches the platform only through the state layer | UI code starts making decisions that the Debug API and automation need too — and they diverge | ARCHITECTURE "The layers" |
| A2 | **The facade invariant.** A domain exposes a facade and does not know its consumers (its signatures carry no Debug context, widgets or intents). Adapters — Debug HTTP, Automation, UI — know the transport and the security, but not what they grant access to. An operation is declared once, and adapters reduce to calling the facade | four entry points (UI / Debug / backup / build) reinvent one check, and one of the copies lags behind | §291 |
| A3 | **Strangler-fig, not big-bang.** The new structure goes in behind the old behaviour one domain at a time; the app stays releasable at every step | an "all at once" refactor blocks releases and hides regressions | §291 |
| A4 | **Cohesion over line count.** The goal is one responsibility and cohesion, not a line count; 600 cohesive lines are legitimate. Large code is split within the same library or by extracting subtrees | splitting for the metric scatters one contract across files | §089 |
| A5 | **No monsters.** A god object (a screen or controller that owns everything) is split by responsibility | any edit touches everything, tests do not isolate | §089, §085 |
| A6 | **A structural refactor is zero behaviour change**; a deliberate behaviour change is a separate class of work with its own candidate registry | "incidental" behaviour changes without a spec | §089 / §090 |
| A7 | **Structure instead of reverse parsing.** A node's metadata (tag, type, section, detour, transport and security labels) is parsed from the config once into a model; membership of a subscription is a prefix filter over the tag; the display tag is never parsed back | a whole class of "the UI parses its own display tag" bugs | §091 (closed §077/§079/§080) |
| A8 | **Two channels of differing reliability — do not mix them.** The tunnel status comes over a reliable native channel and survives the death of the UI; screen data (groups, nodes, connections, traffic) comes over ephemeral core subscriptions bound to the UI. Three sync points: going to the background, returning, a cold start of the UI (reset of native subscriptions) | "Connected, but the list is empty after a swipe" | ARCHITECTURE "The invariant", §163, §185 |
| A9 | **Defaults live in the template**, not in code; user values go on top, in storage | two sources of a default diverge | DEVELOPMENT_GUIDE |
| A10 | **Offline-first:** the config is built from cache without the network; config building never downloads subscriptions | tunnel start depends on the network | DEVELOPMENT_GUIDE |
| A11 | **English is the only source language of the UI**; others are translations; a literal in a display position fails the checker | strings without a key do not get translated | DEVELOPMENT_GUIDE, §285 |
| A12 | **Every reference to an outbound exists:** every new path that emits an outbound, a group or a reference is checked against the config-assembly layer of the guard registry — the core fails at start on a dangling reference and names the referrer, not the culprit | the whole config is dead because of one node | DEVELOPMENT_GUIDE "Critical risks", `GUARDS.md` |

## The process around the code

- **Spec first.** Before code — a task in `docs/spec/tasks/`; a change of a
  feature's behaviour edits its `FEATURE.md` and adds itself to the revisions.
- **Commits are atomic**, to `develop`, `git add` only of your own files;
  force-push, `main`, tags and outward publications — only on the operator's
  explicit command.
- **Lazy reading (owner's decision 2026-09-24).** Do not read files whole when
  `grep`/`sed -n` is enough; docs — only by a link from the task; heavy things
  (tests, checkers, builds) — not for what CI will check; cap the output. A long
  test run is always a brief for a cheap sub-agent, and only the summary enters
  context (status, failures with file and line, the first stack). Decisions
  belong to the reasoning model, output triage to the cheap one.
- **The full test suite runs only on CI**; locally — `flutter analyze` over the
  whole project and the task's own tests (see
  [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.md)).
- `AGENTS.md` is only a router of links; new rules go to the relevant document.

## Audit registry

The common method of the later audits: a multi-agent pass over axes/areas →
**adversarial verification of every finding by reading the code** → a
prioritised registry → remediation in separate commits.

| Date | Audit | Scope | What was found | Outcome |
|------|-------|-------|-----------|------|
| 2026-04-20 | [008](../../tasks/008-deep-code-review-perf-refactor.md) | hot modules: home screen, controllers, subscriptions | perf/simplification/refactor candidates | Done (report) |
| 2026-05-09 | [049](../../tasks/049-singbox-wrapper-deep-audit/spec.md) | the native core wrapper against the reference implementation of the same libbox version | F1–F26; the main one — unsynchronised mutation of the tunnel descriptor | phases A/B done, native service split (F1) |
| 2026-06-08 | [084](../../tasks/084-code-audit-cleanup.md) | 13 areas, 46 agents | 28 confirmed (6 high, 22 medium), 62 low, 5 refuted | ✅ high and medium closed, low — as the occasion arises |
| 2026-06-08 | [085](../../tasks/085-architecture-roadmap.md) | 7 architecture slices, 28 agents | god objects of the home screen and the main controller; roadmap R1–R4 | ✅ executed |
| 2026-06-08 | [089](../../tasks/089-deep-refactor-no-monsters.md) · [090](../../tasks/090-logic-rewrite-architecture.md) · [091](../../tasks/091-config-node-model.md) | all code, native side, ARCHITECTURE.md | monsters; behavioural refactor candidates; reverse parsing of the tag | 089 DONE · 090 partial · 091 implemented |
| 2026-06-16 | [141](../../tasks/141-deep-code-audit-hardening.md) | stability · refactoring · energy | 64 confirmed (26 / 22 / 16), 20 discarded; ceiling — medium | In progress (P0 and most of P1–P3 done) |
| 2026-06-22 | [155](../../tasks/155-audit-2026-06-quick-wins.md) | Dart, native, docs, tests/CI | quick wins | In progress |
| 2026-07-02 | [219](../../tasks/219-deep-audit-2026-07.md) | 69 units (16 shards × 4 dimensions + 5 doc auditors) | 352 claimed → 190 confirmed + 96 partial, 66 refuted | audit Done, findings in progress |
| 2026-07-15 | [273](../../tasks/273-energy-audit-client.md) | client energy audit, 5 axes | 6 findings on the config-generator axis | partial (4 axes not run) |
| 2026-07-20 | [291F](../../tasks/291F-layered-architecture-facades/spec.md) | domain health map | worst — DNS (raw lists, dual-write); VPN mode and probe without a facade | ✅ mostly achieved |
| 2026-09-28 | [588](../../tasks/588-spec-kit-revision-audit.md) | every feature of the catalogue, code and tests against the legacy `F` specs | ~200 code-vs-spec mismatches, ~25 promises without a witness | Open — waiting for the owner's triage |

The sibling cycle in the core is the audit of the fork's delta (SPEC 022
LX_DEEP_AUDIT in sing-box-lx); its findings on the client boundary are
tracked by [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md).

## State of the facade invariant (§291)

| Domain | State |
|-------|-----------|
| Channels / detour / balancing, subscriptions and servers, runtime (VPN, ping, live state) | reference shapes — do not touch |
| Routing rules, WARP, backup, automation, native settings | clean |
| Template / variables / config generation | the core is unified, seams at the edges |
| DNS | model and facade introduced (294, 300); dual-write in the screens — open (295, needs a device) |
| VPN mode / tun / app settings | facade created, not all entry points wired (293) |
| Probe | a shared controller over server lists (296) |
| onChange cascade | dedup done, "non-UI writers" open (297) |
| Folder member identifier | deferred as RISKY (299) |

## Revision tasks

| # | Revision | Status | Gist |
|---|---------|--------|------|
| 1 | [085](../../tasks/085-architecture-roadmap.md) | ✅ | roadmap of layers and abstractions |
| 2 | [089](../../tasks/089-deep-refactor-no-monsters.md) | DONE | "remove the monsters", cohesion over line count |
| 3 | [090](../../tasks/090-logic-rewrite-architecture.md) | partial | deliberate behaviour changes — a separate registry |
| 4 | [091](../../tasks/091-config-node-model.md) | IMPLEMENTED | a node model instead of reverse parsing the tag |
| 5 | [163](../../tasks/163-home-screen-data-model-refactor.md) | Implemented | three home-screen data channels after CommandClient |
| 6 | [291F](../../tasks/291F-layered-architecture-facades/spec.md) | ✅ mostly | the facade invariant, strangler plan 292–299 |
| 7 | [293](../../tasks/293-vpn-settings-facade.md) | partial | VPN settings facade |
| 8 | [300](../../tasks/300-dns-controller-facade.md) | D1+D3 | DNS controller on the probe reference shape |

## Watch for

- **Services import screens.** The chains handler in the Debug API takes
  validation and hop candidates from the chain editor screen's folder; the DNS
  controller takes the resolver from the DNS screen's folder (the debt is
  recorded in §300). This violates A1.
- **The "documented large exceptions" table in ARCHITECTURE.md is stale:** the
  traffic profiler shrank (≈870 lines), the custom rule model and the native
  bridge grew (≈1230 and ≈1560). There are 24 files over 1000 lines; the
  largest — backup (≈4500), the parse engine interpreter (≈4150), the
  subscription controller (≈3580) — are not in the table.
- **The §291 invariant tests were not found.** The promised boundary tests
  ("an adapter does not import another adapter") are absent from the tests;
  only the `@visibleForTesting` guard on raw mutators holds.
- **ARCHITECTURE.md is 2100+ lines with a source tree** that drifts with every
  file move; the principles from it are carried over here.
- The 293 / 295 / 297 tails do not reopen the umbrella, but are not closed either.

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the template as the source of defaults, building without the network.
- [005-DNS](../005-DNS/FEATURE.md) — the worst domain of the §291 map, typed model and facade.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the reliable tunnel status channel.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the ephemeral screen data channel.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md), [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — external adapters (Debug API, Intent API) on top of facades.
- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — English as the UI source language.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the boundary with the core and the contract, the core audit.
- [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.md) — where the rules are checked automatically (analyze, checkers, tests on CI).

## Maintenance notes

- An audit goes stale: the registry describes the code as of the pass. A repeat
  cycle makes sense after large layer moves or a core change.
- Without adversarial verification the registry fills up with plausible false
  findings (219: 66 of 352) — and trust in it disappears.
- A reference shape instead of a rule: when a domain is brought to the invariant,
  first look for a reference that already works (probe, subscriptions,
  channels) and copy its shape.
