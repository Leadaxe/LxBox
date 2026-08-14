# The core — sing-box-lx (fork)

Everything about the L×Box VPN core: where we get it, how it is pinned, which
build tags it carries, and the gotchas of a version bump. ARCHITECTURE.md links
here.

## What it is

The core is our fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(the working and release branch is `lx`; `lx-1.14` is an archived anchor for the
finished migration to 1.14; for the upstream base see “The current pin” below):
upstream sing-box plus AmneziaWG 2.0, native XHTTP, VLESS encryption (the PQ
layer) and LxBox-specific features (idle-suspend, the round-robin balancer, DNS
groups, the DNS stream and more).

Control goes through the **libbox CommandClient** (§122; the Clash HTTP server
was removed).

## Where the AAR comes from

| | |
|---|---|
| Version pin | `app/android/libbox.version` — the single source of truth (local and CI) |
| Download | `scripts/fetch-libbox.sh` → `libbox.aar` from the fork's GitHub Releases plus a SHA256 check; idempotent (the `.libbox.version` marker) |
| Called from | `scripts/build-local-apk.sh` and CI (`ci.yml` → the android job → “Fetch sing-box-lx core”) |
| The AAR in git | NO (~110 MB as of lx.25; `app/android/app/libs/` is in `.gitignore`); `build.gradle.kts` → `implementation(files("libs/libbox.aar"))` |

**The current pin: `v1.14.0-lx.25-rc.5`** (see `app/android/libbox.version`) —
the final name of the `masque` key (`vhttp`) plus the urltest group's mode in the
API. The client side is §393.

**`transport` → `vhttp` (SPEC 062).** The name from rc.4 was removed **with no
alias**: for vless/trojan/vmess `transport` is the V2Ray transport key, and it is
an object (`{"type":"ws"}`), not a string. One name with two meanings and two
types is exactly the confusion SPEC 062 removes. The interim name lived through a
single prerelease; the client does not support it at all (it never went out — see
§393).

`network` remains deprecated until `v1.14.0-lx.30`, as announced in rc.4.

**`Group.mode` (SPEC 019)** — the mode of a urltest group: `least_test` (an
ordinary urltest, with the node in `selected`) | `round_robin` (balancing, with
the state in `GetPool`) | empty (not a urltest). Promised “in any build”, unlike
`GetPool`, which sits behind the `with_lx_command` tag.

⚠️ **The Android AAR of rc.5 does NOT have this field.** `classes.jar` is
byte-identical to rc.4 (SHA256 `23b2eb27…`), and
`javap io.nekohasekai.libbox.OutboundGroup` shows no `getMode()`. The native part
*is* built from rc.5 (`strings libbox.so` → `1.14.0-lx.25-rc.5`, and the
`least_test` / `round_robin` strings are present) — so the Go code is there, but
the gomobile binding for `OutboundGroup` was not regenerated. This does not affect
§393 (`vhttp` is config parsing, not a Java surface), but anyone who wants `mode`
has to wait for the next core build.

**The `masque` schema (introduced in rc.4).** The HTTP version moved from
`network` to `vhttp`, and the TLS options moved from the flat root into a nested
`tls{}` (`sni` → `tls.server_name`, `skip_cert_verify` → `tls.insecure`, and
`fragment` / `record_fragment` / `fragment_fallback_delay` under `tls`). The
remaining fields (`server`, `server_port`, `profile`, `private_key`,
`public_key`, `ip`, `ipv6`, `uri`, `mtu`, `idle_timeout`, `keep_alive_period`,
`network_list`) are unchanged. The old names are accepted until
**`v1.14.0-lx.30`**, and every such outbound prints one warning to the log.

⚠️ The same field given under both the old and the new name **with different
values** is fatal at startup (the error names both fields). Identical values are
not treated as a conflict. Hence the client rule in §393: emit only the new set of
names, never both at once; legacy lives strictly on the input side (the URI parser
and the JSON import).

The new field `tls.disable_sni` produces a ClientHello with no SNI. An empty `sni`
did NOT do that — it was replaced by the profile's default.

The core now **warns** (it used to stay silent) about fields unsupported for
masque: `tls.alpn`, `tls.ech`, `tls.reality`, `tls.kernel_*`, and about
fragmentation when `vhttp: h3`.

**The default SNI changed:** `consumer-masque.cloudflareclient.com` →
`www.cloudflare.com`. This affects configs with NO explicit SNI; an explicit value
still wins. The reason (core measurements on two independent Russian networks):
with the previous name the h3 tunnel to the endpoint does not come up. The name is
not critical for authentication — the endpoint is verified by pinning its ECDSA
key.

⚠️ This diverges from `assets/warp_endpoints.json`, where `recommended_sni` is
`consumer-masque.cloudflareclient.com` (commit 9d5629ba) — exactly the name the
core found non-working on h3. Revisiting that recommendation was split out of
§393.

Diagnostics: `masque: CONNECT-IP timed out` instead of a wall of
`http3: parsing frame failed` when the endpoint accepted QUIC but never answered
CONNECT-IP. The original cause is preserved in the error chain.

The previous pin — **`v1.14.0-lx.25-rc.4`** — carried the same config schema under
the name `transport` (removed in rc.5) plus the default SNI change. Its Java
surface equals rc.3.

Before that — **`v1.14.0-lx.25-rc.3`** — two changes on top of rc.1, both about
the TLS leg under `detour`.

