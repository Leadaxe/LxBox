# 126 — WARP + AmneziaWG obfuscation (anti-DPI)

| Field | Value |
|------|----------|
| Status | Draft |
| Started | 2026-06-15 |
| Trigger | WARP to Cloudflare is plain WireGuard; DPI (RU/Iran) matches the WG handshake signature and throttles it. We need AmneziaWG obfuscation on top of WARP: junk fields that "fly off" (ignored by the server) but break the signature for DPI. |
| Related | [§025 warp integration](../features/025%20warp%20integration/spec.md) (base WARP); [§097](097-awg2-obfuscation.md)/[§112](112-awg2-ranged-headers.md) (AWG 2.0 in the project); [§110](110-amnezia-vpn-link.md) (Amnezia vpn://); [§127](127-pseudo-name-domain-generator.md) (pseudo name/domain generator) |
| Files touched | `services/warp/warp_account.dart`, `warp_client.dart`, `screens/warp_wizard_screen.dart`, new junk generator; `Awg` model/emit/parser — **do NOT touch** (ready) |

## Summary

Optional **"Add Amnezia 1.5 obfuscation"** checkbox in the Get WARP wizard (default off). When enabled, AmneziaWG fields from the **1.5** preset are mixed into the WARP node, masking the WG handshake from DPI **without breaking Cloudflare compatibility** (a plain WG server).

**Key principle (per the user):** only fields that do NOT break WG are used. The handshake packet stays standard WireGuard (Cloudflare understands it); junk is sent separately and ignored by the server.

## AmneziaWG 1.5 preset (from the working generator)

```jsonc
{
  "jc":   4,    // number of junk packets BEFORE the handshake
  "jmin": 40,   // min junk packet size
  "jmax": 70,   // max junk packet size
  "s1":   0,    // init-packet prefix — OFF (handshake = plain WG)
  "s2":   0,    // response-packet prefix — OFF
  "h1":   1,    // headers = default WG (1,2,3,4) → server understands
  "h2":   2,
  "h3":   3,
  "h4":   4,
  "i1":   "<b 0x...>"  // custom junk packet, generated on-device (2 templates: WG / SIP — see below)
}
```

**Why this does not break Cloudflare:** `s1=s2=0` (no magic prefixes in the handshake) + `h1..h4=1,2,3,4` (standard WG message-types) means the init/response packets are bit-for-bit like plain WireGuard. DPI does not see the signature (junk `jc`/`i1` goes first and breaks the pattern), and Cloudflare ignores the junk. This is exactly "fields that fly off but disturb DPI".

### i1 — own junk generator, 2 mimicry templates

**Reverse-engineering of `warp-generator.github.io` (2026-06-15):** their i1 is NOT random — it's **hardcoded meaningful constants** of two kinds:
- **Pseudo-WG** (`<b 0xce000000...>` / `c7000000...`, ~1250 bytes): the header imitates the WireGuard packet structure (1 fake type byte + 3 zeros, like `type`+reserved in a real WG packet), body is noise (entropy ~7.8). Masks junk as "another WG packet".
- **SIP** (`INVITE sip:bob@biloxi.com SIP/2.0...`, the canonical RFC 3261 example): junk pretends to be a VoIP call (DPI usually does not cut telephony).

**Our decision — OWN generator with randomization** (better than copying the constant: mimicry + uniqueness, no shared signature). CPS-tag format `<b 0xHEX>`.

**Template A — WG-traffic:**
```
byte[0]   = random fake type (NOT 1/2/3/4 — else taken for valid WG)
byte[1:4] = 00 00 00  (like reserved in WG)
byte[4:]  = random bytes, length ~1250 (randomize within a range)
```

**Template B — SIP-traffic** (valid SIP-INVITE, EVERYTHING randomized).

⚠ **Critical — do NOT keep `bob@biloxi.com`/`alice@atlanta.com`:** that is the verbatim RFC 3261 example, a publicly known string. DPI vendors know it → a non-randomized SIP becomes a **signature beacon** (worse than no obfuscation) + a shared signature across all users. Randomization is mandatory.

**Randomization decision (agreed 2026-06-15):** user/host are produced by a separate reusable generator — **see [§127 — pseudo name/domain generator](127-pseudo-name-domain-generator.md)** (`PseudoGen.user()` / `PseudoGen.host()`: pronounceable syllables, public IPs, no RFC beacons).

- **user** = `PseudoGen.user()` — syllabic name, 30% compound (`wecrifrima_tubruhe`).
- **host** = `PseudoGen.host()` — 30% 3-level / 30% public IP / 30% 2-level / 10% sip-subdomain.
- **branch / tag / Call-ID / CSeq / port** — random hex/digits (trivial, in §126).

```
INVITE sip:<syl-user>@<pub-ip> SIP/2.0
Via: SIP/2.0/UDP <pub-ip>:<rand-port>;branch=z9hG4bK<rand-hex>
Max-Forwards: 70
To: <sip:<syl-user>@<pub-ip>>
From: <sip:<syl-user2>@<pub-ip2>>;tag=<rand-digits>
Call-ID: <rand-hex>@<pub-ip2>
CSeq: <rand-num> INVITE
Contact: <sip:<syl-user2>@<pub-ip2>:<rand-port>>
Content-Type: application/sdp
Content-Length: 0
```
Randomize EVERY time: both users (syllabic), both IPs (public), branch, tag, Call-ID, CSeq, port. Valid per RFC 3261, but with no recognizable constants.

Junk bytes → hex → `<b 0x<hex>>`. Randomness: `Random.secure()`.

## Decisions (agreed with the user 2026-06-15)

| Question | Decision |
|---|---|
| Checkbox label | **"Add Amnezia 1.5 obfuscation"** |
| On/off | Checkbox in the Get WARP wizard |
| Checkbox default | **Off** (plain WARP by default) |
| i1 | **Own generator**, 2 templates: **WG-traffic** / **SIP-traffic**, randomized |
| Template selection | Dropdown/radio next to the checkbox (default — WG-traffic) |
| jc/jmin/jmax/s/h values | Built-in 1.5 preset (table above) |

**Obfuscation mechanics (why it works):** `s1=s2=0` + `h1..h4=1,2,3,4` → the handshake itself stays a valid WG packet (Cloudflare accepts it). `jc=4` (4 random junk packets) + `i1` (mimicry packet) are sent BEFORE the handshake → they shift the real init away from the position where DPI expects the `01 00 00 00`/148b signature, and mask the start of the stream as "another, but similar" protocol. Reliable against signature-based DPI; weaker against behavioral DPI (RTT/statistics). Effectiveness is empirical and depends on the specific DPI.

## Infrastructure — already in place (do not touch)

- `Awg` ([node_spec.dart:443](../../../app/lib/models/node_spec.dart)) stores `jc/jmin/jmax/s1-s4/h1-h4` (numKeys) + `i1-i5` (strKeys, case preserved).
- `emitWireguard` ([node_spec_emit.dart](../../../app/lib/models/node_spec_emit.dart)) writes AWG fields into the endpoint-JSON root (`Awg.writeInto`).
- `WireguardSpec.awg` carries them; `parseWireguardUri` reads `Awg.fromQuery` (i* as strings).
- `awgClampMtu` already clamps MTU to 1280 when AWG is present — our WARP is already 1280, matches.

## Code changes

1. **`WarpAccount`** — add optional field `Awg? awg`. Persist in storage (toJson/fromJson).
2. **`WarpClient.register`** — params `bool obfuscate`, `JunkTemplate template`. If obfuscate → build `Awg(1.5 preset)` + generate i1 with the chosen template, put into `WarpAccount.awg`.
3. **Junk generator** — new file `services/warp/awg_junk.dart`:
   - `enum JunkTemplate { wgTraffic, sipTraffic }`
   - `String generateJunkI1(JunkTemplate t)` → `<b 0x<hex>>`. `Random.secure()`.
   - `_wgTrafficJunk()` — fake type + `00 00 00` + random body (~1250b).
   - `_sipTrafficJunk()` — SIP-INVITE per RFC 3261 with randomized branch/tag/Call-ID/CSeq/user/domain → bytes(ascii). Uses `PseudoGen` (§127) for user/host.
4. **`WarpWizardScreen`** — `CheckboxListTile` **"Add Amnezia 1.5 obfuscation"** (significant option — do NOT hide in Advanced, default off). When enabled — template selection (radio/segmented: **WG-traffic** / **SIP-traffic**, default WG). Caption: "Masks WireGuard from DPI by adding junk traffic. Enable if WARP is blocked."

### Node-add path — via `.conf` (INI), DECIDED

**URI length limit — NOT a problem (verified in code 2026-06-15):** `maxURILength = 65536` ([uri_utils.dart](../../../app/lib/services/parser/uri_utils.dart)), while i1 ~1700 bytes hex = ~3400 chars in the query — ×19 headroom. Also `parseWireguardIni`→`parseWireguardUri` **bypasses** the length check (it lives only in the `parseUri` dispatcher). The original length concern is dropped.

**Decision — build a `.conf` (INI text) and parse with `parseWireguardIni`** ([ini_parser.dart](../../../app/lib/services/parser/ini_parser.dart)):
- The parser **already reads AWG fields** from `[Interface]` (`Jc/Jmin/.../I1-I5`, lines 54-58), value case preserved.
- **i1 is already encoded correctly** — `Uri.encodeComponent` escapes `<`/`>`/space (line 107).
- `rawIni` is preserved in the spec (clean round-trip, line 24).
- The `.conf` format = **exactly what the Amnezia 1.5 generator emits** → 1:1, no transforms.

```
WarpAccount(+awg) → build .conf text ([Interface] PrivateKey/Address/Jc/.../I1 + [Peer] PublicKey/Endpoint/AllowedIPs/Reserved)
                  → parseWireguardIni(conf) → WireguardSpec(awg, reserved)
                  → UserServer → _entries
```

`addWarp` for the obfuscate branch builds `.conf` instead of `toWireguardUri()`. Plain WARP (no checkbox) stays on the existing URI path (short, no i1).

**NB on `reserved` in .conf:** the Amnezia generator puts the WARP `client_id` via an analogous key. Verify that our `parseWireguardIni`/`_iniToUri` carries `reserved` through (currently it does NOT list it in `[Peer]` — lines 59-63). If not — add reading `reserved`/`client_id` in `[Peer]` (trivial, mirroring the AWG handling from `[Interface]`), or carry reserved as a separate query param when building the URI inside `_iniToUri`.

## Acceptance

- [ ] Checkbox in the wizard, default off; off = current plain WARP (byte-for-byte).
- [ ] On → the WARP node has 1.5-preset AWG fields in the endpoint-JSON; i1 is generated by the chosen template (WG/SIP), differs across two registrations.
- [ ] s1=s2=0, h1..h4=1,2,3,4 → the handshake stays a valid WG (Cloudflare accepts); device-smoke: traffic flows.
- [ ] i1 (~1700b) does not break node-add (via `.conf`/`parseWireguardIni`); `reserved` (WARP client_id) reaches the endpoint-JSON.
- [ ] Tests: preset is applied; i1 is random (≠ between calls); off = awg==null.
- [ ] Device-smoke against real DPI (or at least that the node connects with AWG fields).

## NB

- Effectiveness against a specific DPI is empirical; the 1.5 preset is a working starting point, values can be tuned.
- The sing-box-lx core already handles AWG 2.0 (§097/§112) — the core (client-side in the core) part is ready, this is pure config.
