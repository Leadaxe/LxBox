# Guards — the sanitiser registry

Every place where LxBox **drops, normalises, defaults, degrades or rejects**
a value so that the sing-box core does not fail, panic, or go silently dead.

This file is the single registry. It was written by walking the code, not from
memory; each row carries `file:line` so a reader can check the claim. Where the
purpose of a guard could not be established from the code, the row says so
instead of guessing.

Related: [`PROTOCOLS.md`](PROTOCOLS.md) (what each protocol's fields mean),
[`ARCHITECTURE.md`](ARCHITECTURE.md) (where the parser and builder sit in the
pipeline), [`spec/features/026 parser v2/spec.md`](spec/features/026%20parser%20v2/spec.md)
(the parser's original design).

## Why this exists

sing-box validates a config **as a whole**. A single unusable field in a single
node of a single subscription is frequently not a per-node failure but a fatal
one for the entire file:

```
initialize outbound[3]: create client transport: xhttp: v2ray-xhttp:
uplink_data_placement can be header only in packet-up mode
```

The user experience of that is "the VPN does not start", with no indication
which of their several hundred subscription nodes is at fault — or that a node
is at fault at all. Guards exist so that provider data cannot take the whole
config down.

## Contents

- [Principles](#principles)
- [Where guards live](#where-guards-live)
- [The guard over the guards — no field falls out of the round trip (§476)](#the-guard-over-the-guards--no-field-falls-out-of-the-round-trip-476)
- [The last echelon — the core's own verdict (feature 478)](#the-last-echelon--the-cores-own-verdict-feature-478)
- [How a user finds out](#how-a-user-finds-out)
- [Layer 1 — URI parsing](#layer-1--uri-parsing)
- [Layer 2 — JSON branches](#layer-2--json-branches)
- [Layer 3 — node emission](#layer-3--node-emission)
- [Layer 4 — config assembly](#layer-4--config-assembly)
- [Known asymmetries and gaps](#known-asymmetries-and-gaps)

## Principles

**1. Drop, do not silently fit (§169).** When a value is unusable, discard it.
Do not trim, pad or coerce it into a shape the core will accept — that produces
a *valid config with the wrong meaning*, which is worse than a rejected one.
A REALITY `short_id` truncated to an even length is a valid short id belonging
to somebody else; the server compares it byte for byte and the node dies
quietly. Dropping it leaves an empty short id, which is legal.

**2. Fail closed against a whole-config fatal.** The unit of damage decides the
response. If the core rejects one outbound, passthrough is fine — let the core
judge it. If the core rejects the entire file, the app must intervene, because
one node from a provider would otherwise cost the user every node.
`XhttpTransport` shows both policies side by side: `session_placement` and
`uplink_http_method` pass through untouched (the core's problem), while
`uplink_data_placement: header` is guarded (§416 — the whole config's problem).

**3. Changed behaviour must be visible.** If a guard alters what the source
asked for, the user gets a warning. The anti-pattern (§277/§278) is a guard
that only fires on a code path nobody watches. Two deliberate exceptions:
canonicalising a synonym is not a degradation (uTLS xray aliases, §281), and
neither is a value whose absence and whose "none" mean the same thing
(`packetEncoding=none`).

**4. Never quietly widen the user's exposure.** A guard may not replace a
declared relay with a direct connection. §404 rejects an Xray node whose
`dialerProxy` is unusable *in full*, rather than emit it with a direct path:
the provider wrapped the dial in a relay on purpose, and quietly unwrapping it
routes traffic where the user did not agree to send it. The mirror case in the
sing-box branch (§368) drops only the chain, because there `detour` is optional
decoration rather than the point of the node.

**5. Degrade one element, do not fail the build.** A broken rule, member or
node is dropped so the rest of the config survives. The exception is DNS groups
(§312): an emptied group blocks the build with a fatal issue rather than
degrade, deliberately, so the user resolves it instead of silently losing
resolution.

**6. Fail open only when guessing is worse.** Two documented cases: an
unparsable core version is treated as *supporting* chains (§393 C5 — degrading
on a guess costs the user a working route, and a config the core rejects at
least produces a visible error), and a node pulled out of a group keeps its
`detour` (§393 A4 rule 4).

## Where guards live

Four layers, in pipeline order. A guard belongs at the **narrowest point every
source branch must pass through**. Putting the §416 check in the URI parser
would have missed sing-box JSON, Xray JSON and the manual editor; putting it in
`XhttpTransport.toSingbox` catches all four, because every branch builds that
object before emitting.

| Layer | Code | What it guards |
|---|---|---|
| 1 — URI parsing | `app/lib/services/parser/uri_parsers/**`, `uri_utils.dart`, `transport.dart`, `utls_fingerprint.dart`, `hysteria2_obfs.dart`, `ini_parser.dart`, `amnezia_link.dart`, `body_decoder.dart` | One link from a subscription body |
| 2 — JSON branches | `app/lib/services/parser/singbox_config.dart`, `json_parsers.dart` | Imported sing-box and Xray configs |
| 3 — node emission | `app/lib/models/transport_spec.dart`, `tls_spec.dart`, `node_spec_emit.dart`, `node_spec.dart` | The node → outbound JSON step, common to all sources |
| 4 — config assembly | `app/lib/services/builder/**`, incl. `post_steps/**` and `validator.dart` | The whole file: graph, groups, rules, DNS |

## The guard over the guards — no field falls out of the round trip (§476)

Layers 1–4 answer "is this value usable". A different defect hides under them:
a field that is perfectly usable and simply **never read**.

`parseSingboxEntry` reads the body key by key, by hand. A key nobody wrote a
line for disappears without a sound — no warning, no log, no dropped node — and
the emitter happily writes it back out for the fields it *does* know. The user
sees it as: typed the field into the JSON tab, pressed Save, and the node went
to the core without it. Over a single day of spec 472 this bit `encryption`
(vless), `plugin`/`plugin_opts` (shadowsocks), `quic` (naive),
`host_key_algorithms` (ssh) and `min_idle_session` (anytls) — every one of them
found by accident, while doing something else. Issue #140 (`tls.certificate`)
was the same defect a month earlier.

The launcher cannot have this class at all: its body travels as a map through
the registry, and no list of readable keys exists. Ours is the list —
`parseSingboxEntry` itself — so its completeness needs a watchdog.

`test/contract/body_fields_roundtrip_test.dart` builds, for every protocol the
app models, bodies in which **every** field of the registry schema is filled
(`body_field_generator.dart`, values derived from the schema: `values`,
`format`, `min`/`max`, `len`, nested objects, the shared `tls`/`transport`/
`multiplex`/dialer blocks). Mutually exclusive fields — `conflicts`, `requires`,
transport variants, `reality` against `ech` — get several bodies per protocol,
and coverage is itself asserted: a field that lands in no body fails the test.
Each body then goes round the same path the pipeline uses — registry sanitiser,
`parseSingboxEntry`, `emit()` — and the result is compared with the body as the
sanitiser left it.

Two properties make it a guard rather than a fixture:

- values come **from the schema**, so a field added by a contract bump enters
  the bodies the day the contract arrives, instead of ageing out of a
  hand-written sample;
- an expression the generator cannot build a value for **fails the test by
  name** rather than being skipped. The sanitiser does the opposite with an
  unknown expression (leaves the value alone — 24.1, the registry running ahead
  of the code is a working state); the difference is deliberate: production has
  to survive a contract bump, the watchdog has to notice one.

What is deliberately outside the round trip lives in one list, `kNotModelled`,
`"scheme.path" → reason`. An entry with no reason fails; an entry that has
become **stale** — the field now survives the trip — fails too, so the list
cannot quietly outlive the defect it described. Three kinds of entry: keys the
app sets itself (`detour`, `domain_resolver`), core features the app does not
model at all on either side (multiplex, UDP-over-TCP, the QUIC tuning knobs —
absent from the model *and* the emitter, so nothing is being lost), and fields
waiting on another task (wireguard and masque → step 7 of spec 472).
`socks.version` was the third kind until §475 read it in the socks branch; the
entry had to go the moment the field survived the trip, which is the guard
working as designed.

Nodes with `origin.kind: json` are out of scope by construction: they go to the
core **verbatim**, never through the model (§455), so they have nothing to lose.

## Guards over the engine itself (feature 480)

Once the mapper became a registry interpreter, a new class of defect appeared:
the engine is right, the table is right, and the two have silently drifted
apart. These four guards watch the seam, and all of them are cheap tests, not
runtime checks — a drift caught after shipping is a whole scheme read wrong.

| Guard | What it fixes in place | Where |
|---|---|---|
| **identity snapshot** | The identity hash of every corpus node, recorded **before** the engine existed. Identity is the key a stored node is found by, so a shifted hash is not a cosmetic diff: the node detaches from its folder, its position and its overrides. The snapshot is never rewritten to match new output — a diff here is a question to answer, not an expectation to update | `test/fixtures/parser/pipeline_identity_before.json` |
| **link shape** | The text of every link the emitter produces, snapshotted the same way. The emitter and the parser now read one table, and a change meant for the parsing direction silently rewrites what "Copy link" puts on the clipboard | `test/fixtures/parser/emit_before480.json` |
| **full copies of drafts** | An overlay **replaces** a registry entry, it does not merge fields into it. So an overlay carrying a lone `emit_as` would drop that entry's `source` and kill it. The guard requires every overlay entry to be a complete copy of the registry entry plus the deviation, and every deviation to carry a `_why` — an unexplained divergence can neither be lifted nor handed to the launcher | `test/contract/mapper_sections_draft_test.dart` |
| **no scheme names in the engine** | Greps `lib/services/parser/engine/` for protocol names, **comments included**. The whole point is one engine for every scheme; the first `if (scheme == …)` is the end of it, and a name in a comment is how that starts — it documents a special case that the next reader then implements | `test/parser/engine_no_scheme_names_test.dart` |

## The last echelon — the core's own verdict (feature 478)

Layers 1–4 cover what the app knows about. Feature 478 covers the rest: when
the core refuses to start and names a node, that node is switched off with the
same switch a person uses, the core's own text is stored next to the off-mark as
a `core_rejected` warning record, and the start is retried. Duplicating the
core's grammars in the app is the alternative and a dead end — a copy has to be
re-checked at every bump, and a copy that fell behind rejects good nodes. So the
cheap registry checks stay the first echelon and the core's verdict is the
second, on everything nobody anticipated.

Nothing here normalises a value. The unit of action is a whole node, the
judgement is the core's, and the app's only decisions are *which* node the
error names and *when to stop asking*.

| Invariant | Why it has to hold | Where |
|---|---|---|
| The stored verdict is **authoritative** — it is the one warning the app persists, and the parse-time recompute of derived codes must not erase it. Every other `NodeWarning` is computed on parse and never stored; `core_rejected` is the opposite, and a sanitiser that rebuilds a node's warning list from scratch would silently drop the only record saying *why* the node is off | Without the record a disabled node is indistinguishable from one a person disabled by hand, and the two have opposite rules: the person's choice is never touched, the app's is cleared the moment the body changes. Losing the record means either re-enabling what the core refuses (a start failure the user cannot explain) or leaving a fixed node off forever | `models/core_reject_verdict.dart` (`upsertVerdict` replaces by code and puts the verdict first), `controllers/subscription_controller/core_reject_ops.dart` |
| The automaton acts **only on a matched tag**. `parseCoreRejection` returns a node only when the tag it cut out is present in the tags of the config that was just built; nothing is guessed by index, by position or by elimination | The core's index is diagnostic (CANON §9.1) and the tag can itself contain `]` and `: `, so no cut of the string is unambiguous. Acting on an unmatched candidate would switch off a node the core never complained about — and the user's own server rather than the provider's broken one | `services/core_reject/core_error_parse.dart`, tags from `BuildResult.nodeByEmittedTag` (CANON §9.3) |
| The **same tag named twice ends the loop**. A round that has nothing left to switch off — error not about a node, tag unmatched, tag already seen, node not switchable — breaks out (CANON §9.5) | The loop is finite by construction only because every round removes one node. A tag named twice means the removal did not take, and without the break the app would check, rebuild and check again forever, with the Start button spinning and no VPN | `services/core_reject/core_reject_guard.dart` (`_seenTags`, `_consume` → `null`) |
| **Exactly two real core starts per press of Start** — the signalling one and the final one; everything in between is `Libbox.checkConfig` with no tunnel and no service | A real start raises a tunnel and a foreground service; a loop of them would flap the VPN state, and the kill-switch / lockdown decisions hang off that state. A rare error that `check` passes and `run` catches switches its node off but gets no third start: the next press of Start begins afresh and gets further | `services/core_reject/core_reject_guard.dart` (`realStart` twice, `check` in the loop), `HomeController.startAndAwaitVerdict` |
| `warnings` stays **symmetric between the codec allowlist and the backup slice table** (§221) | A key in the record but not in the slice table travels to storage and is lost on backup; the reverse produces an export the import drops as unknown. The key stays in the slice so old files that still carry `core_rejected` are not flagged unknown; sanitisation (`core_reject_backup.dart`, §489) strips the insurance verdict and the disable it caused — a diagnostic cache is not a user setting | `models/codec/source_record.dart` (`_subscriptionKeys`, `_serverKeys`, `_memberKeys`) ↔ `services/lx_backup_slice.dart` (three `BackupField(..., 'warnings', _c)` rows) + `services/core_reject/core_reject_backup.dart` |
| The verdict is cleared by **exactly two events** — the node's body changed, or a person switched the node on. A core update clears nothing | Any third clearing rule is a guess about the core's opinion made without asking the core. A body comparison is a fact the app has in hand; "the core was updated, maybe it accepts it now" is not, and re-enabling a whole subscription on a bump would hand the user a failed start instead of a working VPN (owner's decision — the toggle is the manual mechanism) | `core_reject_ops.dart` (`canonicalNodeBody`, `refreshSubscriptionVerdicts`), `SubscriptionController.enableNodeByCoreTag` |

## How a user finds out

Four channels, and they are not interchangeable.

| Channel | Type | Surface | Notes |
|---|---|---|---|
| `NodeWarning` | sealed subclass, `models/node_warning.dart` | Inline line under the node in the subscription screen, coloured by `severity` (`node_warning_row.dart`). Colour and icon per level come from one place — `warningSeverityStyle` in `widgets/banner_palette.dart` (§471): `error` red (`colorScheme.error`, `error_outline`), `warning` amber (`warning_amber`), `info` blue (`info_outline`). In the node list only `error`/`warning` get text; `info` is the icon alone — next to the node's name when the node has nothing else, otherwise before the level icon in the warning line — and the "+N more" counter ignores it | Deduped by type + data, not by rendered text (§279). Reaches `emitWarnings` as `'<tag>: <renderEn()>'` (`build_config.dart:282-285`) |
| `emitWarnings` | `List<String>`, EN text, `BuildResult` | SnackBar (§105) + AppLog | Builder-layer channel. Free text, mostly without machine codes — the chain degradations are the exception (`chain_unsupported_by_core`, `chain_invalid`, `chain_hop_missing`, `chain_nested_position`, `chain_cycle_through_direction`) |
| `ValidationIssue` | sealed, `models/validation.dart`, all `Severity.fatal` | Blocks the build: `FatalValidationException`, config is neither saved nor sent to the core (§141 P0.1) | Last line of defence, not the first — the graph sanitiser unties what it can *before* this |
| `StoredWarning` with `core_rejected` | `models/core_reject_verdict.dart`, `code` + `params` | The same inline line and Notifications sheet as a `NodeWarning` (`RegistryWarning`, texts from the registry), plus a "N servers disabled" banner on the main screen with a **Show** list | The only warning the app **persists** — every other one is computed on parse. It rides next to the node's off-mark and is what tells "the app switched this off" from "a person did" (feature 478) |

`NodeWarning` subclasses also carry machine codes for the shared contract
(`app/contract/registry/warnings.json`), mapped by runtime type in
`test/contract/contract_test.dart:87`.

## Layer 1 — URI parsing

### 1.0 Schemes that no longer have layer-1 value rules (spec 472)

`trojan` (step 2), `vless` (step 3), `vmess` and `shadowsocks` (step 4),
`hysteria2` and `tuic` (step 5, the scheme alias `hy2://` included) and
`anytls`, `naive` (both `naive+https://` and `naive+quic://`), the
`http(s)` proxy (`proxy-http(s)://` and the `proxy+…` forms), `socks`
(all four of `socks://`, `socks5://`, `socks4://`, `socks4a://` — §475) and
`ssh` (step 6) reach the model through
the unified pipeline — mapper → registry sanitiser → `parseSingboxEntry` — so
the value rules listed in §§1.1–1.5 below **no longer run for them**.
Three of the step-6 schemes — naive, socks and ssh — had **no** layer-1 value
rule to begin with: their dialects carry nothing to judge (naive has two query
parameters and both are structural, socks has none, and every ssh body field is
a plain `string`/`listable_string`). They moved for the single source of rules,
not for new codes. The rules themselves did not disappear: the same judgement is
now made once, by the registry, for every input the node can arrive through.
What the mapper still does is translate the *spelling* (aliases, uTLS hello
names, `?ed=N` in the path, `flow=xtls-rprx-vision-udp443` splitting into two
fields, base64 containers, `plugin=name;opts` splitting into two body fields) —
translation is not judgement, and the registry writes it down in its `mapper`
section.

**Inputs that are not links are on the same pipeline.** `wireguard`/AWG arrives
as a link, as `wg-quick` INI text and inside an `amnezia://` container (step 7),
and **Xray JSON** as an object (step 8) — all reach the model the same way, so
the Xray rows of §2.2 that used to judge values are gone from the code too. The
mapper differs per input only in how it *reads* the source; what it produces is
one sing-box map, and the judge after it is the same. The sanitiser is told the
input (`BodySource`), and every mapper-built map counts as `other`, never
`singbox`: the one rule that asks (`except_sources` on the AWG `mtu` ceiling,
§473) exempts a body **written in the core's own form** by the person or the
subscription, not one this app assembled.

| Rule, as §§1.2–1.5 describe it | Registry field that judges it now | Code |
|---|---|---|
| `fp` outside the dictionary → `chrome` | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce` | `utls_fp_unknown` |
| REALITY + fingerprint without the hybrid key share | `tls.json` → `utls.fingerprint`, `advisory` with `except` | `reality_fp_not_chrome` |
| `pbk` not a 32-byte X25519 key → no REALITY block | `tls.json` → `reality.public_key`, `format: base64_32` | `reality_pbk_invalid` |
| `pbk` written in **std** base64 (`+`, `/`, `=`) | *spelling*, not judgement — `normalizeRealityPublicKey` (`uri_utils.dart:413`) beside the block gate, the same place `short_id` is normalised. The registry's `format: base64_32` accepts both alphabets and has no paired `normalize`, and the sanitiser only knows the reverse move (`base64_std`) | silent — the same key, byte for byte |
| `sid` non-hex / odd / over 16 | `tls.json` → `reality.short_id`, `format: hex`, `normalize: hex_only` | `reality_short_id_invalid` |
| `key_share` outside the enum | `tls.json` → `reality.key_share`, enum + `normalize: trim_lower` | `reality_key_share_invalid` |
| VLESS `flow` outside `{"", vision}` | `protocols/vless.json` → `flow`, enum + `on_invalid: drop` | `flow_deprecated` |
| VLESS `packetEncoding` outside the core's set | `protocols/vless.json` → `packet_encoding`, enum + `on_invalid: drop` | `packet_encoding_unknown` |
| VLESS `encryption` outside the shape → **node dropped** | `protocols/vless.json` → `encryption`, `normalize: trim` + `absent_values: ["none"]` + `pattern` + `on_invalid: drop_node` (§477) | `vless_encryption_invalid` |
| Transport path with broken percent-encoding | `transports.json` → `path`, `format: url_path` | `type_invalid` |
| XHTTP `mode` / `session_placement` outside the enum | `transports.json` → `xhttp.*`, enum + `on_invalid: drop` | `xhttp_param_reset` |
| Shadowsocks method outside the core's eighteen → **node dropped** | `protocols/shadowsocks.json` → `method`, enum + `on_invalid: drop_node` | `ss_method_invalid` |
| Shadowsocks stream cipher (the nine shadowstream ones) | `protocols/shadowsocks.json` → `method`, `advisory` (D-122) | `ss_method_legacy` |
| uTLS / REALITY block on a QUIC scheme — **stripped by the emitter before, judged now** | `tls.json` → `utls` / `reality`, `forbidden_for` + `forbidden_codes` | `tls_not_applicable_quic`, one per block |
| Hysteria2 `obfs` type outside `{salamander, gecko}` | `protocols/hysteria2.json` → `obfs.type`, enum + `on_invalid: drop` | `obfs_unknown` |
| Hysteria2 `obfs` without a password → **the obfs block goes, the node lives** | `protocols/hysteria2.json` → `obfs.password`, `required` with its own `code` | `obfs_password_missing` |
| Hysteria2 gecko packet sizes on a non-gecko obfs | `protocols/hysteria2.json` → `obfs.{min,max}_packet_size`, `requires` with `equals` | `field_requires` |
| TUIC `congestion_control` outside `{cubic, new_reno, bbr}` | `protocols/tuic.json` → `congestion_control`, enum + `on_invalid: drop` | `tuic_congestion_invalid` |
| TUIC `udp_relay_mode` outside `{native, quic}` | `protocols/tuic.json` → `udp_relay_mode`, enum + `on_invalid: drop` | `tuic_udp_relay_mode_invalid` |
| TUIC `uuid` not in UUID form → **node dropped** | `protocols/tuic.json` → `uuid`, `format: uuid` + `required` | `type_invalid` |
| AnyTLS `min_idle_session` not a non-negative integer | `protocols/anytls.json` → `min_idle_session`, `min: 0` + `on_invalid: drop` | `anytls_min_idle_invalid` |

Every one of those codes now carries a `path` and the value **as the link's
author wrote it** — the pipeline's sanitiser sees the raw map, before any
normalisation.

### Where `on_invalid: drop_node` is actually enforced (§477)

`drop_node` means the core would refuse to start on the **whole** config, so the
record must never reach it. Three inputs, three enforcers, and the node goes at
the earliest one that sees it:

| Input | Who drops it | How |
|---|---|---|
| Link (any pipeline scheme) | the pipeline itself | `RegistrySanitizer` returns `body == null`, and `_runPipeline` returns `null` — no node is built at all (`mappers/uri_pipeline.dart`) |
| sing-box body (JSON tab, subscription, pasted object) | `parseAll` | the pass over the **verbatim** map (`annotateFromRawBody`, §455) returns the verdict; `parseAll` removes the node from the list and puts the reason into `dropped[]` with the record's tag as `ref` (D-088) |
| Xray JSON | **parse time**, since spec 472 step 8 | the mapper builds the sing-box map this input never had, the sanitiser judges it, and `drop_node` removes the node from the list with the reason in `dropped[]` — the same moment as for a link or a sing-box body. Until step 8 such a node got the code from the second pass (over `emit()`) but **stayed in the list** as a working one, and only `applyRegistryGate` stripped it right before the config went to the core |
| Node with `origin.kind: json` (verbatim, §455) | the build gate | such a node bypasses the model entirely, so the gate is the only thing between it and the core — `applyRegistryGate` puts the record into `report.dropped` and `dropRegistryEntries` takes it out of the config |

The parse-time drop is deliberately narrower than "the sanitiser returned
`null`": only an **explicit** `on_invalid: { action: drop_node }` removes a node
there. A record can also lose its body by missing a required field, and such a
node has always been shown in the list and stripped only at build time — pulling
it at parse time would silently change a whole class of nodes
(`SanitizeResult.explicitDropNode`).

Three value rules used to stay hand-written, each a request to the launcher.
**All three are gone** — the launcher answered with contracts 1.1.6 and 1.1.7
(spec [§474](spec/tasks/474-contract-116-conflicts-declarant-advisory-bool-dialer.md)):

| Rule that was hand-written | Registry field that judges it now | Code |
|---|---|---|
| VLESS `flow=xtls-rprx-vision` with a live transport → `flow` dropped | `protocols/vless.json` → `flow.conflicts` with its own code | `vision_with_transport` (info) |
| `tls.insecure: true` → certificate checking is off | `tls.json` → `insecure`, `advisory` on the value `true` | `tls_insecure` (info) |
| VMess `scy` outside the core's enum → folded to `auto` **silently** | `protocols/vmess.json` → `security`, enum + `on_invalid: coerce auto` | `vmess_security_unknown` (warning) |

Two of those needed the contract to change, not just the client.
`conflicts` turned out to drop the **declarant** — the field the rule is
written on — and to look for the neighbour in the **original** body as well,
which is why `flow` (order 3) sees `transport` (order 9) at all; this file's
own reading of "the younger field by `body.order`" was wrong, and so was the
sanitiser's. And `advisory` learned to accept booleans, so a `bool` field can
carry a code on the value `true`.

`vmess.security` was the last `on_invalid: coerce` in the registry still
carrying the generic `type_invalid`, whose text describes a field being
*removed*. Coercion does not remove the field, it **replaces** it — the node
travels on a different cipher than the subscription asked for — so the code is
now its own, and the substitution is no longer silent on any pipeline input.
A registry linter keeps the boundary: `coerce` with `type_invalid` fails the
test.

One hand-written funnel is left on purpose, and it is not on the pipeline:
`normalizeVmessSecurity` (`uri_utils.dart`) still folds `security` for the
**sing-box JSON and Xray JSON** inputs. Those do not pass a body through the
sanitiser (`annotateAllWithRegistry` judges the model's assembled `emit()`),
so removing it today would put a cipher the core rejects into the model —
`aes-128-ctr` is fatal for the whole config — without producing a code either.
It goes when the JSON input moves to the pipeline (spec 472, step 8).

Shadowsocks is the first scheme with **no** hand-written value rule left at
all: both of its judgements — the eighteen-method allowlist and the nine
legacy stream ciphers — are registry fields.

The remaining nine schemes still run every rule below.

### 1.1 Shared helpers (`uri_utils.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| URI longer than 65536 (except `vpn://`) | node rejected | `uri_too_long` in `dropped[]`, with the length and the limit (§506; silent before) | `uri_utils.dart:9` (`maxURILength`), applied `uri_parsers.dart:70` | base64 bomb guard | §506 |
| `vpn://` longer than 524288 | rejected (`DecodeFailure`) | silent | `uri_utils.dart:24`, `amnezia_link.dart:24` | under the common cap such a link was silently lost while desktop accepted it | §103 §9.B12 |
| WG key (private/public/psk) not exactly 32 bytes after lenient base64 | **node rejected** | silent | `uri_utils.dart:127-131` | garbage like Proton's `*****` or `publickey=enabled` otherwise reaches `sing-box check` and fails the whole file | D-023/D-030 |
| Key in a non-canonical base64 form (`…ccC=` vs `…ccA=`) | normalised to canonical std-base64 | silent | `uri_utils.dart:130` | same 32 bytes, different text → two identity hashes for one node | D-030 |
| Dart's strict base64 rejects non-canonical padding bits | manual lenient decoder instead of `dart:convert` | silent | `uri_utils.dart:79-114` | matching core behaviour instead of over-rejecting valid keys | D-030 |
| `reserved` not 3 parts / outside 0..255 / not 3 bytes | value dropped | silent | `uri_utils.dart:138-156` | degrade to "no reserved" | §025 |
| Control characters in display strings | stripped (`<0x1F`, `0x7F`, keeping `\t\n\r`) | silent | `uri_utils.dart:164-175` | display sanitation | — |
| Trailing CRLF in the fragment (chat copy-paste) | sanitise, then trim edges only | silent | `uri_utils.dart:193-200` | mirrors Go's label pipeline | §103 |
| `packetEncoding` empty or `none` | field dropped, **no warning** | silent (deliberate) | `uri_utils.dart:259` | xray subscriptions write `none` meaning "unset"; semantically identical to omitted | — |
| `packetEncoding` outside `{xudp, packetaddr}` | field dropped | `PacketEncodingUnknownWarning` | `uri_utils.dart:253-266` | unknown value **panics** the core in `format.ToString` — a native `libbox.so` crash, not a failed connection | SPEC 103 |
| `packetEncoding` upper-case | lower-cased | silent | `uri_utils.dart:258` | core accepts lowercase only | — |
| AWG `mtu` above 1280 (link / `.conf` / Amnezia export) | clamped to the registry ceiling (1280) | `awg_mtu_clamped` (warning), carrying the original value | *moved to the registry, §1.0* — `wireguard.body.fields.mtu.max_when`, executed by `body_sanitizer.dart` `_applyMaxWhen`. The hand-written trio `awgClampMtu` / `awgMtuByRegistry` / `awgMtuWarnings` is **gone** | too high is a silent failure: handshake succeeds, data does not flow. Two cases the sanitiser cannot reach are covered by the pipeline itself (`mappers/uri_pipeline.dart`): a node that **asked** for AmneziaWG but kept no valid AWG field (§463 — `when.any_set` judges keys in the body, and none are left), and a **registry that failed to load** (`kAwgMtuFallback`) | §473 (contract 1.1.5), §472 step 7, was §097 |
| AWG `mtu` above 1280 **from a sing-box body** | **kept as written** | `awg_mtu_high` (info) | `body_sanitizer.dart` `_applyMaxWhen` (`except_sources: [singbox]`) | the body is in the core's own form, written by the user or the subscription; rewriting it silently is not ours to do (owner's decision 18.09.2026). Input parity is broken here deliberately — the only such place in the contract | §473 |
| AWG `mtu` absent | default 1280, on every input including sing-box bodies | silent — a default is not a replacement | `body_sanitizer.dart` (`default_when.when.any_set`) | AmneziaWG's own recommended client MTU and the IPv6 minimum | §473, §472 step 7, was §097 |
| Bare IP without CIDR in `address` / `allowed_ips` | `/32` or `/128` appended | silent | `uri_utils.dart:288-292` | breaks endpoint load: `netip.ParsePrefix(...): no '/'` | §106 |
| Raw `/` inside a base64 key in userInfo | percent-encoded to `%2F`, userInfo only | silent | `uri_utils.dart:298-309` | `Uri.tryParse` would read it as the start of the path and lose the userInfo | §106 |
| REALITY `pbk` not 32-byte X25519 | REALITY block not created, node degrades to plain TLS | silent | `uri_utils.dart:335-340`, applied `transport.dart:472` | a non-X25519 key makes the core reject the **entire** config.json | §169 |
| REALITY `sid` non-hex / odd length / over 16 | value dropped entirely (`''`), case folded | `reality_short_id_invalid` (info) from the registry; the class `RealityShortIdInvalidWarning` is gone (§485) | *moved to the registry, §1.0* — `tls.json` → `body.fields.reality.short_id` (`format: hex`, `max: 16`, `len_parity: even`, `on_invalid: drop`). `normalizeRealityShortId` (`uri_utils.dart:442`) survives only for the Xray-JSON input (`json_parsers.dart:1477`) | decoded as hex into `[8]byte`; any of these is a whole-config fatal. Trimming would yield a valid id belonging to someone else | §343/§169 |
| `sid` normalisation differs from `lower(trim(raw))` | detection only — the code is set when `normalize` changes the value | `reality_short_id_invalid` | `tls.json` → `body.fields.reality.short_id` (`normalize: hex_only` + `normalize_code`); the hand-written predicate `realityShortIdWouldDegrade` (`uri_utils.dart:463`) has no callers left in `lib/` | after normalising, the original value is gone | SPEC 103 |
| Duration given as a bare number (`"30"`) | `s` suffix appended | silent | `uri_utils.dart:385-389` | `badoption.Duration` rejects it with `time: missing unit in duration` and drops the whole config | D-024 |
| VMess `security` empty / `null` / `undefined` | default `auto` | silent | `uri_utils.dart:394` | — | — |
| VMess `security` outside the 6-value whitelist | replaced with `auto` | silent | `uri_utils.dart:396-407` | normalise to the sing-box vocabulary | — |
| Shadowsocks method outside the 18 core methods | **node rejected** | `ss_method_invalid` in the envelope's `dropped[]` | *moved to the registry, §1.0* — was `uri_utils.dart` `isValidShadowsocksMethod` | an unknown method is a `CreateMethod` error on the whole config | §463 / §24.2 7.10, §472 step 4 |
| Shadowsocks legacy stream cipher (`aes-*-ctr`, `aes-*-cfb`, `rc4-md5`, `chacha20-ietf`, `xchacha20`) | **accepted** — node lives | `ss_method_legacy` (info) | *moved to the registry, §1.0* — was `isLegacyShadowsocksMethod` + a hand-written `RegistryWarning` | the core accepts them; both clients used to drop working nodes with no explanation. No AEAD, so the traffic is unauthenticated — the info code says so | §463 / §24.2 7.10, §472 step 4 |
| uTLS fingerprint `hellorandom*` (Xray spelling) | canonicalised to `random` | silent | `utls_fingerprint.dart:101` | the subscription asked for a *random* hello; substituting a fixed `chrome` restored the very signature it was avoiding | §463 / §24.2 7.1 |
| Transport `path` with broken percent-encoding (`%zz`) | field dropped, node lives | `RegistryWarning(type_invalid, path=transport.path)` | predicate `uri_utils.dart:410`, guard `transport.dart:156`, applied at `transport.dart:29, 50, 89, 103, 119` | the core parses the path with `url.Parse`; a bad escape is a fatal for the **whole** config.json, not one node | §463 / §24.6 |
| TUIC `udp_relay_mode` outside `{native, quic}` | field dropped | `RegistryWarning(tuic_udp_relay_mode_invalid)` | *moved to the registry, §1.0* — `protocols/tuic.json` → `udp_relay_mode`, enum + `on_invalid: drop` (spec 472 step 5) | coercing to `native` hid the loss of the subscription's intent; core lx.6 rejects the junk outright | §463 / §24.2 7.8 |
| anytls SNI without `.` or `:` (`🔒`) | replaced with the server address | silent | `contract_draft/uri/anytls.json` → `mappers.uri.params.sni` (`on_invalid: default_from`) — **our overlay** on top of `registry/tls.json` → `blocks.uri.sni`, which carries only the source chain; the mapper rule is named `sni_heuristic_falls_back_to_server` | `sing-box check` passes and the handshake is dead — the server gets an SNI it does not know | §463 / §24.2 7.5, §472 step 6 |
| AWG `jmin` without `jmax` | `jmin` dropped (registry `requires`) | `RegistryWarning(awg_header_invalid, path=jmin)` | registry `protocols/wireguard.json` → `body.fields.jmin` (`requires: [{path: jmax, code: awg_header_invalid}]`); Dart mirror `Awg.applyJunkSizeRequires` (`node_spec.dart:1007`), called from `Awg.fromJson` (`:1060`) | a missing `jmax` reads as 0 and the core fails the whole config with `jmin (50) must be <= jmax (0)` | §463 / §24.6 |
| All AWG fields removed by guards | node still counts as AmneziaWG (MTU clamp kept) | silent | registry `protocols/wireguard.json` → `body.fields.mtu` (`default_when` / `max_when` judge the kind by `source_kind: awg\|awg3`, which travels with the body — contract 1.1.22); fallback with no registry loaded — `mappers/uri_pipeline.dart` (ceiling `kAwgMtuFallback`, `contract/registry.dart`) | the link asked for AWG; otherwise dropping the last field silently restored plain-WireGuard MTU | §463 |
| naive with an empty host | **node rejected** | silent | `registry/protocols/naive.json` → `body.fields.server` (`field_missing`); the `mappers.uri.params.server` record deliberately declares no `required`, so the verdict comes from the sanitiser | the core rejects an empty server address fatally for the whole config, so one such node left the user with no VPN at all | §463 / §24.6 |
| Xray transport `splithttp` | treated as `xhttp` (alias; `splithttpSettings` read too) | silent | `transport.dart:129`, `json_parsers.dart:979, 1595` | unrecognised, the node reached the config with **no transport** — plain TCP to an HTTP port, dead without a message | §463 / §24.2 7.13 |
| Empty `reality.short_id` | key omitted from the body | silent | `tls_spec.dart:264-271` | equivalent to the core's own `omitempty`; writing `""` diverged from the launcher for nothing | §463 / §24.6 |
| `insecure` in any of its link spellings (`allowInsecure`, `allow_insecure`, `skip-cert-verify`, …) | normalised to bool, value kept | `tls_insecure` (info) from the registry; the class `InsecureTlsWarning` is gone (§485) | `tls.json` → `blocks.uri.insecure` (eight spellings in `source`, `type: bool_spelled`) and `body.fields.insecure` (`advisory` on `true`) | — | §474, §485 |
| Label contains `🇪🇳` | replaced with `🇬🇧` | silent | `uri_utils.dart:181` | **purpose unclear** — the comment says "leftover artefact from v1" and does not name a core error or observable behaviour | — |

### 1.2 uTLS fingerprint (`utls_fingerprint.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `fp` outside `kUtlsFingerprints` (15 values) and not an xray alias | replaced with `chrome` | `UnknownFingerprintWarning` | `utls_fingerprint.dart:63`, added `:79` | the core matches fingerprints strictly and case-sensitively; an unknown one is a whole-config fatal at start. One bad node takes the VPN down | §281 |
| `fp` is a known xray alias (`hellochrome_120`, …), 9 prefixes | canonicalised **silently** | silent (deliberate) | `utls_fingerprint.dart:41-51, 60-62` | a synonym is not a degradation (principle 3) | §281 |
| `fp` in any case / with spaces | `trim().toLowerCase()` | silent | `utls_fingerprint.dart:57` | Xray accepts any case | §281 |
| `fp` empty while `reality != null` | default `chrome` | silent | `utls_fingerprint.dart:78` | REALITY requires a uTLS block ("uTLS is required by reality client" — fatal on outbound creation), and an empty fingerprint emits no block | §281 |
| `reality != null` and `fp` outside the chrome family (`firefox`, `safari`, `randomized`, …; `random` excluded) | **none** — the value stays in the node and in the config | `RealityFingerprintWarning` (`reality_fp_not_chrome`) | `utls_fingerprint.dart:110-113` | Xray servers since v26.9.8 reject a ClientHello without the `X25519MLKEM768` key share, which only the chrome family carries; the warning suggests `chrome`. The node's fingerprint comes from the subscription and goes into the config as is — the app does not rewrite the source's choice. 2.23.2 replaced it with `chrome` at build time (D-104); dropped in 2.24.0. `random` gets no warning: the parser's default for an empty `fp` cannot be told apart from an explicit one | §444 (D-119) |

### 1.3 Hysteria2 obfuscation (`hysteria2_obfs.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| obfs type outside `{salamander, gecko}` | obfs dropped whole (type and password) | `UnknownObfsWarning` | `hysteria2_obfs.dart:38-41` | `Hysteria2Obfs.MarshalJSON` returns "unknown obfs type" — the config will not assemble at all | §358 |
| Valid type, empty password | obfs dropped whole | `MissingObfsPasswordWarning` | `hysteria2_obfs.dart:42-45` | "missing obfs password" is fatal on outbound creation | §358 |
| Type in another case / with spaces | `trim().toLowerCase()` | silent | `hysteria2_obfs.dart:36` | — | §358 |

### 1.4 Transport and TLS from the query (`transport.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Xray tail `?ed=N` in a ws path | tail cut, `ed` moved to `max_early_data` | `ws_early_data_converted` (info, text from the registry) | `transport.dart:47, 73-75` | left in place the core sends the tail to the server as part of the path and gets a 404 — and `sing-box check` passes | §303 |
| `?ed=N` on httpupgrade | tail cut, `ed` **discarded** | silent | `transport.dart:109-117` | httpupgrade has no early data; leaving the tail gives a 404 | §303/§320 |
| `?ed=` on xhttp | tail cut, value discarded | silent | `transport.dart:216-226` | xhttp has no early data | §303 |
| Broken percent-encoding in the tail (`splitQueryString` throws) | exception swallowed → "no ed"; path still cleaned | silent | `transport.dart:152-159` | the path must be cleaned regardless | §303 |
| `eh` without `ed` | `eh` dropped | silent | `transport.dart:56` | the core enables early data on `max_early_data > 0`; a header name without a size means nothing | §320 |
| Doubly percent-encoded path (`/%2Fassignment`) | extra decode, **capped at 2 passes** | silent | `transport.dart:172-182` | `Uri.queryParameters` decodes once, so the server receives the wrong path and 404s. More than two passes is almost certainly garbage | §320 |
| ALPN multiply percent-encoded | unwound to a fixed point, **capped at 16 passes** | silent | `transport.dart:586-607` | leftover `%XX` went into `tls.alpn` verbatim; the cap guards against pathological input | §151 F2 |
| ALPN element still contains `%` / space / control after unwinding | element dropped from the list | silent | `transport.dart:603` | not a valid protocol id | §151 F2 |
| `ech=<name>+<resolver>` present and not `none` | **not applied at all** (the URI parameter only — `tls.ech{}` from JSON does pass, see 2.1) | `ech_ignored` (info, text from the registry) | `transport.dart:443-447` | the Xray-form parameter carries no key, only a name for a DNS query: subscriptions put public ECH probes there (`ip.gs`), whose keys do not belong to this server — the handshake breaks and the core has no fallback. Device-verified: with `ech` dead, without it 723 ms | §320, §459 (contract §24.2 item 7.2) |
| `echfq` | never read | silent | `transport.dart:441-442` | the paired core option is legacy, removed in sing-box 1.13.0, and drops the config when true | §320 |
| XHTTP `extra` broken / not an object | ignored whole; node lives on flat params | silent | `transport.dart:355-365` | — | §399 |
| `extra` contains `host` / `path` / `mode` | values from `extra` **discarded**; only flat params read | silent | `transport.dart:319, 370-371` | device-verified: `extra.path = "/"` made the server answer 404 on uplink while the flat `/hls/…` worked. Deliberate divergence from the Go reference | §410 |
| `extra` holds an empty string for a key | empty does **not** override the flat value | silent | `transport.dart:383, 389-391` | otherwise `mode` disappears, the core defaults to `auto`, and a node with `uplinkDataPlacement=header` drops the whole config | §410 |
| `extra` holds an array or nested object (except `xmux`) | discarded | silent | `transport.dart:302-313` | — | §399 |
| Number like `1000000.0` in an XHTTP scalar | normalised to `"1000000"` | silent | `transport.dart:401-407` | the core cannot parse exponential notation | §399 |
| XHTTP int field non-numeric or absent | `-1` ("unset"), key not emitted | silent | `transport.dart:279-287` | zero is a meaningful value for these fields, not emptiness | §127 |
| `type=h2` in a VLESS/Trojan query | transport not created | silent | `transport.dart:100` | Go does not recognise bare `type=h2` there either | SPEC 103 |
| gRPC `serviceName` in the Xray absolute-path form `/<service>/Tun` | **nothing — the value is stored and emitted verbatim**, leading `/` included | silent | `transport.dart:86-93` (URI), `json_parsers.dart:967-972` (Xray JSON) | core `v1.14.1-lx.8` (fork SPEC 093) reads the leading `/` itself: segments are escaped one by one, the last one names the stream, a `\|…` tail is dropped, so `/a/b/Tun` reaches the wire unchanged. §464 used to translate `/<service>/Tun` → `<service>` for a core without that parsing; the rule fixed only the single-segment form and would now strip a `/` the core expects, so contract 1.1.3 removed it on both sides. **Normative for the lx.8 pin and newer** — rolling the core back means bringing the translation back | §468 (supersedes §464, issue #130) |
| Unknown `type` | transport not created, node survives | silent | `transport.dart:129-135` | — | — |
| httpupgrade / xhttp `host` empty | **no fallback to sni** (unlike ws) | silent | `transport.dart:118-121, 228-231` | the fallback produced different configs and identity hashes for an empty host | §103 D-016 |
| No `path` key at all (ws/httpupgrade/xhttp) | path stays `''`, `/` **not** substituted | silent | `transport.dart:45-48, 114-117, 224-226` | only an explicit `path=` reaches the config | SPEC 103 CANON §2.4 |
| VLESS `sec` empty and port in `{80, 8080, 8880, 2052, …}` | TLS disabled by port whitelist | silent | `transport.dart:502`, list `uri_utils.dart:427` | ports that normally carry plain HTTP | — |
| `key_share=` in any case / with spaces (`Hybrid`, ` classical `) | `trim().toLowerCase()`, then the enum | silent | *moved to the registry, §1.0* — the mapper record (`registry/tls.json` → `blocks.uri_reality.key_share`) copies the value verbatim into `tls.reality.key_share`, and `tls.json` normalises it (`normalize: trim_lower`) before the enum; spec 472 steps 3 and 6 removed the hand-written `realityKeyShareFromQuery` from the link path | the core is case-sensitive, but the value comes from the subscription — a case difference is the source's intent, not garbage, and used to be lost silently | §459 (contract §24.2 item 7.12) |
| `key_share=` outside `{hybrid, classical}` after normalisation (a number, an empty value) | field dropped, the node lives | `reality_key_share_invalid` from the registry, with path and value | *moved to the registry, §1.0* — `tls.json` → `reality.key_share`, enum (see the row at §1.0 above). Read only together with a `pbk` that builds the REALITY block: without that block there is nowhere to put it | the core answers an unknown value with `unknown reality key_share` and refuses the outbound — and with it the whole config | §457, §459 |
| `pbk=` present but not 32 bytes after base64 decode (`enabled`, `true`) | REALITY block **not built**, node degrades to plain TLS | `RegistryWarning` `reality_pbk_invalid` | `transport.dart:530-543`, gate `uri_utils.dart` `isValidRealityPublicKey` | the gate is old (§169 — a non-X25519 key is `invalid public_key`, a fatal on the whole config); what §464 adds is the **code**. The URI branch used to degrade silently while the JSON import reported it, so one node arriving two ways carried two different code sets | §464 (contract §24.7 item 5, DRIFT §2(b2)) |

### 1.5 Per-protocol URI parsers

Rejection of a node for a missing host, empty userinfo, empty password or
unparsable key is the common case, and after §480 no scheme states it in code
any more: the rule is the `required` flag on a record of the scheme's own
registry section (`registry/protocols/<scheme>.json` → `mappers.uri.params`) —
`server` everywhere, plus `uuid` for vmess/tuic, `method`+`password` for
shadowsocks, `user` for ssh, `password` for anytls,
`private_key`/`publickey`/`address` for masque and wireguard. A record that
finds no value answers `null`, exactly as the old parser did. The `*_parser.dart`
files under `uri_parsers/` are now only the entry points that name the pipeline
table — they carry no checks of their own. Port defaults (443 / 1080 / 22 /
51820) are likewise the section's `defaults` / `default_when`, all silent. The
rows below are the guards that do something more than reject or default.

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| VLESS `flow=xtls-rprx-vision` with any transport | flow suppressed (`''`) | `vision_with_transport` from the registry, with path and value | *moved to the registry, §1.0* — `protocols/vless.json` → `flow`, `conflicts` with its own code (spec 472 steps 3 and 8); the hand-written `VisionWithTransportWarning` is **gone entirely** — step 9 removed the class once the Xray input, its last producer, moved to the pipeline | vision is valid only on bare TLS; with ws/grpc/xhttp the core will not bring the config up. The link is the source of truth — not guessed from REALITY | §115, §472 step 9 |
| VLESS `flow=xtls-rprx-vision-udp443` | replaced with `xtls-rprx-vision` + `packetEncoding=xudp`; **the node's port is not touched** | silent | `registry/protocols/vless.json` → `mappers.uri.params.flow` (`value_map` + `sets: {packet_encoding: xudp}`) | v1 quirk. The port is a property of the node: rewriting it to 443 (as the Xray-JSON branch used to) made a `…:8443` node unreachable | §459 (contract §24.2 item 7.4) |
| VLESS `encryption` (post-quantum) | edges trimmed, `none` / empty → no key; otherwise only the **shape** is checked (`mlkem768x25519plus` plus at least three non-empty dot-separated parts), a mismatch rejects the node | `vless_encryption_invalid` in `dropped[]`, with the raw value | `registry/protocols/vless.json` → `body.fields.encryption` (`pattern`, `on_invalid: drop_node`) and `mappers.uri.params.encryption` | the full grammar is deliberately not duplicated (owner's decision 18.09.2026): a copy would drift from the core on the next pin bump; anything finer than the shape is caught by the core-reject guard (feature 478). Silently dropping the layer would be a silent downgrade of protection, hence `drop_node` | §335 |
| VMess body not base64 / empty / no `add` or `id` | node rejected | silent | `registry/protocols/vmess.json` → `mappers.uri.forms` (the `base64`+`json` decoder chain) and `params.server` / `.uuid` (`required`) | — | §472 step 4 |
| VMess malformed UTF-8 | `utf8Lossy` (`allowMalformed`) | silent | the engine's `base64` decoder (`engine/decoders.dart`), invoked by `registry/protocols/vmess.json` → `mappers.uri.forms[].decode` | — | §472 step 4 |
| VMess `scy` outside the core's enum (`aes-128-ctr`, garbage) | coerced to `auto`, value kept in the warning | `vmess_security_unknown` (warning) — the node travels on a cipher the server picks, not the one the subscription asked for | *moved to the registry, §1.0* — `protocols/vmess.json` → `security`, enum + `on_invalid: coerce auto`. Since spec 472 step 8 the Xray input is on the registry too; still hand-written for the **sing-box JSON** input (`uri_utils.dart` `normalizeVmessSecurity`, called from `parseSingboxEntry`), which does not pass a body through the sanitiser | `sing-vmess@v0.2.8` `client.go:42-54` accepts exactly `auto, none, zero, aes-128-cfb, aes-128-gcm, chacha20-poly1305` and answers anything else with `ErrUnsupportedSecurityType` — a fatal on the **whole** config. Before §459 `aes-128-ctr` was let through (unknown to the core) and a working `aes-128-cfb` collapsed into `auto`; before §474 the substitution was silent on the URI and Xray inputs and only the body input reported it, as `type_invalid` | §459 (contract §24.2 item 7.11), §474 (contract 1.1.7) |
| VMess `scy` empty / `null` / `undefined`, or `chacha20-ietf-poly1305` | `auto` substituted / translated to `chacha20-poly1305`; the `security` key is always written | silent — "not set" is not the author's choice, and an alias is spelling, not judgement | `registry/protocols/vmess.json` → `mappers.uri.params.security` (`value_map` + `materialize_default` + `emit_when: always`) | the core's field has no `omitempty` and the schema marks it `required`, while a registry `default` does not materialise into the body — an omitted key would drop the node with `field_missing` | §474 (contract 1.1.7 §24.16) |
| SSH empty elements in `host_key` / `host_key_algorithms` | dropped from the list | silent | `registry/protocols/ssh.json` → `mappers.uri.params.host_key` / `.host_key_algorithms` (`list.sep: ","`, `normalize: trim`) | — | §472 step 6 |
| Bare `http(s)://` as a proxy link | only the custom schemes `proxy-http(s)` / `proxy+http(s)` accepted | silent | `registry/protocols/http.json` → `mappers.uri.detect.scheme_in` plus `scheme_sets` (the TLS discriminator and the default port), entry point `http_parser.dart` | plain URLs are caught earlier as subscriptions; promo links inside bodies would otherwise become "nodes". The `https` suffix is also the TLS discriminator: `-http`/`+http` produces a body with **no** `tls` key at all (an explicit `enabled:false` crashed cores lx.5–lx.18, SPEC 045) and port 80, `-https`/`+https` a TLS block and port 443 | §222/§268, §472 step 6 |
| Hysteria2 multi-port authority (`host:443,20000-30000`) | authority rebuilt on the first numeric port, rest → `server_ports` | silent | `registry/protocols/hysteria2.json` → `mappers.uri.params.$multiport` (`extract` over `port_raw`, `prepend_group`), merged with the `mport` record (spec 480; was a hand-written mapper, before that `hysteria2_parser.dart`) | Dart's `Uri.parse` cannot digest `,`/`-` in the port position | §103 §9.B2 |
| Hysteria2 first port outside 1..65535 | rebuild abandoned → node rejected | silent | `registry/protocols/hysteria2.json` → `mappers.uri.params.$multiport`, then `body.fields.server_port` | — | §103 §9.B2 |
| Hysteria2 empty password | node **survives**, password simply not emitted | silent (deliberate) | `registry/protocols/hysteria2.json` → `mappers.uri.userinfo` (`single_into: password`, no `required` on the record) | Go requires non-empty userinfo only for vless/trojan/ssh/tuic/anytls | §103 |
| Hysteria2 `sni` empty, `== '🔒'`, or without `.` and `:` | replaced with the server | silent | `registry/protocols/hysteria2.json` → `mappers.uri.params.sni`, `on_invalid: default_from` with `not_matches: "[.:]"` — the second half of the rule `sni_heuristic_falls_back_to_server`, declared per scheme because trojan/vless/vmess deliberately do **not** apply it | "this is not a domain name" heuristic. The `'🔒'` literal is **unexplained in the code** — purpose unclear | — |
| Hysteria2 `up_mbps` / `down_mbps` in the URI | **read as aliases** of `upmbps` / `downmbps` (emission still writes `upmbps`) | silent | `registry/protocols/hysteria2.json` → `mappers.uri.params.upmbps` / `.downmbps`, both spellings in `source` | W2d made both spellings registry aliases (`hysteria2.json uri.query.upmbps.aliases`) and the launcher now accepts both. Until §464 a link carrying `up_mbps=` lost its bandwidth silently | §464 (contract §24.7 item 4) |
| Hysteria2 `obfs-min-packet-size` / `obfs-max-packet-size` with `obfs` other than `gecko` | field dropped | `RegistryWarning` `field_requires` | *moved to the registry, §1.0* — `protocols/hysteria2.json` → `obfs.{min,max}_packet_size`, `requires` with `equals: gecko` | the sizes are gecko-only (registry `requires` + `equals`). The emitter already skipped them for salamander, but silently — the same node arriving as a body got a code from the sanitiser | §464 (contract §24.7) |
| Hysteria2 `fp` / `pbk`+`sid` in the URI | **the mapper puts both blocks in the raw map like any other scheme**; the sanitiser removes them, so neither reaches the model | `RegistryWarning(tls_not_applicable_quic)`, severity `info`, one per block (`tls.utls`, `tls.reality`) | *moved to the registry, §1.0* — `tls.json` → `forbidden_for` + `forbidden_codes`, executed by `body_sanitizer.dart`. The hand-written `forbiddenTlsBlockWarnings` pass is **gone from this path** | uTLS and REALITY do not exist over QUIC (the core builds its TLS through `STDConfig()`, which neither provides), so the strip is right — but until 1.1.4 it was silent and the user never learned `fp=` had no effect. Until spec 472 step 5 the code had to be set by the parser, because the emitter (`toSingboxForQuic`) stripped the blocks before the sanitiser ever saw them; on the pipeline the sanitiser sees the raw map and judges them itself. The node's body is unchanged — the blocks were never in it | §469 / contract 1.1.4, §472 step 5 |
| TUIC `fp` in the URI | the mapper puts the block in the raw map; the sanitiser removes it | `RegistryWarning(tls_not_applicable_quic)` on `tls.utls` | *moved to the registry, §1.0* — same route as hysteria2 (spec 472 step 5); the hand-written pass is gone from this path | before 1.1.4 `fp` on tuic was not read at all ("uTLS does not apply to QUIC") and a subscription's fingerprint vanished without a word. An unrecognised value is printed **as it arrived**, not as the `chrome` the normaliser would substitute: `value` is the original before degradation. No `utls_fp_unknown` here — a fingerprint that never applies cannot be unknown to the core | §469 / contract 1.1.4 |
| TUIC `congestion_control` outside `{bbr, cubic, new_reno}` | field cleared, core default applies | `tuic_congestion_invalid` **with a path and the author's value** | *moved to the registry, §1.0* — `protocols/tuic.json` → `congestion_control`, enum + `on_invalid: drop` (spec 472 step 5); the hand-written `TuicCongestionInvalidWarning` is **gone entirely** — step 9 removed the class, it had no producers left in `lib/` | a broken value must not smuggle a pseudo-explicit `cubic` into the config | SPEC 103 |
| TUIC `congestion_control` empty | key not written at all | silent (deliberate) | `registry/protocols/tuic.json` → `mappers.uri.params.congestion_control` (no default, so an absent key writes nothing) | "unset" is not a degradation | SPEC 103 |
| TUIC `alpn` absent | empty list; `h3` **not** substituted | silent | `registry/tls.json` → `blocks.uri.alpn` (included by `tuic.json` as `tls#uri`) — the record has no default, so an absent `alpn` writes nothing | `h3` is a protocol default, not our value; substituting changes the identity hash | §103 D-016 |
| TUIC empty password (`uuid:@host` or `uuid@host`) | node **survives**, `password: ""` in the body as before | `password_empty` (warning) on `password` — the node carries no credentials and the user is told so | `assets/contract_draft/uri/tuic.json` → `mappers.uri.params.password`, `on_empty: {code}`. An overlay while the code is still missing from `warnings.json`: the launcher keeps the case open (Q133-67) and is adding the code as a **shared** one. `on_empty` is a general primitive — it judges a value's *presence*, which no type check catches, and unlike `required` the node lives | owner decision 19.09.2026. TUIC v5's token is a TLS exporter and the password travels as *context*; an empty context the exporter does not reject, so the connection can work. Rejecting would throw away live nodes, silence would hide the missing credentials. The rule lives on the **source**, not the body: both spellings give the same body (`password: ""`) and a body rule could not tell "no password given" from "password deliberately empty" | §480 delta480-7 / contract §24.2 |
| AnyTLS `security` in the query | removed before TLS parsing | silent | `registry/protocols/anytls.json` → `mappers.uri.params.security` — a `selector` with `priority: 10` and `merge: overwrite`, which overrides the same-named record of `tls#uri` and keeps `tls.enabled` in every branch | AnyTLS is always over TLS (`anytls.json` → `body.fields.tls` → `required`, the core answers `C.ErrTLSRequired`); `security=none` would zero the whole TLS block and take `sni`/`alpn`/`insecure` with it. The registry lists anytls under `security_none_no_tls`, so the divergence is named in `mapper_rules_coverage_test` as `security_none_no_tls@anytls` | §269, §472 step 6 |
| AnyTLS `min_idle_session` not a non-negative integer | field dropped | `RegistryWarning(anytls_min_idle_invalid)` with path and the author's value | *moved to the registry, §1.0* — `protocols/anytls.json` → `min_idle_session`, `min: 0` + `on_invalid: drop` (spec 472 step 6); was `AnyTlsMinIdleInvalidWarning`, a code with neither path nor value — step 9 removed that class entirely, it had no producers left in `lib/` | core default applies, node lives. The hard cast that read this field on the body input used to throw on any non-numeric value and the node vanished whole and silently — fixed with the shared `_asInt` | SPEC 103, §472 step 6 |
| AnyTLS / TUIC durations as bare numbers | `s` suffix appended | silent | the registry, and on the **body**, not in the mapper: `anytls.json` / `tuic.json` → `body.fields.<field>` with `normalize: duration_bare_seconds` — a value rule has to hold on every input, not only on a link (mapper rule `heartbeat_bare_number` in `tuic.json` → `mapper` records why) | whole-config fatal otherwise | D-024 |
| Naive `padding` parameter | discarded | `naive_padding_ignored` (info, text from the registry) | `registry/protocols/naive.json` → `mappers.uri.params.padding` (`maps_to: null`, `on_present: drop` with the code `naive_padding_ignored`) | no sing-box equivalent; previously log-only, so the user never learned their parameter was dropped. The code is set by the **mapper**, not the sanitiser: the body never carries the key, so there is nothing for the sanitiser to judge (§482) | SPEC 103, §472 step 6 |
| Naive TLS block | `enabled` + `server_name` only (the URI carries nothing else) | silent | `registry/protocols/naive.json` → `mappers.uri.scheme_sets` (the scheme itself sets `tls.enabled` and `tls.server_name`; mapper rule `tls_block_kept_minimal` in the same file) | naive accepts only `certificate(_path)`/`ech` on top of these; the validator rejects alpn/utls/insecure/reality. The allowlist itself lives in the registry as `forbidden_for: ["naive"]` on seventeen `tls.json` fields with the code `tls_field_unsupported_naive`, and the sanitiser runs it on the **body** input, where such fields actually arrive — the naive URI dialect knows no TLS parameters at all (`naive.json` → `uri.query` lists only `extra-headers` and `padding`) | §281, §454/§270, §472 step 6 |
| Naive extra-header without `:` / empty name / name outside the charset | line discarded, the other headers survive | `naive_extra_headers_invalid` once per node (text from the registry) | `registry/protocols/naive.json` → `mappers.uri.params.extra-headers` — the pair charset is the record's own `extract.re`, the skip is `on_item_invalid` with the code `naive_extra_headers_invalid` (mapper rule `broken_header_pair_skipped` in the same file). The hand-written `naive_parser.dart` `parseNaiveExtraHeaders` survives with no callers in `lib/`, exercised only by `uri_naive_test.dart` | HTTP header-name charset from the DuckSoft de-facto spec | §084 M7, §472 step 6 |
| Naive empty host | node **rejected** by the sanitiser, not the mapper — see the naive row in §1.1 | `field_missing` | `registry/protocols/naive.json` → `mappers.uri.params.server` (no `required` on purpose) and `body.fields.server` | the mapper does not judge it (Go validates a non-empty hostname only for five schemes, naive not among them), the body rule does | §103, §463 |
| naive `quic` / ssh `host_key_algorithms` in a body | **read back into the model** | silent | `json_parsers.dart`, cases `naive` and `ssh` | the emitters write both keys and these branches did not read them, so a `naive+quic://` node re-saved through the JSON tab silently fell back to HTTP/2 and stopped connecting, and an SSH node lost its host-key algorithm list. Same class as `encryption` for vless (step 3) and `plugin` for shadowsocks (step 4). `quic_congestion_control` is deliberately **not** read back: `NaiveSpec` has no such field, the core accepts one value, and the emitter sets it from `quic` | §472 step 6 |
| AnyTLS `min_idle_session` as a string (`"3"`) or garbage in a body | read as a number where it is one, otherwise the field is dropped and the **node lives** | `anytls_min_idle_invalid` from the registry | `json_parsers.dart`, case `anytls` (`_asInt`) | the hard cast `as num?` threw on any non-numeric value, and `parseUri`/`parseSingboxEntry` answer a thrown parse with `null` — the node vanished whole and silently. Aggregators send numbers as strings routinely | §472 step 6 |
| socks `version` in a body | **not read** — the model keeps its default `5` | silent | `json_parsers.dart`, case `socks` | known and deliberate for now: the registry records it as a dead model field (`socks.json` → `uri.userinfo.impl`, "version '4'/'4a' is unreachable by any parse path"). Reading it would be a behaviour change — a body with `version: "4"` would start emitting `4` — and no corpus case asks for it, so it waits on the launcher (spec 472, §12.6) | §472 step 6 |
| MASQUE `vhttp` outside `{h3, h2, auto}` | forced to `h3` | `masque_vhttp_invalid` from the registry, with `path: vhttp` and the value the author wrote | *moved to the registry, §1.0* — `protocols/masque.json` → `body.fields.vhttp`, enum + `on_invalid: coerce h3`. The hand-written `MasqueVhttpInvalidWarning` is **gone entirely** — step 9 removed the class, it had no producers left in `lib/` | mirrors `node_parser_masque.go` | SPEC 103, §472 step 7 |
| MASQUE `vhttp` absent | default `h3`, **no warning** | silent | `registry/protocols/masque.json` → `mappers.uri.params.vhttp` (`default_when` + `materialize_default` + `emit_when: always`; mapper rule `vhttp_empty_defaults_to_h3` in the same file) | "no parameter" and "operator chose auto" are different things. The mapper writes `h3` **explicitly**: the registry's own `default` is `auto`, and a `default` is not materialised into the body at all (CANON §2.4) — relying on it would shift the identity of every live MASQUE node | contract 0.11.1, §472 step 7 |
| MASQUE legacy `network` / `server_name` | not accepted at all | silent | `registry/protocols/masque.json` → `mappers.uri.params.$legacy_flat` (mapper rule `singbox_flat_fields_stripped` in the same file) | operator directive D-078 | §393 |
| AWG `h1`–`h4` not uint32 and not a `lo-hi` range | field cleared | `awg_header_invalid` from the registry, **one per broken header** (§463), with `path` and the value the author wrote | `registry/protocols/wireguard.json` → `body.fields.h1`–`h4`: `type: awg_range`, `normalize: range_order` (a reversed pair is swapped silently) and `on_invalid: drop` with the code `awg_header_invalid`. Contract 1.1.11 closed the request made in spec 472 step 7 — the registry judges these fields itself now, and the hand-written check is gone; `node_spec.dart` `Awg.fromQuery` only collects the raw values. Contract 1.1.33 then took the **text** as well: `AwgHeaderInvalidWarning` and `Awg3FieldInvalidWarning` are gone (§482), the code comes through `RegistryWarning` | the core falls back to the plain WG header and the handshake stops matching the server — a **silently broken** node, hence warning not info | SPEC 103 |
| AWG `jc`/`jmin`/`jmax`/`s1`–`s4` broken | field cleared | `awg_header_invalid` from the registry (`s3`/`s4`: `awg3_field_invalid`), with path and value (silent before §481) | `registry/protocols/wireguard.json` → `body.fields.jc` … `s4` (`type: int`, `min: 0`, `on_invalid: drop`); the mapper keeps the raw value (`on_invalid: keep`) so the sanitiser can judge it | a quiet default does not break the handshake here, but the loss is still named: §481 aligned these fields with `h1`–`h4`, which already carried the code | SPEC 103, §481 (contract 1.1.11) |
| AWG header range reversed (`300-200`) | normalised to `200-300` | silent | `registry/protocols/wireguard.json` → `body.fields.h1`–`h4` (`normalize: range_order`). Not for the AWG 3.x timings: there a reversed pair is a typo and is dropped with `awg3_field_invalid` | the same pair, not another value; without this one node yields two hashes | D-031 |
| AWG `id`/`ip`/`ib` alongside an explicit `i1` | `id`/`ip`/`ib` suppressed | silent | link and `.conf`: `registry/protocols/wireguard.json` → `mappers.uri.params.id` / `ip` / `ib` and `mappers.conf.params.*` (`when: {query.i1 / ini.Interface.I1: {present: false}}`); a sing-box body: `body.fields.i1.conflicts` with `field_conflict` | the core rejects them together with an explicit `i1` | §143 |
| Deeper AWG header validation (uint32 bounds, start ≤ end, non-overlap) | bounds: field dropped; reversed pair: swapped (row above); overlapping `h1`–`h4`: **node rejected** | `awg_header_invalid`; `awg_headers_overlap` in `dropped[]` | `registry/protocols/wireguard.json` → `body.fields.h1`–`h4` (`type: awg_range`) and `body.relations` (`ranges_disjoint`, `drop_node`) | an overlap passes `sing-box check` but fails device configuration and takes the whole config down; the original §112 concern (a silent drop = a silently broken handshake) is answered by naming the code | §112, contract 1.1.11 |
| Plain WG (no AWG) without an explicit `mtu` | `mtu` **not emitted at all** | silent | `registry/protocols/wireguard.json` → `body.fields.mtu`: the registry `default` (1408) is not materialised into the body (CANON §2.4); `default_when` fires only for the AWG kinds | the core sets 1408 itself; our own default fights it and breaks the identity hash | SPEC 103 D-026 |
| WG `preshared_key` (underscored) | **accepted** as an alias of `presharedkey` (Dart only) | silent | `registry/protocols/wireguard.json` → `mappers.uri.params.presharedkey` (`source.url` lists both) and `uri.query.presharedkey.aliases` | Go reads only `presharedkey`; the registry records the alias as Dart-only | D-021 |
| INI bare IPv6 endpoint without brackets | whole endpoint becomes the host, port 51820 | silent | `registry/protocols/wireguard.json` → `mappers.conf.params.endpoint` (`extract` without a match → `on_no_match: take_all`, default port 51820). Open question to the launcher: Q133-61 | the port is genuinely indistinguishable from the address here — a deliberate degradation | §219 |
| Amnezia claimed uncompressed size over 4 MiB | inflate not performed | silent | `amnezia_link.dart:143-152` | decompression-bomb cap | §110 |
| Amnezia container not awg/wireguard | skipped | silent | `amnezia_link.dart:17-18, 41-45` | — | §110 |
| `vpn://` as a single URI with N containers | exactly **one** node (`defaultContainer`, else the first); rest dropped | silent | `amnezia_link.dart:58-104` | mirrors Go | §103 §9.B12 |
| Unknown scheme | line skipped | `protocol_unsupported` in `dropped[]`, the scheme in `value` (§506; silent before). Provider service lines (`incy://`, `happ://`) and lines with no `://` stay silent on purpose | `uri_parsers.dart:142-162` | a lost line must be named; routing lines of provider panels are not nodes, a code on them would be a false alarm | §506 |
| Any exception inside a protocol parser | `null`, line skipped | silent | `uri_parsers.dart:164-165` | structural errors return null rather than throw | — |
| Base64 body: over 20% control bytes, under 16 chars, or no `://`/`{`/`[` after decoding | decode refused or rolled back | silent | `body_decoder.dart:96, 144-169` | probably binary | — |
| Lines starting with `#`, `//`, `;` | skipped (counted in `skippedComments`) | silent | `body_decoder.dart:131-135` | — | §219 |
| TCP keep-alive duration in the query that is not a Go-duration | field dropped, the other two survive | silent (deliberate) | `tcp_keep_alive.dart:18-22` | a bare integer is read as seconds first (D-024); anything still unparseable would make the core's `badoption.Duration` reject the whole config. A new warning type would drag in strings and the l10n gates of three languages for a power-user path (as with hysteria2 obfs, §358) | §453 |

## Layer 2 — JSON branches

### 2.1 sing-box import (`singbox_config.dart`, `parseSingboxEntry`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `type` in `{direct, block, dns}` | service outbound — never becomes a node | silent | `singbox_config.dart:35, 172` | `block`/`dns` were removed in 1.11 but still appear in configs | §368 §3.1 |
| Tag is the target of someone's `detour` | withdrawn from candidates, travels as the owner's hop | silent | `singbox_config.dart:155-162, 178` | — | §368 §4 P1 |
| Tag takes part in a detour **cycle** | edge cut, target **returned** to candidates | owner gets the warning below | `singbox_config.dart:146-162, 313-344` | otherwise the node would land in `detourTargets` and vanish from the list entirely — the silent loss §3.5 exists to prevent | §368 §4 P3 |
| Duplicate tag | first wins; indexed fallback `tag N` for the name | silent | `singbox_config.dart:141-144, 185-189` | the file is written by the provider, and repeats between elements are normal | §368 §3.3 |
| Converter returned `null` (unsupported type) | node skipped, type accumulated | `UnsupportedProtocolWarning` on the config's first node | `singbox_config.dart:205-209` | a config that produced no node at all is lost silently — compensated by the "skipped" counter in the import dialog | §368 §3.5 |
| Detour depth ≥ 8 (`kMaxDetourDepth`) | chain truncated, node lives | `DetourChainTooDeepWarning(8)` | `singbox_config.dart:366-370` | real configs are 2–3 hops; the limit guards against recursion driven by provider data | §368 §4 P2 |
| `detour` closes a cycle | edge broken, node connects directly | `DetourCycleBrokenWarning` | `singbox_config.dart:374-377` | broken rather than fatal (unlike §254) because the cycle arrived in someone else's file — the user did not create it | §368 §4 P3 |
| `detour` target not in the config | chain not built, node lives | `DetourTargetMissingWarning` | `singbox_config.dart:381-384` | drop the unusable part, not the whole (§169) | §368 §4 P4 |
| `detour` points at a group | chain not built | `DetourToGroupWarning` | `singbox_config.dart:388-392` | `getEntries` expands the group into a detour list its members are absent from | §368 §4 P5 |
| `detour: "direct"` | chain not built — **silently** | silent (deliberate) | `singbox_config.dart:393-397` | a common way of saying "go direct"; not an error and not a hop, since a direct exit is not a node here | §368 §4 |
| Exception (TypeError on a garbage field type) inside a converter | node skipped, neighbours survive | `UnsupportedProtocolWarning('malformed')` | `singbox_config.dart:245-251` | "broken forms do not sink the whole parse" at node granularity | §321/§368 |
| Any config field of the wrong type | `is` checks, never casts | silent | `singbox_config.dart:118-127, 158-159` | a cast would sink the parse of the whole subscription | §368 §3.1 |
| `type: selector` (manual choice) | imported as auto-select (`urltest`) | `SelectorAsAutoWarning` (info) | `singbox_config.dart:434` | we have no manual type, and losing a hand-built roster is worse than changing selection mode | §368 §5.1 |
| Group member unresolvable (nested group / service / broken) | member dropped | `GroupMemberMissingWarning(count)` | `singbox_config.dart:450-459` | a group cannot be a pool member | §368 §5.3 |
| Group empty after filtering | group **not created at all** | silent | `singbox_config.dart:460` | an empty `urltest` kills core startup | §368 §5 |
| Sorting more than 32 elements | index added to the comparator | silent | `singbox_config.dart:68-74` | Dart's `List.sort` is stable only up to ~32 | §342 |
| Empty `server` or `server_port == 0` (all protocols) | node rejected | silent | `json_parsers.dart:994, 1013, 1028, …` | — | — |
| Empty `tag` | synthetic `<type>-<server>-<port>` | silent | `json_parsers.dart:998, 1016, …` | LxBox has no nameless nodes — they need identity to be disabled individually | contract 0.10.0 |
| AnyTLS with no/disabled TLS block | minimal `enabled` block substituted | silent | `json_parsers.dart:1042-1047` | AnyTLS is always over TLS | §269 |
| `up_mbps: 100.0` (double, not int) | read as `num` | silent | `json_parsers.dart:1102-1107` | `as int` would sink the whole node via TypeError | §404 |
| `server_ports` mixed array `[443, "20000:30000"]` | element-wise `toString()`, empties dropped | silent | `json_parsers.dart:498-507` | `cast<String>()` throws on read and the node would be lost, though the range parses fine | §404 |
| hysteria2 `obfs` in JSON: type outside `{salamander, gecko}`, or a valid type with no password | obfs dropped whole | `UnknownObfsWarning` / `MissingObfsPasswordWarning` | `json_parsers.dart` `parseSingboxEntry`, case `hysteria2` (`normalizeHysteria2Obfs`). Since spec 472 step 5 this funnel serves the **JSON inputs only** — the URI path leaves the raw `obfs` object to the sanitiser, which judges it by the registry and reports `obfs_unknown` / `obfs_password_missing` with a path and a value. The two funnels meet at step 8 | until §469 this path passed `null` for the accumulator and both codes were swallowed: the same node arriving as a link warned and arriving as a body said nothing, though the body it produced was identical. The launcher had the mirror-image defect (`sanitizeSingboxHysteria2Obfs`, fixed in `371448da`) | §358, §469 item 6 |
| hysteria2/tuic/masque body carrying `tls.utls` or `tls.reality` | blocks do not reach the config (the emit strips them) | `RegistryWarning(tls_not_applicable_quic)`, severity `info`, one per block; `value` is the block **as the body carried it** | `parse_warnings.dart` `annotateFromRawBody` — the verbatim-map pass of spec 472 step 1 runs the sanitiser over the body the provider sent, and the registry rule fires there. For **hysteria2 and tuic** the extra hand-written producers in `json_parsers.dart` were removed in step 5: each named the same `(code, path)` on the same body, the dedup hid the duplicate, and they were redundant either way. `masque` still has its own (step 7); hysteria v1 has no parser in LxBox at all (`extension: desktop`), so nothing there to remove | the same registry rule as the URI path — a node must carry the same codes whichever way it arrived. MASQUE matters only here: its link format carries no `fp`/`pbk`, and `MasqueSpec` knows no such fields at all, so in a hand-written body the block vanished without a trace | §469 / contract 1.1.4, §472 steps 1 and 5 |
| naive full TLS block in JSON | trimmed to `enabled` + `server_name` + `certificate` + `certificate_path` | silent | `json_parsers.dart` `_naiveTlsFromSingbox` | the rest (`disable_sni`, `insecure`, `alpn`, versions, `client_*`, `fragment*`, `kernel_*`, `utls`, `reality`) is fatal on outbound creation (`protocol/naive/outbound.go:45-86`); the pin `certificate_public_key_sha256` is silently not read by naive, so it is dropped rather than promise pinning that does not happen | §281, §454 |
| TLS passthrough key (`kTlsPassthroughKeys`: `certificate`, `certificate_path`, `disable_sni`, `min/max_version`, `cipher_suites`, `curve_preferences`, `client_*`, `fragment*`, `kernel_*`) with a value of the wrong type — number instead of PEM, object instead of string, `false` for a bool | key dropped, the node lives | silent | `json_parsers.dart` `tlsPassthroughFromSingbox` | a `Listable[string]` with garbage sinks the decode of the whole config in the core; `false` is the core's omitempty | §454 |
| `vmess.security` outside the core's enum / absent | the same funnel as the URI: `trim`+`lower`, enum of six, alias `chacha20-ietf-poly1305`, anything else → `auto` | silent (AppLog only) | `json_parsers.dart` `parseSingboxEntry`, `normalizeVmessSecurity` | the JSON editor and Smart-Paste bring `aes-128-ctr` just like subscriptions do; the core drops the whole config on it | §459 (contract §24.2 item 7.11) |
| TLS key outside the core's `OutboundTLSOptions` (typos) | key dropped | silent | `json_parsers.dart` `_tlsFromSingbox` | the core rejects an unknown field on the whole config | §454 |
| `tls.engine`, `tls.spoof`, `tls.spoof_method`, `tls.handshake_timeout` in a body | **passes through as is**, emitted in the core struct's position | silent | `tls_spec.dart` `kTlsPassthroughKeys`, `json_parsers.dart` `tlsPassthroughFromSingbox` | all four are `OutboundTLSOptions` fields the registry has always listed and the emitter could always write, but the parser never read them — a node saved through the JSON tab lost them without a trace. Found by the round-trip guard below, not by a report | §476 |
| ws / httpupgrade `headers` other than `Host` | **read into the model** and emitted back | silent | `json_parsers.dart` `_headersExceptHost`, `transport_spec.dart` `HttpUpgradeTransport.headers` | the emitter merged `Host` with `headers` and wrote both, but ws read only `Host` out of the map and httpupgrade had no `headers` field at all: a node with `User-Agent` lost it on re-save. `Host` stays a separate field so the two do not both produce the same key | §476 |
| http transport `headers` | read into the model | silent | `json_parsers.dart`, case `http` of `_transportFromSingbox` | `HttpTransport.headers` existed and was emitted; the JSON branch simply never filled it | §476 |
| `tls.ech` as an object | **passes through as is**, emitted in the core struct's position (between `kernel_rx` and `utls`); the app does not look inside | silent | `json_parsers.dart` `tlsPassthroughFromSingbox`, `tls_spec.dart` `kTlsObjectKeys` | premise D-006 ("the core is built without `with_ech`") was false: `common/tls/ech_tag_stub.go` declares the tag itself deprecated, ECH is always compiled in, and `tls.ech` passes `sing-box check` on the lx.4 pin. naive reads the block too (`protocol/naive/outbound.go:139-155`) | §459 (contract §24.2 item 7.2), revises §454/D-006 |
| `tls.ech` not an object (a string, a number, an array) | key dropped | silent | `json_parsers.dart` `tlsPassthroughFromSingbox` | same guard as the rest of the allowlist — the core would reject the wrong shape on the whole config | §459 |
| WG private/public/psk not 32 bytes | node rejected | silent | `json_parsers.dart:1254-1268` | garbage sinks `sing-box check` entirely; a non-canonical form changes the identity hash | D-023/D-030 |
| WG `reserved` not a 3-element array in 0..255 | `null` — degrade to "no reserved" | silent | `json_parsers.dart:1349-1358` | do not lose the node | §219 |
| WG AWG with `mtu` over 1280 | **kept** — a sing-box body is the `singbox` input | `awg_mtu_high` (info), set by the sanitizer over the verbatim map | `json_parsers.dart` (wireguard branch), rule in `body_sanitizer.dart` `_applyMaxWhen` | used to mirror the URI parser and clamp; since contract 1.1.5 the input decides, and what the author wrote in the core's own form stays. The build gate honours the same exception, so §455 (`origin.kind: json` goes to the core verbatim) holds | §473, was §097 |
| MASQUE flat legacy `network`/`sni`/`skip_cert_verify` | never read | silent | `json_parsers.dart:1307-1313` | a flat `sni` beside `tls.server_name` made the core fail fast | §393 |
| `reality.enabled != true` or invalid `public_key` | `reality = null`, node stays plain TLS | silent | `json_parsers.dart:1385-1395` | do not poison config.json | §169 |
| `reality.short_id` non-hex / odd / over 16 | dropped (`''`) | silent | `json_parsers.dart:1392-1394` | as in the URI branch | §343 |
| `reality.key_share` in any case / with spaces (`Hybrid`) | `trim().toLowerCase()`, then the enum | silent (AppLog only) | `json_parsers.dart` `_realityKeyShare` | the core is case-sensitive, but the value is the source's intent — used to be lost silently | §459 (contract §24.2 item 7.12) |
| `reality.key_share` outside `{hybrid, classical}` after normalisation (a number, an empty string) | field dropped, the node lives | silent (AppLog only) | `json_parsers.dart` `_realityKeyShare` | the core answers an unknown value with `unknown reality key_share` and refuses the outbound — and with it the whole config; degrade the field, not the config | §457, §459 |
| ws/httpupgrade `path` key absent | path `''`, no `/` default | silent | `json_parsers.dart:1412-1416` | canonical sing-box JSON does not write the default either | §103 D-016 |
| Glued Xray path `/x?ed=N` in ws JSON | tail cut | silent (no warnings channel here) | `json_parsers.dart:1413-1415` | glued Xray paths reach the editor too | §303 |
| JSON flavour unrecognised, or `clashYaml` | 0 nodes | silent | `body_decoder.dart:181-209`, `parse_all.dart:191-193` | the `xrayArray` branch works, and its classification must not shift on ambiguous input | §368 §7.1 |
| `tcp_keep_alive` / `tcp_keep_alive_interval` not a Go-duration | field dropped, the other two survive | silent (deliberate) | `tcp_keep_alive.dart:18-22`, `json_parsers.dart:1006` | same guard as the URI branch — the value is read with `toString()`, not a cast, because a hand-edited JSON writes the duration as a number | §453 |

### 2.2 Xray import (`parseXrayElement`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `protocol` in `{freedom, blackhole, dns, loopback}` | service outbound — never a node | silent | `json_parsers.dart:572, 63-68` | not servers | §321 |
| Tag is a `sockopt.dialerProxy` target | withdrawn from standalone nodes | silent | `json_parsers.dart:130-133` | a relay is not a subscription node of its own; it lives as the owner's hop | §310 |
| Tag is a target but inside a **cycle** | returned to candidates | owner gets `DialerProxyUnusableWarning` | `json_parsers.dart:104-133` | filtering it here would lose the node **silently**, with no warning at all | §404 |
| `dialerProxy` target unusable (missing / group / service / unconvertible / cyclic / deeper than 8) | **owner rejected in full** — no node created | `DialerProxyUnusableWarning` (error) | `json_parsers.dart:225-241`, logic `:794-855` | emitting it with a direct path would be a silent deanonymisation: the provider wrapped the dial in a relay because the direct route is cut. Principle 4 | §404 / D-085 |
| Unusable hop in the **middle** of a multi-hop chain | whole chain → null → owner rejected | `DialerProxyUnusableWarning` | `json_parsers.dart:846-851` | a truncated path releases traffic one hop earlier than the provider intended | §404 |
| `dialerProxy: "direct"` | chain → null → **owner rejected** | `DialerProxyUnusableWarning` | `json_parsers.dart:815-819` | differs from the sing-box branch, where the same text is silent and costs no node — here D-085 forbids substituting a direct path for a relay | §404 |
| Rejected owner has no sibling to carry the warning | reason kept in `dropped[]`, attached to the subscription's first node | `DialerProxyUnusableWarning` | `json_parsers.dart:286-291`, `parse_all.dart:151-164` | if there is no node at all the subscription is empty and there is nobody to tell — a documented hole | §404 P3 |
| Duplicates by `nodeDedupSignature` | skipped | silent | `json_parsers.dart:248-256` | the old key ignored transport and relay, collapsing "direct + BYPASS" pairs into one | §404 D-086 |
| Exception (TypeError) inside a converter | node skipped | `UnsupportedProtocolWarning(proto\|'malformed')` | `json_parsers.dart:263-271` | garbage field types (`streamSettings: "none"`) throw | §322 |
| Several balancers in one element | first taken, rest **silently ignored** | silent | `json_parsers.dart:312-323` | the schema allows it; real configs have one | §322 |
| Balancer `maxRTT` | clamped by `clampPoolTolerance` | silent | `json_parsers.dart:388-390` | `maxRTT` is an absolute ceiling in Xray while `pool_tolerance` is a window from the best — carried 1:1 by owner decision, since an exact conversion is impossible | §322 |
| `strategy.type` unknown / absent | default `roundRobin`; `leastLoad expected≤1` → `leastTest` | silent | `json_parsers.dart:366-373` | `leastLoad` with expected > 1 → round_robin is an approximation | §322 |
| hysteria `version != 2` | node rejected | `UnsupportedProtocolWarning` | `json_parsers.dart:751` | no v1 spec here | §321 |
| `finalmask.quicParams` on hysteria | **not carried over** | silent | `json_parsers.dart:741-743` | no sing-box equivalent, and an unknown field sinks the whole config | §321 |
| Xray `users[].security` (VMess) outside the core's enum | coerced to `auto`, original kept in the warning | `vmess_security_unknown` (warning) | *moved to the registry, §1.0* — `protocols/vmess.json` → `security`, enum + `on_invalid: coerce auto` (spec 472 step 8). The hand-written `normalizeVmessSecurity` is gone **from this input**; the substitution used to be silent, in AppLog only | one funnel for all three inputs | §459 (contract §24.2 item 7.11), §472 step 8 |
| Xray VLESS `flow=xtls-rprx-vision-udp443` | flow → `xtls-rprx-vision`, `packet_encoding: xudp`; **the port is not touched** | silent | `registry/protocols/vless.json` → `mappers.xray.params.flow` (`value_map` + `sets`), described by the mapper rule `vision_udp443_is_a_compound_name` in the same file — not a value judgement: the suffix is part of a compound **name** the core's enum does not contain at all | the port is a property of the node. Rewriting it to 443 made a `…:8443` node unreachable — a bug both clients had | §459 (contract §24.2 item 7.4), was §321 |
| Xray VLESS `flow` outside the pair `""`/`vision` | field dropped | `flow_deprecated` with the path and value | *moved to the registry, §1.0* — `protocols/vless.json` → `flow`, enum + `on_invalid: drop`. On this input there was **no code at all** before step 8 | the core accepts exactly two values | §115, §472 step 8 |
| Xray `fingerprint` outside the vocabulary | → `chrome` | `utls_fp_unknown` with the path and the value **as written** | *moved to the registry, §1.0* — `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome`. Was `UnknownFingerprintWarning` with no address and no value | whole-config fatal | §281, §472 step 8 |
| Xray REALITY `publicKey` invalid | block dropped → plain TLS (body unchanged) | `reality_pbk_invalid` with the path | *moved to the registry, §1.0* — `tls.json` → `reality.public_key`, `format: base64_32`. The degradation used to be **silent** | keep the node working, do not poison config.json | §169, §472 step 8 |
| Xray REALITY `shortId` not hex / odd length | field dropped | `reality_short_id_invalid` | *moved to the registry, §1.0* — `tls.json` → `reality.short_id`. No code on this input before step 8 | a truncated short id belongs to somebody else (principle 1) | §169, §472 step 8 |
| REALITY `pbk` in **std** base64 (`+`, `/`, `=`), on any input | rewritten to RawURL (`-`, `_`, unpadded) — the same key byte for byte | silent: this is spelling, not a verdict | `uri_utils.dart:413` `normalizeRealityPublicKey`, called beside the block gate (`json_parsers.dart:1378`), the same place `short_id` is normalised. Precedent: `normalizeAwgHeaderKey` (§481) | the core decodes `public_key` with **RawURLEncoding only** and answers `decode public_key: illegal base64 data`, killing the **whole** config: the node parsed fine and the VPN did not come up at all. Validity was judged correctly all along (`format: base64_32` accepts both alphabets) — it was the *spelling* that never got translated. A value that does not decode to 32 bytes is returned **as it arrived**: the block gate judges it, and the person needs to see what they wrote | §480 Д-6 |
| Xray transport `path` with broken percent-encoding (`%zz`) | **field dropped** | `type_invalid` with `transport.path` and the value | *moved to the registry, §1.0* — `transports.json` → `path`, `format: url_path`. **Before step 8 the path reached the core**, which rejects the whole config.json over it (`ws: parse path: invalid URL escape`) — one subscription node took the entire VPN down | normative in the corpus (`uri/trojan/ws_path_broken_percent_kept`): field dropped, node lives | §463, §472 step 8 |
| Xray VLESS `encryption` outside the `mlkem768x25519plus…` form | **node rejected at parse time**, reason in `dropped[]` | `vless_encryption_invalid` | *moved to the registry, §1.0* — `protocols/vless.json` → `encryption`, `pattern` + `on_invalid: drop_node`. Until step 8 the node got the code but **stayed in the list**, and only the build gate removed it | the core will not start on the whole config (issue #147) | §477, §472 step 8 |
| Xray `fp`/`pbk` on hysteria2 (QUIC) | both blocks not written to the body at all | silent | the mapper rule `quic_has_no_utls_or_reality` (`registry/protocols/hysteria.json` → `mapper`) records the intent; the removal itself is the registry's `forbidden_for` on `tls.json` → `body.fields.utls` / `.reality` with the code `tls_not_applicable_quic`, executed by the sanitiser (`tls.json` → `policy.quic_strip`), since `mappers.xray` of hysteria/hysteria2 does include `tls#xray`. Handing them to the sanitiser instead would put `tls_not_applicable_quic` where this input has always been silent: the old branch read the fingerprint, but `Hysteria2Spec` never emitted it | uTLS and REALITY do not exist over QUIC | §469, §472 step 8 |
| Xray ws `?ed=N` | tail cut → `max_early_data` | `ws_early_data_converted` (info, text from the registry) | `registry/transports.json` → `blocks.xray.ws.path` (`extract` splits the `?ed=` tail into `max_early_data`, with `implies` for the header name), described by the mapper rule `ws_early_data_path_suffix` in the same file. The channel exists on this input now: before step 8 the conversion was silent here | otherwise a 404 | §303, §472 step 8 |
| Xray gRPC `grpcSettings.serviceName` in the form `/<service>/Tun` | **nothing — carried verbatim**, leading `/` included | silent | `registry/transports.json` → `blocks.xray.grpc.serviceName` — carried by `maps_to` with no normalisation, the same answer as the URI branch (core lx.8 parses the `/` itself) | the same node must not read differently by input | §468 (supersedes §464, issue #130) |
| Xray ws `eh` without `ed` | `eh` ignored | silent | `registry/transports.json` → `blocks.xray.ws` — the record declares `path` only, and the header name arrives solely through the `implies` of the `?ed=` tail | the core enables the mode on `max_early_data > 0` | §320 |
| Xray `sockopt.tcpKeepAliveIdle/Interval` negative | `disable_tcp_keep_alive: true` | silent | `registry/dialer.json` → `blocks.xray.disable_tcp_keep_alive` (a `when: {lt: 0}` record, one per spelling of the key) — any negative value means `SO_KEEPALIVE=0` (`sockopt_linux.go:143`) | translation of spelling, not a judgement | §453 |
| Xray `realitySettings.keyShare` and `tlsSettings.alpn` | **not carried over** — as before step 8 | silent | `registry/tls.json` → `blocks.xray`: `keyShare` has no record at all, and `alpn` has one with `maps_to: null` — read but deliberately not written (D133-C9), except in the hysteria/hysteria2 sections, which declare their own `alpn` record | the sing-box input reads both, this one never did. Carrying them would shift the body and identity of live nodes, and the corpus has no case for this input — a question for the launcher, not a side fix (spec 472, §14.5) | §472 step 8 |

## Layer 3 — node emission

The narrowest waist in the pipeline: every source branch — URI, sing-box JSON,
Xray JSON, manual editor — builds a `NodeSpec` and emits through here. A guard
placed at this layer cannot be bypassed by adding a new source.

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| XHTTP `uplink_data_placement: header` with **no** `mode` | `mode: packet-up` written, placement kept | `XhttpModeForcedPacketUpWarning` | `transport_spec.dart:266-292` | the core accepts header placement only in packet-up and drops the **entire** config otherwise; one subscription node stops the VPN coming up at all. The mode is added rather than the placement removed because `header` is meaningful only in packet-up — so the source implied it, and removing the placement would build the node differently from what the server expects | §416 |
| XHTTP `uplink_data_placement: header` with an explicit non-packet-up `mode` | placement removed, `mode` **left alone** | `XhttpParamResetWarning(placementRequiresPacketUp)` | `transport_spec.dart:293-295` | now two intents conflict. Principle 1: rewriting an explicit `mode` would change the node's wire protocol, so the unusable part goes instead | §416/§169 |
| XHTTP `mode` outside `{auto, packet-up, stream-up, stream-one}` (case-sensitive) | field reset (not emitted) | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:240-252, 255-258` | a value outside the set is a whole-config fatal (`transport/v2rayxhttp/client.go:47-51`); nobody checked it before. The case is not normalised — the core is case-sensitive | §459 (contract §24.2 item 7.14) |
| XHTTP `seq_placement` outside `{path, query, header, cookie}` | field reset (not emitted) | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:244-252, 262-263` | a value outside the set is a fatal | §217 |
| XHTTP `x_padding_placement` outside `{cookie, header, query, queryInHeader}` (case-sensitive: `queryInHeader` is camelCase only) | field reset | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:320-321` | as above | §217, §459 |
| XHTTP `x_padding_method` outside `{repeat-x, tokenish}` (case-sensitive) | field reset | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:322-323` | as above | §217, §459 |
| XHTTP `session_placement`, `uplink_http_method` | **pure passthrough, no guard by design** | silent | `transport_spec.dart:254-260, 303-309` | principle 2: the core rejects one node on these, not the file. The canon is Go's behaviour ("normalization is left to the core") | SPEC 103 |
| XHTTP empty `xmux` sub-object | not emitted | silent | `transport_spec.dart:305-317` | `{"xmux":{}}` would read as configured-but-zero | §127 |
| uTLS **and** REALITY over QUIC (hysteria, hysteria2, tuic, masque) | both blocks stripped from the emit; `server_name`/`alpn`/`insecure` kept | `RegistryWarning(tls_not_applicable_quic)`, severity `info`, **one code per block** — set by the parser, see §1.5 and §2.1 | `tls_spec.dart` `toSingboxForQuic`, applied `node_spec_emit.dart` (hysteria2, tuic) | their `STDConfig()` returns an error and the QUIC path falls back to exactly that — both blocks on QUIC mean a dead node, and `fp` on hy2/tuic is xray-subscription noise. Which schemes and which code is a **registry rule** (`tls.json` `body.fields.utls/reality` → `forbidden_for` + `forbidden_codes`), not a list in Dart. Until 1.1.4 the strip was silent on every path | §282, §469 / contract 1.1.4 |
| VLESS `flow` other than exactly `xtls-rprx-vision` on bare TLS | field not written (plain VLESS) | `flow_deprecated` from the registry (`protocols/vless.json` → `flow`, enum + `on_invalid: drop`); the class `DeprecatedFlowWarning` is gone (§485) | `node_spec_emit.dart:117-125` | the core accepts exactly two values; a universal net over all paths (URI/Xray/raw JSON/manual). The drop used to be silent: the user saw a node with no flow and no hint that the subscription had asked for a deprecated one | §115, §463 |
| socks with a password but **no** username | userinfo written as `:pass@` | silent | the engine emitter: `registry/protocols/socks.json` → `mappers.uri.emit.userinfo` (`form: raw`, `keep_empty_tail`); `toUri()` goes through `uriViaEngineRequired`. Test: `socks_pipeline_invariants_test.dart` | an empty username dropped the userinfo wholesale and the password was lost on the next re-save — a node's storage form *is* its link | §463 / §24.2 7.15 |
| node whose link carries a private key (ssh with an inline `private_key`, WireGuard/AWG, MASQUE), "copy link" action | copy **confirmed first**: nothing reaches the clipboard until "Copy anyway" | warning dialog "Link contains a private key" | flag `node_spec.dart:159` (overrides at `607`, `1137`, `1222`), applied `node_actions.dart:159-206` | a private key in a shared link is a different trust boundary than local state. It is not stripped from `toUri()`, because that same text is the storage form (`parseUri(spec.toUri()) ≈ spec`) and stripping would destroy the key on reload. The launcher refuses outright (`ErrShareURINotSupported`); we differ at the screen, not the emitter — a flat refusal broke moving your own node between your own devices, and it was inconsistent: ssh would not give the key out at all while WireGuard carried it away silently | §466 (replaced the refusal of §463) / §24.2 7.16 |
| hysteria2 obfs type not `salamander`/`gecko` at emit | `obfs` object not written | silent | `node_spec_emit.dart:245` | second line after the parser: only what the core accepts gets through | §358 |
| MASQUE legacy `network`/`sni` names | never written | silent | `node_spec_emit.dart:426-430` | still accepted but deprecation-warned per outbound, and writing old and new names with different values is fatal | §393 |
| Default-valued fields (`path='/'`, absent ints) | not emitted | silent | `transport_spec.dart:222-227` | the constructor default is for the UI, not the wire; emitting it breaks canon and identity hashes | SPEC 103 CANON §2.4 |
| **Contract registry sanitiser at PARSE time** — `emit()` of every freshly parsed node is checked against the registry `body` schema, and the findings are appended to `node.warnings` as `RegistryWarning(code, path, value)` | **nothing is sanitised — the body is left exactly as parsed**; the sanitiser's output is discarded and only its warnings are kept | the ⚠ on the node row, and behind a tap on it the warnings sheet (§460 W2b): every warning of the node, each with its registry text and — where the registry has them — `Why` (`cause_*`) and `What to do` (`fix_*`), plus a `Learn more` link to `docs/contract/warnings.md#<code>`. Text from `registry/warnings.json`, naming the field (`[<path>=<value>]`) | `services/contract/parse_warnings.dart`, called from `parse_all.dart:parseAll` | the build gate (§4.4) already removes this rubbish, but it does so at build time and reports into the build log — the subscription row stayed silent, so a node that the core would have refused looked healthy until you tried to connect. Cleaning is deliberately **not** duplicated here: a node in storage must stay what the provider sent (§455), and a parse has no core to judge against, so `min_core`/`platform` are switched off (`applyCoreGates: false`, contract §24.1.6) — a field the running core "does not know yet" is a build concern, not a parse one. A code a hand-written `NodeWarning` already put on the node is not repeated: the hand-written text is the human one. Reachability is bounded by the node model: a key the model has no field for, or a value that fails the parser's own type coercion, is gone before `emit()` — those codes come from the build gate, where the verbatim JSON source (§455) is also judged | §460 W2a |

## Layer 4 — config assembly

Order matters and is hard-coded in `buildConfig`, not derived from the `part`
directives in `post_steps.dart` (which is a barrel, not an orchestrator):
sources emitted → `resolveDeferredDetours` (§439, the second pass over detour links) →
`resolveChains` → direction groups → `normalizeRuleOrder` → custom rules →
rule-set flush → `route.final` degrade → TLS transforms → custom DNS →
`applyTunPackages` → `healPresetTagPrefix` → `healDanglingResolveServers` →
`healLegacyDnsStrategy` → `healUnknownUtlsFingerprints` → `healInvalidReality` →
`sanitizeOutboundGraph` → `validateConfig`
(`build_config.dart:309-611`). Two adjacencies are normative and commented in
place: prefix healing before the degradations (otherwise the setting is lost
rather than migrated), and the graph sanitiser last before the validator.

### 4.1 Graph sanitiser (`post_steps/sanitize_outbound_graph.dart`)

The final pass over the outbound graph. Its stated rule is "degrade one element
with a warning rather than hand the core a file it will reject"
(`sanitize_outbound_graph.dart:19-20`).

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `detour` to a non-existent tag (a detour that came inside a node body; storage links are resolved earlier, fail-closed — §4.4a) | `detour` key removed, node goes direct | `emitWarnings`, aggregated per target (first 5 names + count) | `:304-314`, render `:792` | any dangling reference is fatal for the config **as a whole**, and sing-box names not the culprit but the first outbound referencing it (`dependency[X] not found for outbound[Y]`) | §393 A4 |
| Same, but the target was removed by the sanitiser itself | separate bucket, different text | `emitWarnings` ("was left with no members and removed during sanitation") | `:310-312`, `:803-806` | "referenced missing X" would be a lie sending the user to hunt a broken subscription instead of what happened | §393 A4 |
| Ghost members of a `selector`/`urltest` | excluded from the roster | `emitWarnings` | `:382-402` | the core rejects the config on a dangling member | §393 A4 |
| Group emptied **and** it is a Direction | not dropped: roster becomes `[block, direct-out]`, `default = block` | `emitWarnings` | `:417-430` | removing it would dangle `route.rules[].outbound`; blocking is safer than releasing traffic outside the VPN | §393 A4 |
| Group emptied, not a Direction | entry dropped whole | `emitWarnings` | `:432`, `:148-152` | cascade cleanup | §393 A4 |
| Group `default` not among its members | replaced with `kept.first` | `emitWarnings` | `:440-446` | otherwise the core rejects the config ("default outbound not found") | §393 A4 |
| Node whose detour leads into a group it belongs to | node removed from the roster, **detour kept** (fail-open) | `emitWarnings`, aggregated per node | `:390-410`, render `:783` | the detour was set deliberately; sending the traffic direct would break exactly what the user asked for. Otherwise the kernel would not start (dependency cycle) | §393 A4 |
| Composite: a node keeps a detour into a Direction that has gone to block | nothing changed — composite warning only | `emitWarnings` | `:211-222`, render `:765` | the node's policy silently inverted while the config stays valid and the core starts; no other warning names the consequence | §393 A4 |
| `type: chain` hop pointing at a non-existent tag | **chain dropped whole** | `emitWarnings` | `:332-343` | the core will not start on a dangling reference, and "just drop the hop" would make it a different route | §393 C4 |
| `type: chain` nested chain at position ≥ 1 | chain dropped whole | `emitWarnings` | `:344-352` | core invariant `protocol/chain/chain.go:279` | §393 C4 |
| Group used as a hop contains chains among its leaves | chains excluded from that group's roster | `emitWarnings` | `:498-546` | the core walks group leaves at start and rejects a nested chain; `check` does not catch it, only `run` does | §393 C4 |
| Cycle over any edge (detour / member / chainHop) | Tarjan SCC + scoring, **one** edge cut per pass: detour key removed, member excluded, or chain dropped | `emitWarnings`, 3 texts | `:571-668` | which edge to cut is the §254 question — taking the first would cut innocent nodes (the §254 case would have stripped detours from two clean nodes instead of the one at fault) | §393 A4/§254 |
| No edge unties the cycle (`bestScore <= 0`) | sanitiser gives up | nothing here → fatal `DetourCycle` later | `:644` | hand it to the validator | §393 A4 |
| `urltest` whose `interval` is greater than `idle_timeout` (a missing key or `0` means the core default: 3m / 30m) | `idle_timeout` set to the `interval` string; `interval` is never changed. Values the core would reject, negative values and `selector` are left alone | `emitWarnings` with both values and the reason | `sanitize_urltest_timings.dart:39-65`, call `:234-238`; durations parsed by `core_duration.dart` | the core fills in its defaults and rejects `interval > idle_timeout` in the group constructor (`NewURLTestGroup`, both `least_test` and `round_robin`), so `check` passes and only `run` fails. Shortening `interval` would multiply probes against the provider; a longer `idle_timeout` costs at most one extra probe of an idle group. The core's duration parser knows `d`, `time.ParseDuration` does not | §442 |
| A tag counts as "alive" only with an actual entry (`dns-out`/`block-out`/`direct`/`reject`/`drop` are ghosts) | affects all rules above | — | `:130-146` | treating a tag as alive without an entry would leave a reference the validator then kills fatally — fail-open here equals fatal there | §393 A4 |
| `chain` deliberately excluded from `_isGroup` | trap guard | — | `:260, 267, 73-79` | giving it group semantics would exclude a ghost hop from the "roster" instead of dropping the chain, and the user would travel a route they never asked for | §393 C4 |
| Fixpoint iteration limit (`len*4 + 8`) exhausted | loop exits | **silent** | `:154-197` | the comment argues it is unreachable (each pass removes an edge or node); there is **no handling and no warning** if it is reached — purpose of the unhandled branch unclear | §393 A4 |

### 4.2 Heal steps (`post_steps/heal_*.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Route rule `{action: resolve, server: X}` where X is not a DNS server tag | `server` removed, resolution falls back to DNS routing | `emitWarnings` (`build_config.dart:554`) | `heal_dangling_resolve_servers.dart:44-45` | the core does **not** validate this at start — it fails lazily on every matching connection (`DNS server not found`), so all matched traffic is dead. Our validator does not see this reference | §247 |
| REALITY `public_key` not X25519 | whole `reality` block removed, node degrades to plain TLS | `emitWarnings` (`:593`) | `heal_invalid_reality.dart:36-40` | `invalid public_key` is a whole-config fatal | §343/§169 |
| REALITY `short_id` not a String (a number from raw JSON or a §302 patch) | → `''` | `emitWarnings` (`:591`) | `heal_invalid_reality.dart:44-48` | the core cannot decode it either — same fatal. Drop, do not fit | §343/§169 |
| REALITY `short_id` non-hex / odd / over 16 | → `''` (an empty short id is legal) | `emitWarnings` | `heal_invalid_reality.dart:48-51` | decoded as hex into `[8]byte`; whole-config fatal | §343 |
| `reality.enabled != true` | left alone | silent (deliberate) | `heal_invalid_reality.dart:31` | the core does not decode a disabled block, so it is not fatal | §281 |
| Legacy `strategy` in `dns.rules` together with any `query_type`/`ip_version` | `strategy` removed from **all** dns.rules | `emitWarnings` (`:565`) | `heal_legacy_dns_strategy.dart:34-45` | the presence of the new keys switches the core into non-legacy DNS mode, where legacy `strategy` is fatal at start and the VPN does not come up | §246 |
| Other triggers of the same core switch (`match_response`, `response_rcode`, action `evaluate`/`respond`) | **not caught** | silent | `heal_legacy_dns_strategy.dart:15-18` | our template does not emit them; catching every user-authored form is a separate task | §246 |
| Reference to a local (unprefixed) preset tag | rewritten to `<preset_id>:<tag>` in dns rules, `dns.final`, route rules | `emitWarnings` (`:543`) | `heal_preset_tag_prefix.dart:70-101` | the core does not validate this at start: `sing-box check` passes and it fails lazily, so the user sees "the internet is broken on some sites", not "the update broke a setting" | §103 C7 |
| Two presets declared the same local tag | **not healed** — falls through to the dangling-resolve guard | that guard's warning | `heal_preset_tag_prefix.dart:48` | guessing which one the user meant would silently pick the wrong one | §103 C7 |
| hysteria2/tuic carrying `tls.utls` and/or `tls.reality` | both blocks removed | silent **here**; the registry guard of the same build reports `tls_not_applicable_quic` on the body it sees | `heal_unknown_utls_fingerprints.dart:30-34` | uTLS and REALITY over QUIC are a dead node; restoring utls here would resurrect it. Since 1.1.4 the strip is a registry rule, so a body that still carries the block gets a code in the build report — the node itself is warned earlier, at parse time | §282, §469 |
| REALITY with no `utls` block (or disabled) | minimal `{enabled: true}` restored | **silent** | `heal_unknown_utls_fingerprints.dart:38-47` | REALITY without uTLS is fatal ("uTLS is required by reality client") | §281 |
| Known xray fingerprint alias | canonicalised | **silent** | `heal_unknown_utls_fingerprints.dart:51-58` | a synonym, not a degradation | §281 |
| Unrecognised fingerprint | → `chrome` | `emitWarnings` (`:578`) | `heal_unknown_utls_fingerprints.dart:57-58` | outside the core's case-sensitive vocabulary is a whole-config fatal; discarding would lose a live server | §281 |
| Whitespace-only fingerprint | key removed, utls stays enabled | silent | `heal_unknown_utls_fingerprints.dart:53-56` | the core treats an empty fingerprint as chrome | §281 |
| REALITY with a missing, empty or `random` fingerprint | → `chrome`, written explicitly | **silent** | `heal_unknown_utls_fingerprints.dart:78-85` | no choice was made: `random` is the vless/anytls/Xray-JSON parsers' default for an empty `fp` (D-009) and the model does not tell it apart from an explicit `fp=random`, so every `random` is replaced (same as the launcher). Explicit so the config does not depend on the core's default | §444 (D-119) |
| REALITY with any other fingerprint from the vocabulary (`firefox`, `safari`, `randomized`, …) | **left as is** | `RealityFingerprintWarning` on the node (parser) | `heal_unknown_utls_fingerprints.dart:80-85` | the node's fingerprint comes from the subscription and goes into the config as is; the app does not rewrite the source's choice. 2.23.2 replaced it with `chrome` (D-104) | §444 (D-119) |

### 4.3 Core capability gate (`chain_nodes.dart`, `core_chain_capability.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Core older than `1.14.0-lx.27-rc.5` (no `type: chain`) | **all** chains degrade — none emitted | `emitWarnings`, code `chain_unsupported_by_core` | `chain_nodes.dart:98-102`, `core_chain_capability.dart:119` | an older core rejects the config entirely (`unknown outbound type: chain`) — one configured chain would leave the user with no VPN at all | §393 C5 |
| Version unparsable / empty / upstream without `-lx.N` | **fail open** — assume support | silent | `core_chain_capability.dart:120-123` | degrading on a guess costs a working route, while a config the core rejects at least surfaces as a start error. The reverse mistake is undiagnosable | §393 C5 |
| `Libbox.version()` transient failure | empty string not cached; exception → `''` | silent | `core_chain_capability.dart:150-170` | otherwise chains vanish from one rebuild and return in the next — a "flickering" route is impossible to diagnose | §393 C5 |
| Version comparison | typed `CoreVersion`, not string compare | — | `core_chain_capability.dart:92-108` | string compare is the classic bug (`rc.10` < `rc.5`) | §393 C5 |
| Chain tag collides with an existing node/Direction/chain | chain skipped | `emitWarnings`, `chain_invalid` | `chain_nodes.dart:115-121` | two outbounds with one tag makes the core reject the config | §393 C3 |
| Chain position references an unknown tag (**including a forward reference**) | **chain dropped whole** | `emitWarnings`, `chain_hop_missing` | `chain_nodes.dart:126-143` | cycles between chains become impossible by construction; and silently substituting a hop is the same as silently changing the exit country | §393 C3 |
| Chain passes through a Direction (transitively) | excluded from **that** Direction's roster | `emitWarnings`, `chain_cycle_through_direction` | `chain_nodes.dart:236-263` | the user would get a route they never intended — picking a chain inside proxy-out loops traffic back onto it | §393 C4 |

### 4.4 Build orchestration (`build_config.dart`, `server_list_build.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `route.final` not among `{direct-out, block, emitted Direction tags}` | default `vpn-1` substituted | `emitWarnings` | `build_config.dart:496-509` | a static tag for a Direction with an empty node set would dangle (fatal); `vpn-1` is undeletable and therefore always a valid target | §125/§219 |
| Tags of **all** Directions (including disabled) reserved in the allocator | a same-named node gets a `-N` suffix | silent | `build_config.dart:254-256` | a subscription node labelled `vpn-1` would duplicate a tag and the core refuses to start; for disabled ones the user was getting a "vpn-2" option leading to someone else's server | §351/§393 |
| `direction.include[]` referencing below itself / disabled / non-existent | option dropped from the roster | `emitWarnings` | `build_config.dart:789-798` | the core would reject a forward reference, so degrade the roster rather than break the build | §393 A3 |
| Direction roster empty | fallback `[block-out, direct-out]`, `default = block` | `emitWarnings` when a non-empty filter is to blame | `build_config.dart:837-840, 890-892` | safer to block than to release outside the VPN; and a selector must not be an empty group (fatal) | §201/§274 |
| A non-empty node filter matched nothing | warning states the **actual** outcome (blocked / direct / fallback) | `emitWarnings` + SnackBar | `build_config.dart:849-881` | with include_direct the outcome is direct-out — claiming "blocked" would be a lie about traffic leaving the VPN | §200/§274 |
| Chains subtracted from a Direction | that subtraction does **not** trigger the filter warning | — | `build_config.dart:733-742` | sending the user to fix a filter means sending them to hunt a typo that does not exist | §393 C4 |
| Broken / empty `node_filter` regex | `tryCompileRegex` → null → all base nodes | silent | `build_config.dart:715-722` | — | §125 |
| `defaultFilter` landed on a non-member | `default` key simply not written | silent | `build_config.dart:895-909` | otherwise the core rejects the config ("default outbound not found") and takes the first option anyway | §141 |
| An auto-select node inside a Direction's urltest twin | excluded | silent | `build_config.dart:753-763` | urltest inside urltest would measure the inner group's pick, not a server | §322 |
| A server or folder member whose source is a JSON object (`origin.kind: json`) | the source object goes into the config **verbatim** — the model's gates (§169/§281/§282/§343, the naive TLS filter) do not run on it; its `detour` key is dropped and re-decided by the build | silent at build; at Save the core's own verdict (`Libbox.checkConfig`) is shown and a rejected body is not stored | `verbatim_body.dart`, `server_list_build.dart` (before `getEntries`), `node_settings_screen.dart` `_saveSource` | the user wrote a sing-box object themselves — the launcher sends such an object as is too (TASKS_LXBOX §22); the gate is the core, not the model, and one bad key would otherwise sink the whole config | §455 |
| `clash_api` block | no longer injected | — | `build_config.dart:168-171` | the core is built without `with_clash_api`, and the block is a fatal start failure | §122 |
| `lx_idle_suspend_reachable` without the base `lx_idle_suspend` | reachable not written | silent | `build_config.dart:475-484` | core: "lx_idle_suspend_reachable requires lx_idle_suspend" | §215/§272 |
| Proxy auth without a password | `proxy_auth = 'false'` | silent | `build_config.dart:187-192` | guards against `[{"":""}]` | §067 |
| Auto-select node with an empty pool | node **not emitted at all** | silent | `server_list_build.dart:143-146` | an empty urltest kills core startup, reachable when all members are disabled or the subscription emptied | §322/§283 |
| Intra-folder detour cycle | DFS colouring, closing edge discarded | silent | `server_list_build.dart:247-264` | the main guard is in the controller; this backs up a hand-edited backup | §239 |
| Intra candidate with its edge cut | detour → `''`, reference not emitted | silent | `server_list_build.dart:273-279` | otherwise a bare tag goes into the config as a dangling reference | §239 |
| Tag allocator exhausts its counter (100000) | returns the **taken** base tag | **silent** | `build_config.dart:658-665` | practically unreachable, but the fail mode is "silently fatal" rather than "silently degrade", and there is no comment — **purpose/deliberateness unclear** | — |
| **Contract registry sanitiser** — every `outbounds[]`/`endpoints[]` entry from a node source is checked against the `body` schema of the contract registry: `unknown_key`, `type_invalid`, enum/format/bounds, `conflicts`/`requires` (**judged by VALUE, not by key presence — §467**: a key written as `0`, `""`, `"0"`, `"0-0"`, `false`, an empty object or an empty array counts as *not set*, exactly as the core reads it, so a provider's fully-spelled-out `xmux` section keeps its working `max_concurrency`), `forbidden_for` (naive TLS), `min_core`, `platform`, and the W2d expressions `format: base64_32` (key exactly 32 bytes after decode), `normalize: hex_only` + `normalize_code`, `advisory` with `except`/`when`, `requires` with `equals`, `default_when`, field types `awg_range` and `int_array` (§464) | offending key removed (or the entry dropped on `required`/`drop_node`) | `emitWarnings`, text from `registry/warnings.json` in the UI language, with `[<path>=<value>]` | `registry_gate.dart`, `services/contract/body_sanitizer.dart` | the registry is normative for both sides (contract §24.1): an unknown or out-of-enum key is fatal for the **whole** config, and hand-written per-protocol rules drifted from the core on every pin. Second echelon — the parsers' own gates stay in place; key order and valid values are untouched, so a valid config stays byte-identical. An expression the registry gained but this code does not know yet is logged once and ignored — the value is left alone, because the contract may legitimately run ahead of the client. `all_or_nothing` triggers **no action at all** (§467): the core leaves the unset fields of a partially filled section at zero (= no limit), so filling in the neighbours' defaults would impose limits the node never had — the attribute documents core behaviour and nothing more | §460, §464, §467 |

### 4.4a Node links (`node_link_resolve.dart`, `chain_nodes.dart`, `server_list_build.dart`; §439)

Since 2.23.3 `detour` of a source or folder member, chain `hops[]` and the explicit
members of an auto node are NodeLinks `{folder_id?, tag}` (D-112). They resolve to final
tags only at build, after every source has emitted (`build_config.dart:289-294`). The rule
is fail-closed (NODE_LINK §5.1): an unresolved link never becomes a direct connection.

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Empty link / container gone / no node with that raw tag / target node skipped by this build / root tag not among nodes, Directions and service tags | detour carrier **dropped from the config** with its own detour hops | `emitWarnings`, one line per link and reason: one carrier keeps `Node "X" was skipped: its detour … did not resolve`, several are listed as the first five names and `and N more` (§377) | `node_link_resolve.dart:120-152`, `build_config.dart:293-294` | before §439 the graph sanitiser removed a dangling `detour` key and the node went direct — traffic left the route the user set | §439 |
| Detour points at the node itself | carrier dropped | `emitWarnings` | `node_link_resolve.dart:233-236` | the core rejects a self-dependency | §439 |
| Ring of detour links | **every** participant dropped | `emitWarnings` | `node_link_resolve.dart:240-257` | no participant can be picked as "the culprit" without guessing | §439 |
| A carrier's target was dropped | the carrier drops too, until a fixed point | `emitWarnings` | `node_link_resolve.dart:259-276` | going through a node that is not in the config is the same dangling reference | §439 |
| Pair carrying a group's final tag instead of its raw tag (S3) | lowered to the raw tag when exactly one group matches | silent | `node_link_resolve.dart:130-134` | tolerant read agreed with the launcher; with two candidates guessing would pick the wrong group | §439 |
| Chain position link does not resolve | **chain dropped whole** | `emitWarnings`, `chain_hop_missing` with the resolve reason | `chain_nodes.dart:136-165` | as for an unknown root tag (§393 C3): a route without a hop is a different route | §439 |
| Auto node member link outside its container or without a node | member dropped | `emitWarnings` (`Auto node "…": member … was dropped`) | `server_list_build.dart:271-300` | a group does not leave its container (§322 §2); a disabled or vanished member has one outcome | §439 |
| Explicit auto node where no member resolved | node not emitted | `emitWarnings` | `server_list_build.dart:236-241` | an empty urltest stops the core | §322/§439 |

The storage side keeps links valid before the build: renaming (a body edit), moving,
ungrouping, dissolving a folder, reordering namesakes and changing a standalone server's
prefix rewrite links; deleting a node or a source clears them and the Servers screen names
the affected carriers (`settings_storage/node_link_registry.dart`).

### 4.5 Presets, rules and DNS

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Required preset var empty / unset | the **whole preset** yields empty fragments | `emitWarnings` | `preset_expand.dart:126-141` | — | §033 |
| Remote rule_set with no cached file | rule_set skipped | `emitWarnings` | `preset_expand.dart:189-198` | sing-box downloads nothing itself | §011 |
| DNS rule with no `server` and no serverless action | rule dropped **silently** | silent | `preset_expand.dart:232-235` | `route` and `evaluate` without a server are fatal at start, and an unknown action is a decode error; a template typo must not reach the core | §253 |
| DNS/route rule referencing an unregistered `rule_set` | rule dropped | `emitWarnings` | `preset_expand.dart:242-261, 367-375` | the core fails with `rule-set not found`; the guard is per-element so the rest survive | §011/§045 |
| `rule_set` of an invalid shape (empty string, int, bool, map) | reference removed, rule survives | `emitWarnings` | `preset_expand.dart:263-272, 395-404` | degradation instead of the core's fatal | §219 |
| `outbound == "reject"` (including via a template default) | **unconditional backstop**: `outbound` removed, `action: reject` set | silent | `preset_expand.dart:352-355` (marked "do not delete") | `reject` is an action, not an outbound tag; the validator would see a dangling ref and the core would not start. Without the backstop the literal reached users' route.rules | §033 |
| Intermediate actions (`resolve`/`sniff`/`route-options`) | outbound override and reject backstop **not** applied | silent | `preset_expand.dart:303-304` | the override would replace `action: resolve` with the user's outbound and destroy the semantics | §246 |
| A chosen DNS server is a **group** | its members are pulled in alongside it | silent | `preset_expand.dart:424-437` | without them the group arrives empty, the emission filter drops them as unknown, and the validator hits `EmptyDnsGroup` — fatal before the core starts | §354/§312 |
| Preset tag namespacing `<preset_id>:<tag>` | only tags declared here and references to them are prefixed | silent | `preset_expand.dart:474-546` | without it two presets sharing a local tag collide and the second silently loses its server; a reference to someone else's tag is left alone or it would point nowhere | §103 C7 |
| Duplicate DNS servers / rule_sets across presets | identical → silent skip; conflicting → first wins | `emitWarnings` on conflict | `preset_expand.dart:566-594` | — | §033 |
| `detour` on a `type: group` DNS server | **unconditionally removed** | silent | `preset_expand.dart:628-631` | the core accepts exactly `{servers, mode, error_ttl, win_ttl}` on a group and fails on an extra key — start broke whenever a non-direct Direction was picked | §319 |
| DNS server `detour` = `direct-out` / empty | key removed | silent | `preset_expand.dart:643-646` | `direct-out` is the core's own direct path; the key is noise | §117 |
| DNS server `detour` (after substitution) names an outbound that is not in the config — second fail-closed line | server **not emitted** | `emitWarnings` | `dns_servers.dart:205-213`, `preset_expand.dart:647-649` | removing the key (the pre-§441 behaviour) sent the server's queries direct, past the route the user picked | §441/§443, SPEC 129 Н10 |
| DNS rule whose `server` was dropped by the second line | rule kept with its matchers, becomes `action: reject`; route keys (`server`, `strategy`, `disable_cache`, `rewrite_ttl`, `client_subnet`, …) removed | `emitWarnings` | `heal_detour_dropped_dns.dart:54-75` | dropping the rule would hand its domains to `dns.final`, and a direct `final` leaks them | §441/§443, SPEC 129 Н10 |
| `dns.final` names a server dropped by the second line | `final` key removed, `{"action": "reject"}` with no conditions appended as the last DNS rule | `emitWarnings` | `heal_detour_dropped_dns.dart:76-84` | without `final` the core takes the first server of the list — the template's system resolver; the stub lets no query reach it (`sing-box check` on lx.39 accepts it, the live core answers REFUSED) | §443, SPEC 129 Н10 |
| `route.default_domain_resolver`, `domain_resolver` of outbounds/endpoints and of DNS servers name a server dropped by the second line | replaced with the template default (`dns_default_domain_resolver`) if emitted and usable, else the first emitted server that is not `fakeip`/`hosts`; nothing to replace with, or the DNS server's address is an IP — key removed; an object value keeps its shape | `emitWarnings` | `heal_detour_dropped_dns.dart:86-136` | the core does not start without a resolver; the server-address resolver works before the tunnel and carries no user domains. Not persisted: the server returns with its Direction | §441/§443, SPEC 129 Н10 |
| `"//"` comment keys in a raw-JSON rule | **recursively stripped** | `emitWarnings` | `custom_rules.dart:840-858` | sing-box strict-decode on an unknown field drops the whole config at start, and `//` is a common convention — a user copying a commented example got a fatal. Other unknown fields are left alone: their set is unknown to the builder, and cutting blind is worse than letting the core's decoder judge | §350 |
| Raw JSON: empty / malformed / scalar / no objects / empty after comment stripping | rule skipped | `emitWarnings` (4 texts) | `custom_rules.dart:781-827` | the build does not fail; the rule degrades and the rest of the config survives | §225 |
| Preset id missing from the template | rule skipped | `emitWarnings` | `custom_rules.dart:154-157` | — | §033 |
| Preset disabled by the routing toggle | produces no servers, rules or mirror locks | silent | `custom_rules.dart:141-145` | the routing toggle is king — as if the preset were not in the config | §121 |
| Force-IPv4 / DNS mirror with an empty match | not emitted | silent | `custom_rules.dart:~450, ~468` | a match-everything rule would kill AAAA globally | §256/§117 |
| `ip_is_private` / `inbound` / `protocol` inside a headless rule | lifted to routing-rule level | silent | `custom_rules.dart:692-696` | sing-box would cut the config at parse time | §030 |
| DNS group member is the group itself / duplicated / unknown / disabled | member dropped from the emit; **storage not mutated** | `emitWarnings` per reason | `dns_servers.dart:414-430` | self-inclusion drops the config in the core; a disabled member snaps back when re-enabled | §312 |
| DNS group empty after that filtering | **not healed, not dropped** — emitted empty | fatal `EmptyDnsGroup` at the validator | `dns_servers.dart:395-397` | deliberately blocks the build so the user decides, instead of degrading silently (anti-pattern §277/§278) | §312 |
| DNS group emptied because its members were dropped by the second line (`dangling detour`, nested groups included) | group dropped and healed as a server (rules → `reject`, `final` → stub, resolvers → replacement) | `emitWarnings` | `dns_servers.dart:353-389` | the members left for the same fail-closed reason; an empty group would make the build fatal instead of closing the references | §443, SPEC 129 Н10 |
| Disabled DNS server still referenced by an active preset or rule | force-included | silent | `dns_servers.dart:335-339` | otherwise a DNS rule points into nothing | §117 |
| Wizard-only fields in a DNS body (`enabled`, `description`, `_origin`, …) | stripped | silent | `dns_servers.dart:359-364` | the core rejects unknown fields | §044 |
| Orphan/unknown-`kind` DNS entries (legacy) | discarded | silent | `dns_servers.dart:114-123`, `dns_rules.dart:223, 322` | auto-discovery restores fresh state | §043/§044 |
| Duplicated preset rules with one `presetId` | the **last** survives | silent | `rule_order.dart:125-141` | seeding checks presence by presetId and would leave both; on import the second copy reflects the fresher intent | §398 |
| Missing mandatory (`default: true`) presets | seeded | silent | `rule_order.dart:84-111` | guarantees an unsortable preset exists and comes first — critical for route.rule order (sniff first) | §370/§264 |
| Rule-set tag already taken | auto-suffix ` (2)`, ` (3)` | silent | `rule_set_registry.dart:34-43` | tag uniqueness, defence-in-depth for imported or programmatically edited configs | — |
| Mixed-case SNI on a REALITY node | **skipped** | silent | `tls_transforms.dart:25-26` | the server matches the name against a map with an exact string key and no case folding; one changed letter misses the map and falls back to the decoy site — the node does not come up | §363 |
| Punycode labels (`xn--`) | not randomised | silent | `tls_transforms.dart:39` | the prefix is reserved and the payload is case-sensitive | §028 |
| Mixed-case SNI / fragment on inner hops | skipped | silent | `tls_transforms.dart:18, 66` | inner hops are already inside the tunnel; DPI cannot see their TLS | §028 |
| `tls_fragment` on a naive outbound | skipped | silent | `tls_transforms.dart:67-70` | the core rejects it fatally ("fragment is not supported on naive outbound") | §270 |
| `tls_fragment` on a non-h2 MASQUE | skipped **silently and deliberately** | silent | `tls_transforms.dart:71-85` | on h3 the core warns and ignores it; a global toggle should not complain about every unsuitable node | §393 |

### 4.6 Validator — the last line (`validator.dart`)

`validateConfig()` is pure: it never mutates the config, only collects
`ValidationIssue`s, and **every** issue it emits is `Severity.fatal`. Blocking
happens above it (`subscription_controller.dart:1958` → `FatalValidationException`),
so the config is neither persisted nor handed to the core. Before §141 P0.1
fatal issues were only logged and the broken config still reached the core,
producing a looping failed start with the bad config persisted as the source of
truth.

By design this is the *last* line, not the first: routine cycles are untied by
the graph sanitiser with a warning, and only what it could not untie arrives
here (`validator.dart:83-88`).

| Issue | Fires on | Code | Task |
|---|---|---|---|
| `DanglingOutboundRef` | `route.rules[].outbound` or `route.final` naming a non-existent tag | `validator.dart:42, 56` | §219 |
| `DanglingDetourRef` | `detour` naming a non-existent tag | `validator.dart:70` | §084 |
| `DetourCycle` | cycle over detour plus structural group→member edges; Tarjan SCC, minimal culprit set, **capped at 3 culprits** | `validator.dart:101-103, 231`, cap `:6` | §254/§393 |
| `DanglingDnsServerRef` | `dns.final` / `route.default_domain_resolver` naming a non-existent DNS tag | `validator.dart:117, 123` | §121 |
| `BadResolverServerType` | resolver reference pointing at a `fakeip`/`hosts` server | `validator.dart:152` | §384 |
| `EmptyDnsGroup` | group empty after the emission filter | `validator.dart:165` | §312 |
| `BadDnsGroupMember` | group member is `fakeip`/`hosts` | `validator.dart:171` | §312 |
| `DnsGroupCycle` | cycle in the DNS group graph | `validator.dart:180, 464` | §312 |
| `EmptyUrltestGroup` | empty `urltest` | `validator.dart:190` | — |
| `InvalidDefault` | `selector.default` absent from outbounds, or not a String | `validator.dart:196` | §141 |

The culprit cap exists for performance: uncapped colouring is quadratic and a
pathological config (150 nodes) spent about 1.3 s inside `generateConfig`.
Dangling DNS **group members** are deliberately not checked here — the builder
already dropped them with a warning (`validator.dart:130-131`).

## Known asymmetries and gaps

Found in the code during this revision; recorded rather than fixed.

**1. Warnings lost in the sing-box JSON branch.** The same condition that
produces a `NodeWarning` on the URI path is silent when it arrives via
`parseSingboxEntry`, because that function has no warnings accumulator:

| Condition | URI path | JSON path |
|---|---|---|
| `packet_encoding` outside the whitelist | `PacketEncodingUnknownWarning` | silent (`json_parsers.dart:1007-1010`) |
| hysteria2 obfs unknown / no password | `UnknownObfsWarning` / `MissingObfsPasswordWarning` | silent (`:1085-1089`, `warnings: null` passed explicitly) |
| uTLS fingerprint unrecognised | `UnknownFingerprintWarning` | silent (`:1397`) |
| MASQUE `vhttp` outside `{h3,h2,auto}` | `masque_vhttp_invalid` from the registry | the body path is no longer silent either: since §472 step 1 the sanitiser walks the **verbatim** map of a JSON node (`annotateFromRawBody`) and reports the same code |
| ws `?ed=` conversion | `ws_early_data_converted` | silent (`:1413-1415`, and Xray `:928-931`) |

For fingerprint and obfs the silence is **documented** ("power-user path
through the JSON editor / Smart Paste — the resulting value is visible in the
JSON itself"). For `packet_encoding` and MASQUE `vhttp` there is no explanation
in the code, and the divergence looks unintended.

**2. Declared but unused warning variants.** Only `NaiveBuildTagWarning`
(`node_warning.dart:185`) is left declared and produced nowhere in the parser
layer. `UnsupportedTransportWarning`, `MissingFieldWarning` and
`DeprecatedFlowWarning` were removed in §485 (`flow_deprecated` is now a
registry code). `XhttpResetReason.invalidPlacementValue`
and `XhttpResetReason.getRequiresPacketUp` are declared
(`node_warning.dart:186, 193`) but never set — those paths are passthrough by
the "canon = Go behaviour" decision.

**3. Unexplained literals.** `uri_utils.dart:181` replaces `🇪🇳` with `🇬🇧`
("leftover artefact from v1" — no core error or behaviour named).
The SNI heuristic (`registry/protocols/hysteria2.json` → `mappers.uri.params.sni`,
and our overlay `contract_draft/uri/anytls.json` for anytls) treats the
literal `'🔒'` as a bad SNI — a subscription's shop-window glyph, per the
registry's `sni_heuristic_falls_back_to_server`, though no core error is named
for it either. Neither purpose could be established from the code.

**4. Unhandled exhaustion branches.** The graph sanitiser's fixpoint limit
(`sanitize_outbound_graph.dart:154-197`) and the tag allocator's counter
(`build_config.dart:658-665`) both exit without a warning if reached. The
sanitiser's comment argues its branch is unreachable; the allocator has no
comment, and returning an already-taken tag is a silent fatal in the core.

**5. Depth limits are inconsistent.** `_detourReaches` and
`_pruneChainLeavesUnderGroups` (`sanitize_outbound_graph.dart:467, 514, 532`)
rely on a `seen` set with no depth cap, unlike `kMaxDetourCulprits` in the
validator and `kMaxDetourDepth` in the parsers. Whether that is a deliberate
choice is not stated.

**6. `healPresetTagPrefix` coverage.** It rewrites `dns.rules[].server`,
`dns.rules[].rule_set`, `dns.final`, `route.rules[].rule_set` and
`route.rules[].server` (`heal_preset_tag_prefix.dart:84-101`), but not
`route.rules[].outbound`. Nothing states whether that list is meant to be
exhaustive.

**7. Silent loss when a source yields no node.** A config or Xray element that
produces zero nodes loses all its warnings — there is no node to carry them
(`json_parsers.dart:205-207`, `singbox_config.dart:254-257`,
`parse_all.dart:151-158`). Compensated by the "skipped" counter in the import
dialog (§368 §8) and the contract's `dropped[]` envelope (D-088).

**8. `xhttp_uplink_header_placement_reset` — resolved.** The §416 guard used to
diverge from the Go reference, which passed the placement through, and the case
stayed red in the shared corpus. The launcher adopted the guard in its W2c wave:
the expectation now reads `transport: {mode: stream-up, type: xhttp}` with
`xhttp_param_reset`, and the case is green on both sides (§463). See
[`spec/tasks/416-xhttp-packet-up-guard.md`](spec/tasks/416-xhttp-packet-up-guard.md).