**SPEC 060: `record_fragment` turns itself on when an outbound dials through a
`detour`.** The symptom: a chain like `MASQUE detour VLESS` hung for about 15
seconds and died with `tls handshake: EOF`, from which the cause cannot be
reconstructed. The cause is neither the core nor the SNI: the lower leg forwards
our ClientHello under its own name, and if the PMTU beyond that leg is smaller
than the ClientHello, the packet is lost silently — the ICMP “fragmentation
needed” never reaches the client. The threshold is purely about size (1488 B gets
through, 1502 B vanishes) and belongs to the path beyond the leg rather than to
the protocol: on other nodes the same bytes pass straight through. It reproduces
with bare `curl`, without sing-box. The mechanism already existed in the core
(`fragment` / `record_fragment`) — what was missing was the default. There is a
single injection point, `NewClientWithOptions`, before the engine is chosen, so
STD, uTLS and REALITY all get the same default.

⚠️ The default changes the behaviour of **any** outbound with a `detour`, not just
MASQUE chains. An explicit user choice always wins; `fragment: true` is not
upgraded by adding a record split. The cost is bounded by the handshake — only the
first TLS record is rewritten, and an established stream is untouched. The direct
path (with no `detour`) is unaffected.

**SPEC 021: MASQUE h2 moved onto the shared `common/tls`.** It used to be the only
outbound bypassing the shared layer: on h2 it drove TLS through a bare
`crypto/tls.Client` for the sake of pinning the endpoint's ECDSA key — and in
exchange it received nothing from the shared layer (including the new SPEC 060
default). Now h2 goes through the shared client and the pinning sits on top of it.
h3 is untouched: QUIC does not carry TLS over TCP.

The Java surface **did not change** — `classes.jar` is byte-identical to rc.1 (the
same SHA256), no `javap` diff is required and no client changes are needed.

⚠️ This is an **rc**: build the device run around detour configs in general rather
than around a single chain, and separately verify that an explicit
`fragment: true` is not upgraded. The tail of rc.1 (below) is also still open.

Before that — **`v1.14.0-lx.25-rc.1`** — **SPEC 058: `GetURLViaOutbound`**, a
diagnostic HTTP GET through a node addressed by tag, returning the response BODY.
It closes the class of questions `URLTestOutbound` cannot answer: not “is the node
alive” but “what can be seen through it” (the exit IP, geo, `warp=`). The active
selector does not switch, so live connections stay intact. The consumer is §392
(the Diagnostics tab on the node screen).

The Java surface **did change**: `+GetURLResult`, `+HTTPHeaders`,
`CommandClient.getURLViaOutbound(String,String,int,int,HTTPHeaders)`.
⚠️ GOTCHA: the getters on `GetURLResult` carry **no `get` prefix** — `content()`,
`status()`, `truncated()`, `contentType()`, `remoteAddr()`, `elapsedMs()` (unlike
`URLTestOutboundResult.getDelay()`): gomobile strips the prefix when the Go field
name does not start with `Get`. The binding calls exactly those short forms.

The call contract (details in kernel SPEC 058): GET only; `maxBytes` 0 → 256 KiB
with a 1 MiB ceiling, and truncation is flagged as `Truncated`; **a non-2xx is a
result, not an error** (403 and 429 arrive with a body); `RemoteAddr` is the
address from inside the tunnel, NOT the node's exit IP (the body carries that);
`ElapsedMs` is not written into the urltest history. A probe is real traffic and
wakes sleeping WG, so it happens only on an explicit user action — background
sweeps over the list are forbidden on the client side.

⚠️ This is an **rc**: the field check from a device (`cdn-cgi/trace` through a WG
endpoint and through a vless outbound; HTTPS without custom roots) is not closed
in the core's criteria.

Before that — **`v1.14.0-lx.24-rc.2`** (v2.20.7) — catching up with upstream and a
toolchain change, with no changes to the lx-layer code. The branch sits on top of
`upstream/testing` again (base `v1.14.0-beta.9`): out of 19 new upstream commits
the notable ones are that the local transport's DNS caches are partitioned by
interface signature (a network change no longer serves someone else's cache); the
WireGuard handshake resolves **every** address of a domain peer and races them
(`SetEndpointResolver`); hijacked DNS gained process info; plus fixes to reset
network, FakeIP async-save, the Android process finder, unbounded allocations on a
malicious SRS and the OOM stub. The build toolchain is go1.26.5, following
upstream (the SPEC 044 principle). The fork's submodules were rebased before the
core: sing-tun (with SPEC 040 on top) and wireguard-go (AWG2 plus SPEC 041 on top;
`SendHandshakeInitiation` = AWG padding/junk plus the upstream fan-out). The Java
surface did not change — `classes.jar` is byte-identical to lx.22 (the same
SHA256), so no `javap` diff is needed.

The intermediate `lx.23` and `lx.24-rc.1` are about the `lxd` daemon (desktop,
SPEC 056/057): they do not affect the Android build, which is why the pin jumps
from lx.22 straight to lx.24-rc.2.

⚠️ This is an **rc, not a stable**: the core's release notes require a device run
(tunnel, DNS, URL test, WG/AWG — several times) before lx.24 is promoted to
stable, because of the submodule rebase (runbook §1.4) and the toolchain change
(SPEC 044, the hy2/quic profile).

Before that — **`v1.14.0-lx.22`** (v2.20.6) — two changes. **SPEC 054**:
`least_test` reacts to failures of real dials — a penalty for a “the path is
dead” class of failure (a dial timeout, `EHOSTUNREACH` / `ENETUNREACH` /
`ETIMEDOUT`), one fallback dial through the best candidate (capped at two
attempts), and moving the group's selection on a successful fallback without
tearing down live connections. `ECONNREFUSED` / `ECONNRESET` and
`context.Canceled` carry no penalty. At three penalties on the leader an emergency
mode kicks in: ranking first by penalties, then by latency; a penalty is only
lifted by proof of life, and nothing resets on a timer; if everything is
penalised, probes are forced no more than once every two minutes and probe
skipping via `passive_check` is disabled for that period. There are no new timers
— deltas come from a timestamp, so it survives sleep and freezing. This is a
direct continuation of SPEC 052: that one produced a fast failure signal, but
nothing consumed it. **SPEC 053**: REALITY declares `minClientVer` 26.3.27 — Xray
since v26.7.11 requires a minimum client version by default and silently serves
the camouflage site instead of refusing when it does not match. The Java surface
did not change — 226 classes, a 0-line `javap` diff.

Before that — **`v1.14.0-lx.21`** (v2.20.5) — SPEC 052: a 15-second connect
deadline on netstack dials (the WG/AWG endpoint and the per-connection dials of
MASQUE, openvpn, openconnect and tailscale that share it). Until then this was the
only class of dial paths with no timeout: `C.TCPConnectTimeout` lives only in the
system `net.Dialer`, netstack paths bypass it structurally, and the only boundary
was gVisor's SYN backoff — 6 retransmits, about 127 s to an error, times N
addresses for a domain. The Java surface did not change. The pins before that were
`v1.14.0-lx.20` (promoting the branch to stable, with no code changes relative to
rc.8) and `v1.14.0-lx.20-rc.8` (v2.20.4).

On rc.8 — a technical release on top of rc.7 that changes no behaviour. It removed
two merge traps: twice in a row (235 commits, and 217 in rc.7) the same two files
broke in the same way, and the breakage is invisible when reviewing the merge. The
cause was not that upstream deleted something — it simply does not have that code;
what broke was the **shape** of our additions: both sat where both sides append,
and the merge glued them into something nobody wrote, without a conflict. The cure
is structural rather than a patch: the idle-suspend interfaces were moved into
their own file together with their import (the source file became byte-identical
to upstream, so there is nothing left to glue there), and the check when releasing
a sleeping endpoint was collapsed into a single call instead of a block next to
upstream's closing line (our difference inside the function is now one line, so a
future upstream change will collide with it loudly rather than swallow it
silently). The tree was checked for additions of the same shape — there are no
others.

The substance arrived in **`v1.14.0-lx.20-rc.7`** — the fork's base was moved onto
upstream `v1.14.0-beta.8`, 217 commits were carried over, and every dependency was
set to exactly the revision upstream expects. Of note for the client: a TUN
dispatcher deadlock, more stable URLTest results, a Tailscale state observer (the
upstream variant was taken — it does not block and survives a broken notification
bus, which ours did not), and updated gvisor/QUIC. The fork's features are all
present: the detour chain, the DNS query stream, the URLTest pool, idle-suspend,
AWG obfuscation and all eight extended client commands. The merge itself
introduced two defects, both caught before release: an upstream line under our
check in the path that releases a sleeping endpoint (a use-after-free — caught by
the idle-suspend regression test, not by the build) and a lost import of the sleep
interface (caught by the build).

⚠️ The order when bumping dependencies: **dependencies first, then the merge.** The
reverse order is what broke the rc.5 build (see below).

The Java surface did not change between rc.6 and rc.7: 226 classes in both, a
`javap` diff of **0 lines of difference**, and no client changes required.

Along the way the pin passed through **`rc.6`** (a fix for the startup crash
introduced by rc.5: the WireGuard component there had fallen 14 commits behind and
only 3 were taken — the ones the compiler complained about; among the remaining 11
were race fixes and a lock rework, i.e. a combination upstream never had. In rc.6
the component was taken whole and our changes laid on top), **`rc.5`** (two months
of upstream, 235 commits; OpenVPN/OpenConnect as connection types — no field
experience, SPEC 051), **`rc.4`** (SPEC 050: node checks got stuck forever against
a silent server and survived stopping the VPN, holding the entire node list — 2806
nodes from an already-unloaded subscription; the group waits for every check before
publishing, hence the empty ping column and the memory growth until the app was
shot) and **`rc.3`** (SPEC 047 — a crash on a network change while the tunnel was
starting: “reset network” was let through as soon as the core object existed, while
the tunnel was not yet assembled; SPEC 048 — a whole-process crash on a connection
to a dead node, where state was freed before the formal close and a late packet
landed in freed memory; SPEC 049 — the Go toolchain version is recorded in
`go.version`, and `go.mod` is no good for that: it holds the language floor 1.24,
on which every QUIC protocol fails).

The pin before those — **`v1.14.0-lx.20-rc.2`** (v2.19.3) — **SPEC 046**: hijacked
DNS queries moved off the tun stack's packet loop. Resolution used to happen right
in the loop, and calling the resolver blocks the caller for the duration of the
lookup — so a DNS server with a `detour` onto a black-hole node held the loop for
the entire DNS timeout, and NOTHING went through the tunnel (other DNS, ICMP, new
connections of any protocol). A background trickle of queries was enough to keep
the tunnel frozen almost continuously. Exchanges now happen outside the loop, with
a ceiling of 256 concurrent ones (beyond that they are dropped and the client
retries — normal for UDP). The bug is older than this release and lived in both tun
stacks. The Java surface did not change (a `javap` diff rc.1↔rc.2 of 0 lines) and
no client changes were needed.

On top of that came what had already arrived in **`v1.14.0-lx.20-rc.1`**: there
were no Go code changes on top of lx.19 there, only the build toolchain — all
twelve of the fork's build jobs are pinned to Go 1.25.x (upstream parity, SPEC
044), while the Android AAR moves **down** from 1.26.x to that same 1.25.x. The
defect threshold for vendor kernels is “>= 1.25”, and both versions (1.25.5 and
1.26.5) are device-verified, so this is a change within a verified range. `go.mod`
is untouched (it says `go 1.24.7`, which is a language floor rather than a
toolchain choice).

The pin before those — **`v1.14.0-lx.19-rc.3`** (v2.19.2) — three fixes on top of
lx.18: SPEC 041 v2 (the event-driven nudge `RebindStaleEndpoints`, consumed by
§340), SPEC 044 (an AAR built with Go 1.24 killed ALL quic-go outbounds on vendor
kernels — hysteria2/tuic/masque-h3; the fix is the Go 1.25 toolchain, §341) and
SPEC 045 (a nil panic on trojan/vless with `tls.enabled:false` during a URL test).

The pin before that — **`v1.14.0-lx.18`** (v2.19.1, §335) — VLESS `encryption`
(SPEC 032, feature VLESS_ENCRYPTION): the post-quantum layer
`mlkem768x25519plus` **inside** VLESS (it works instead of TLS — such nodes arrive
with `security=none`; not to be confused with REALITY). The field did not exist in
the core's schema before, so nodes carrying it were silently dead: the transport
came up (WS `101`, gRPC SETTINGS) and then the server tore the connection down
without a single line in the log. The client half is §335: the builder moves the
field from `vless://` links (the query) and Xray JSON (`users[0].encryption`) into
a flat field of the outbound next to `uuid`, emits it only when it is non-empty and
not `none`, and writes it back in `toUriVless` (otherwise it would be lost on a
round trip through §302 rules). Measured on a device: 12 genuine nodes came back to
life (ws 7/8, grpc 5/5), taking the subscription from 42 to 53 out of 76. The
libbox Java surface is unchanged — this is a config field, not an API. ⚠️ The flip
side is gotcha 2: a core older than lx.18 rejects a config with `encryption`
**entirely**, so bumping the pin and enabling the emit are one atomic step.

Along the way the pin passed through the stable **`v1.14.0-lx.17`** — the promotion
of the rc.1–rc.5 line plus XHTTP fixes that never shipped in an rc: SPEC 042 (the
`application/grpc` Content-Type on streaming requests — parity with Xray) and SPEC
043 (the root of the complaint “the subscription's XHTTP nodes are dead” —
`stream-one` sent a path without a trailing slash, the server returned 404 and the
connection hung until the timeout; `auto`+REALITY goes into `stream-one`, hence the
false trail “auto is broken”). Device-verified: the subscription's XHTTP nodes came
back. Both fixes are inside the core, with no client changes.

**The previous pin: `v1.14.0-lx.17-rc.5`** (v2.19.0) — two self-healing fixes on
top of rc.3 (rc.4, below) plus the 01.08 upstream sync in rc.5: naiveproxy v150, a
DNS rule race (a completed rule was blocked by one armed earlier), the WireGuard
system device not configuring the interface's DNS, a TLS fragment on Windows
without TCP estats, and a routing loop on darwin. None of them required client
changes.

**rc.4 / SPEC 041** (feature HOTFIXES) — WG/AWG endpoints heal themselves after
the device sleeps, instead of an eternal ERR until a manual reconnect. While the
phone sleeps the tunnel's UDP 5-tuple dies along the path (the NAT mapping expires
and/or the DPI flow record goes stale), and upstream wireguard-go retries the
handshake into that same dead socket forever — the same source port, the same dead
5-tuple. A reconnect “fixed” it purely by opening a new socket with a fresh
ephemeral port. Now the core does that: when a peer's handshake retry cycle is
exhausted (about 90 s of unanswered initiations — an existing give-up event that
only fires under demand for traffic), the bind is reopened once with a fresh port
and a new handshake starts immediately. For masquerade profiles the `i1` decoy
leaves with the first initiation of the new 5-tuple, reopening the flow on the DPI.
The debounce is one rebind per give-up cycle; an explicitly pinned `listen_port` is
preserved (self-healing by changing the port is then unavailable, by design); and
both bind schemes (direct and through a `detour`) are healed by the same mechanism.
In a healthy state, while asleep and after closing it costs nothing — no timers, no
goroutines, no traffic: on a sleeping device the rebind degenerates into a no-op and
does not conflict with idle-suspend (SPEC 020).

**rc.4 / SPEC 040** (feature HOTFIXES) — the system TCP stack no longer dies
permanently when its listener is killed out from under the core. With
`stack: "system"` every new TCP connection from the TUN is NAT-rewritten onto a
local forwarder listener. Its accept loop treated **any** `Accept` error as
terminal and exited silently — so when something else in the shared Android process
closed that listener's fd (a stray close on a reused descriptor number — the very
§047 failure of “the browser is dead, QUIC is alive”), the stack kept running and
kept rewriting every new SYN onto a dead port. The OS answered with an instant RST:
any application got `ECONNREFUSED` in about 16 ms until the VPN was restarted, while
UDP/QUIC/DNS stayed alive. Reproduction on a device: roughly once per 8–36 fast VPN
restarts, worse on a “dirty” process — which is why it went uncaught for months.
sing-tun is now a fork submodule (`submodules/sing-tun`, pinned to the exact
upstream revision from go.mod) with a single-file patch: an unexpected `Accept`
error is logged with its errno (which names the culprit), the listener is recreated
on the same address, the forwarder port is republished atomically, and the loop
keeps serving. A deliberate `System.Close()` still stays silent. The recovery
counter doubles as telemetry: if it ticks, the client-side trigger closing the fd is
still alive. Device-verified on 01.08.2026 (§329): two live occurrences, **errno =
`EINVAL`**.

**rc.2:** rotation of the report archive (SPEC 039 / feature HOTFIXES) — the
`files/oom_reports` and `files/crash_reports` directories were never cleaned, and
**575 directories / 427 MB accumulated over 19 days** on the device; now, before
writing a new report, the archive is trimmed to **32 directories and 64 MB**
(whichever hits first), deleting by mtime rather than by name (the collision
suffixes `-1`…`-1000` break lexicographic order). Plus **240 upstream commits**:
notable for the fork is that URLTest now *requires* history storage in the context
instead of silently creating it. **rc.3:** `Endpoint.Close()` returns the tun
device's close error again (the nil guard from SPEC 020 swallowed it and reported a
clean shutdown); the nil check stayed, only the error propagation changed. **The
javap diff rc.1 → rc.3: NO changes** — `PlatformInterface`, `CommandClient`,
`BoxService` and `Libbox` are identical, and the class set matches (226 in both
AARs). Device-verified on 30.07.2026 (CPH2411): a clean start, an empty
`last_start_error`, 0 errors or fatals in the logs, 54 live measurements.

Take care when bumping through rc.2: it carries 240 upstream commits, so a javap
diff is mandatory even when the release notes promise a “one-line fix” — and it has
to be checked against **your** pin, not against the previous rc. Both rc.4 fixes
live entirely inside the core (the wireguard-go bind and the sing-tun accept loop)
and do not touch the Java surface, so no client changes were needed.

**The previous pin: `v1.14.0-lx.17-rc.1`** — SPEC 038: `GetRunningConfig` returns a
`RunningConfig` object with a `content()` getter instead of a bare `String`. The
bare string **killed the core process on android/arm64 on every call**: gomobile
encodes a Go string as `nstring{void*, len}`, cgo puts it into a `__packed__`
frame, that loses 8-byte alignment, and assigning a slot holding a pointer goes
through `runtime.wbMove` → `bulkBarrierPreWrite` → `throw: unaligned arguments`.
That is not a panic but a fatal throw — the tunnel died with no chance. The defect
was introduced by SPEC 037 (GetRunningConfig; earlier notes called it “SPEC 036”,
a number later freed in the core and now meaning something else), so §311 was
inoperable both in rc.3 and in the stable `lx.16`; that is exactly how the core died
on 26.07 (found through the §316 channel). **The javap diff lx.16 → lx.17-rc.1:**
the only change is that `getRunningConfig()` returns `RunningConfig` instead of
`String`; `PlatformInterface`, `CommandClientHandler` and `Libbox` are unchanged.
The client change is that `BoxCommandClient.getRunningConfig()` calls `.content()`.
Device-verified on 27.07.2026 (CPH2411): 6 consecutive calls with a live tunnel →
200, the core alive, no new crashes.

**The previous pin: `v1.14.0-lx.16`** (stable) — SPEC 037:
`CommandClient.GetRunningConfig`, a canonical snapshot of the RUNNING core's config
(captured once at start in `newInstance`, post-override, re-marshalled; a copy of
the string is returned). The client half is §311 in LxBox (`activeModel`,
`GET /config/running`): it closes the “a rebuild while the tunnel is live” window
and the false “Not found” on a visible node. The javap diff against lx.15:
`+ String getRunningConfig() throws` on `CommandClient`; `PlatformInterface` and
`CommandClientHandler` UNCHANGED. RPC errors: not-STARTED → `FailedPrecondition`,
an attached path or a capture failure → `Unavailable`, and without
`with_lx_command` → `Unimplemented` — the binding swallows all of them into null.

`lx.15` (the one before) — SPEC 002: XHTTP no longer breaks behind a reverse proxy.
VLESS+XHTTP through nginx or a CDN with `mode: packet-up`, a trailing-slash `path`
(`/upload/`) and `session_placement: header` used to fail with
`unexpected download status: 301 Moved Permanently` (the client unconditionally
stripped the trailing slash for ALL modes; nginx `location /upload/ {}` answered
with a 301 redirect to the bare path, and the download request — raw HTTP/2 with no
redirect following — surfaced that as a dial error). The fix: `path` is preserved
as-is, and the trailing slash is stripped only on the bare-path stream-one request.
Default configs (a session id in the path) were never affected. Covered by a
url_test case. Plus a merge of upstream `testing` (13 commits: the async DNS
refactor, a WG detour fix that converges with SPEC 029, OpenConnect
auth-challenge and other fixes). Upstream base `v1.14.0-alpha.48`. AAR build tags
unchanged. **Device-verified** on CPH2411 (2026-07-21): a crash-free start, the
Debug API answering, the VPN coming up. The version history is at the end of this
file.

`lx.14` — SPEC 030: stopping the tunnel no longer hangs for 10+ seconds with many
WG/AWG endpoints (the teardown in `box.Close()` waited for an in-flight ping wake;
the fix is closing the endpoints concurrently while interrupting the wake, with no
teardown step skipped). The core half of §287.

### The AAR before a core release

While the fork has not yet cut an official release (work on an rc chain), the AAR
comes from the artifact of the fork's CI run, NOT from Releases:

```bash
gh run download <run-id> --repo Leadaxe/sing-box-lx --name dist-android
```

The downloaded `libbox.aar` is placed into `app/android/app/libs/` by hand (with
the `.libbox.version` marker set to the right rc, otherwise `fetch-libbox.sh` will
re-download it). This is how §215 (rc.18) and the pre-release rc.21/rc.22 for
v2.9.0 were prepared (MASQUE symbols were verified with `strings libbox.so`).

- ⚠ Do **NOT** commit `app/android/libbox.version` before the core is released — a
  pin on a tag that does not exist in Releases breaks the fetch for everyone else
  and in CI.
- ⚠ In production, use **only the official release AAR** (see gotcha 3).

## AAR build tags

They are baked in `cmd/internal/build_libbox/main.go` (`sharedTags`), NOT in the
client:

```
with_gvisor, with_quic, with_wireguard, with_utls, with_naive_outbound,
badlinkname, tfogo_checklinkname0,
with_xhttp, with_awg, with_lx_command, with_lx_idle_suspend
```

`with_clash_api` is deliberately absent (§122 — CommandClient instead of Clash
HTTP); `with_usbip` and `with_openvpn` / `with_openconnect` are deliberately
omitted too (server-side or outside the client's scope — see the comments in
`build_libbox`).

## ⚠️ Gotchas when bumping the version

### 1. `with_lx_idle_suspend` (rc.19+) — idle-suspend behind a build tag

The idle-suspend tick machinery (`route.lx_idle_suspend`, SPEC 020 / §128) is
compiled **only** with the `with_lx_idle_suspend` tag. **Without it,
`route.lx_idle_suspend` in a config KILLS the core's startup**
(`rebuild with -tags with_lx_idle_suspend (mobile-only feature)`).

- The mobile **AAR** carries the tag (`build_libbox` sharedTags), so the official
  release AAR is fine.
- The desktop/CLI `sing-box` (for `sing-box check`) does NOT have the tag by
  default. Validating a config containing `lx_idle_suspend` through the desktop
  binary will fail without an explicit `-tags with_lx_idle_suspend`.

### 2. A new transport or route field → “unknown field” kills the WHOLE config

The core decodes configs strictly: if the client emits a field an older core does
not know, the **entire** config fails to load, not just the one node. The classic
“the parser outran the core” desync:
- §214: rc.15 did not know `sc_max_each_post_bytes` (XHTTP SPEC 002 v2) → bumped to rc.16.
- Diagnosis: `/device` core_version (§213) — the real core version inside the APK.

### 3. A gomobile AAR is not byte-reproducible

The sha of a local build ≠ the sha of the release AAR (paths and timestamps inside
the archive). They are functionally identical. `fetch-libbox.sh` verifies the sha
of what it downloaded against the release `SHA256SUMS` — which is why production
**always** uses the official release AAR rather than a local one.

### 4. `Libbox.version()` is not visible through `strings`

A gomobile binary does not expose the version string. Verify the core version only
through `/device` core_version on the device, not by pulling strings out of the
AAR.

### 5. The order inside `redirectStderr` — §334 depends on it

`experimental/libbox/log.go:69-77`: `Setup` first archives
`CrashReport-<source>.log` into `crash_reports/`, and only then does `os.Create`
truncate the file for the new session.

§334 (`CrashRecovery`) stands on that order: the “the previous run crashed”
detection reads a non-empty report BEFORE `Libbox.setup()`, and the truncation
inside `setup` serves as the “one crash, one cleanup” dedup. If a bump moves the
archiving after `os.Create`, the §316 banner will start losing crashes; if the
truncation disappears, the cache will be reset on every launch after a single
crash.

To check on a bump: `archiveCrashReport` is called before `os.Create`, and the
early return on `len(content) == 0` (`log.go:29`) is still inside it — that is the
same “non-empty means there was a crash” criterion our detection uses.

## Client versus core: which side to fix a config bug on

Sometimes a “this node kills the config” bug is fixed from both sides
(defence in depth):
- **the client** — do not emit anything invalid, and show the user a ⚠️
  (visibility). Example: §217 (XHTTP `uplink_http_method=GET` outside packet-up →
  reset plus `XhttpParamResetWarning`).
- **the core** — a soft fallback instead of a fatal. Example: rc.20 `c0bbb1c5` —
  the same GET→POST fallback plus a WARN, so that one malformed node does not take
  the whole config down.

Both layers earn their keep: the client provides visibility (a ⚠️ in the
subscription), the core provides insurance in case the client misses something.

## Version history (the LxBox-relevant parts)

| rc | What was added |
|---|---|
| rc.15 → rc.16 (§214) | XHTTP SPEC 002 v2 fields (otherwise an unknown field kills the config) |
| rc.18 (§215) | SPEC 020 idle-suspend (`route.lx_idle_suspend`) |
| rc.19 | idle-suspend behind `with_lx_idle_suspend` (mobile-only, see gotcha 1) |
| rc.20 | The XHTTP GET→POST soft fallback (duplicating §217); a udpnat2 buffer fix; an upstream sync |
| **v1.14.0-lx.1** (stable) | The first stable release of the `lx-1.14` branch (rc.16→rc.22): the MASQUE outbound (§130) and stabilisation; shipped with LxBox v2.9.0 |
| **v1.14.0-lx.11** (stable) | The AWG-over-WireGuard guard was removed (SPEC 007) — AWG-over-AWG/WG now comes up. Device-verified on CPH2411. (The intermediate lx.2…lx.10: idle-suspend L3, the balancer, Force IPv4, the memory limit, AWG padding and reserved-clear fixes — see `docs-lx/lx-changelog.md` in the core) |
| **v1.14.0-lx.14** (stable) | SPEC 030 — Stop no longer hangs for 10+ seconds with many WG/AWG endpoints (silencing the tick, closing UDP sockets upfront, aborting the in-flight wake, and a concurrent close). The core half of §287. Upstream base `alpha.47`. AAR build tags unchanged. (The intermediate lx.12/lx.13 — see `docs-lx/lx-changelog.md` in the core) |
| **v1.14.0-lx.15** (stable) | SPEC 002 — XHTTP behind a reverse proxy: `path` is preserved as-is, and the trailing slash is stripped only on the bare-path stream-one request. Plus a merge of upstream `testing` (the async DNS refactor, a WG detour fix, OpenConnect auth-challenge). Upstream base `alpha.48`. AAR build tags unchanged. Device-verified on CPH2411 (2026-07-21) |
| **v1.14.0-lx.25-rc.3** | SPEC 060 — `record_fragment` turns itself on when an outbound dials through a `detour`. The symptom: `MASQUE detour VLESS` hung for about 15 s and died with `tls handshake: EOF`. The cause is that the lower leg sends our ClientHello under its own name, and when the PMTU beyond that leg is smaller than the ClientHello the packet is lost silently (the ICMP “fragmentation needed” never reaches the client). The threshold is purely about size (1488 B gets through, 1502 B does not) and belongs to the path rather than the protocol; it reproduces with bare `curl`. There is a single injection point, `NewClientWithOptions`, before the engine is chosen, so STD/uTLS/REALITY get the same default. ⚠️ It changes the behaviour of ANY outbound with a `detour`, not just MASQUE. An explicit user choice wins and `fragment: true` is not upgraded; only the first TLS record is rewritten; the direct path is unaffected. SPEC 021 — MASQUE h2 moved onto the shared `common/tls` (it was the only outbound bypassing the shared layer: a bare `crypto/tls.Client` for the sake of pinning the endpoint's ECDSA key), with the pinning moved on top of the shared client; h3 untouched. The Java surface did not change — `classes.jar` is byte-identical to rc.1, no `javap` diff needed. ⚠️ rc: a device run over detour configs in general, plus a check that an explicit `fragment: true` is not upgraded |
| **v1.14.0-lx.25-rc.1** | SPEC 058 — `GetURLViaOutbound`: a diagnostic HTTP GET through a node by tag, returning the response BODY (exit IP, geo, `warp=`), without switching the active selector. The consumer is §392 (the Diagnostics tab). The Java surface **did change**: `+GetURLResult`, `+HTTPHeaders`, `CommandClient.getURLViaOutbound`. ⚠️ GOTCHA: the getters on `GetURLResult` carry **no `get` prefix** (`content()`, `status()`, `elapsedMs()`) — gomobile strips it when the Go field does not start with `Get`. GET only; `maxBytes` 0 → 256 KiB (1 MiB ceiling, truncation = `Truncated`); a non-2xx is a result, not an error; `RemoteAddr` is the address from inside the tunnel, not the exit IP; `ElapsedMs` is not written into the urltest history. ⚠️ rc: the field check from a device is not closed in the core's criteria |
| **v1.14.0-lx.24-rc.2** (v2.20.7) | Catching up with upstream (19 commits on the `v1.14.0-beta.9` base) plus the go1.26.5 toolchain, following upstream (SPEC 044). No changes to the lx-layer code. From the upstream tail: the local transport's DNS caches are partitioned by interface signature; the WG handshake resolves every address of a domain peer and races them (`SetEndpointResolver`); hijacked DNS carries process info; plus fixes to reset network, FakeIP async-save, the Android process finder and unbounded allocations on a malicious SRS. The submodules were rebased before the core (sing-tun plus SPEC 040, wireguard-go plus AWG2/SPEC 041). The Java surface did not change — `classes.jar` is byte-identical to lx.22. ⚠️ rc: the core's release notes require a device run (tunnel/DNS/URL test/WG/AWG) before lx.24 is promoted to stable. lx.23 and lx.24-rc.1 concern the desktop `lxd` daemon and do not affect Android |
| **v1.14.0-lx.22** (v2.20.6) | SPEC 054 — `least_test` reacts to failures of real dials (a “the path is dead” penalty, a fallback dial through the best candidate, emergency ranking at three penalties on the leader). SPEC 053 — REALITY declares `minClientVer` 26.3.27: Xray since v26.7.11 silently serves the camouflage site on a mismatch. The Java surface is unchanged (226 classes, a 0-line javap diff) |
| **v1.14.0-lx.21** (v2.20.5) | SPEC 052 — a `C.TCPTimeout` connect deadline (15 s) on netstack dials: the WG/AWG endpoint (`DialTCPWithBind`, whose stackDevice is shared by the per-connection dials of MASQUE) plus openvpn/openconnect/tailscale through the submodule's `gonet.DialTCPWithBind`. Previously the only boundary was gVisor's SYN backoff (1+2+4+8+16+32+64 = about 127 s; the `TCPSynRetriesOption` knob is dead in our gVisor pin), times N addresses for a domain via `DialSerial`. The symptom: a silent black hole (Wi-Fi cutting UDP to the node, a radio that has gone to sleep) reads as “everything hangs with no error”, leaving the group nothing to react to. 15 s rather than 5 because the budget is shared with the group's health check: a deadline below the probe's would give “the node passes probes but every user dial through it fails”. Measured: 2m07s → 15.05s. The Java surface is unchanged and no client changes are needed |
| **v1.14.0-lx.20** (stable, v2.20.5) | Promoting the `lx.20` branch to stable: substantively equal to rc.8, no code changes. For the branch's contents (SPEC 047 a crash on a network change at startup, SPEC 048 a crash on a connection to a dead node, SPEC 050 stuck node checks, SPEC 051 closing the gap to upstream — 217 commits on the `v1.14.0-beta.8` base) see the v2.20.4 entry in CHANGELOG |
| **v1.14.0-lx.19-rc.3** (v2.19.2) | SPEC 045 — a nil panic during a URL test of trojan/vless nodes with `tls.enabled:false` (the ping test killed the core). No client changes |
| **v1.14.0-lx.19-rc.2** (part of v2.19.2) | **SPEC 044** — an AAR built with Go 1.24 (as the CI did) killed ALL quic-go outbounds (hysteria2/tuic/masque-h3) on devices with a vendor kernel: every dial hung until `context deadline exceeded` and the ping test was permanently `-1`. The same source on Go 1.25 works. The fix is a toolchain change in the core's CI. The client half of the investigation is §341 (the Debug API `/action/quic-knobs`). ⚠️ an emulator with a generic kernel does NOT reproduce the defect |
| **v1.14.0-lx.19-rc.1** (part of v2.19.2) | SPEC 041 v2 — an early rebind (about 15 s instead of about 90) plus the event-driven nudge `CommandServer.RebindStaleEndpoints()`: it rebinds only provably dead sessions (no keypair, or a handshake older than 180 s) and is a no-op for the rest. The consumer is §340 (a wake nudge on `USER_PRESENT`). A new export on the Java surface |
| **v1.14.0-lx.18** (v2.19.1) | SPEC 032 — VLESS `encryption` (`mlkem768x25519plus`, a PQ layer inside VLESS): the field appeared in the core's schema and `security=none` nodes with the crypto layer came back to life. The client side is §335 (moving the field from the subscription into the config, plus the URI round trip). Measured on a device: +12 genuine nodes (ws 7/8, grpc 5/5), the subscription going from 42 to 53 out of 76. A config feature, so the Java surface is unchanged. ⚠️ a core older than lx.18 rejects a config with the field entirely |
| **v1.14.0-lx.17** (stable) | Promoting rc.1–rc.5 plus XHTTP fixes that never shipped in an rc: SPEC 042 (the gRPC Content-Type on streaming requests, parity with Xray) and SPEC 043 (the trailing slash of the `stream-one` path — the root of “the subscription's XHTTP nodes are dead”, a 404 turning into a hang). Device-verified, no client changes |
| **v1.14.0-lx.17-rc.5** (v2.19.0) | The 01.08 upstream sync on top of rc.4: naiveproxy v150, a DNS rule race (a completed rule blocked by one armed earlier), the WireGuard system device not configuring the interface's DNS, a TLS fragment on Windows without TCP estats, a routing loop on darwin. Plus device verification of SPEC 040. Does not touch the Java surface |
| **v1.14.0-lx.17-rc.4** (part of v2.19.0) | SPEC 041 — WG/AWG endpoints heal themselves after the device sleeps (a rebind with a fresh port once the handshake retries are exhausted, about 90 s; a manual `listen_port` disables the self-healing). SPEC 040 — the system TCP stack: the accept loop recreates a killed listener instead of exiting silently (sing-tun as a fork submodule); this closes the §047 failure of “the browser is dead, QUIC is alive”, with the errno on the device being `EINVAL` (§329). Both fixes are inside the core and do not touch the Java surface — no client changes |
| **v1.14.0-lx.17-rc.3** (v2.18.2) | SPEC 039 (rc.2) — rotation of the OOM/crash report archive: 32 directories / 64 MB, deleting by mtime (the device had accumulated 575 directories / 427 MB over 19 days). Plus **240 upstream commits** (URLTest requires history storage in the context). rc.3 — `Endpoint.Close()` returns the tun device's close error again. **The javap diff rc.1 → rc.3: no changes**, and no client changes were needed |
| **v1.14.0-lx.17-rc.1** | SPEC 038 — the fix for the fatal throw in `GetRunningConfig` (returning `RunningConfig` instead of a bare string; see the pin block above). **An API break:** the method's signature changed and the client must call `.content()` |
