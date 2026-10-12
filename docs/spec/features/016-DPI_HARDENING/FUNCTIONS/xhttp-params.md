[English](xhttp-params.md) · [Русский](xhttp-params.ru.md)

# XHTTP parameters — the full Xray XHTTP transport carried over to sing-box

LxBox reads every XHTTP (SplitHTTP) parameter from links, Xray JSON and sing-box
JSON, including `extra` and `xmux`, and keeps invalid values away from the core.

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P11 P12 P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Carries the XHTTP transport (in Xray — `xhttp`/`splithttp`) from the
subscription into the core's `transport` block completely: not only
path/host/mode, but also session placement, padding obfuscation, uplink
tuning and the `xmux` multiplexer. The Xray server expects exactly what the
link specifies: a lost parameter yields a node that connects but does not
pass data.

## Parameters

All — in `transport` with `type: xhttp`; in the link camelCase (Xray), in
sing-box JSON snake_case; both forms are read, camelCase takes priority.

| Group | Core keys |
|---|---|
| basics | `path`, `host`, `mode` (`auto`·`packet-up`·`stream-up`·`stream-one`), `headers` |
| session/seq | `session_placement` (`path`·`query`·`header`·`cookie`), `session_key`, `seq_placement`, `seq_key` |
| uplink | `uplink_data_placement` (`body`·`auto`·`header`·`cookie`), `uplink_data_key`, `uplink_chunk_size`, `uplink_http_method` |
| padding | `x_padding_bytes`, `x_padding_obfs_mode`, `x_padding_key`, `x_padding_header`, `x_padding_placement` (`cookie`·`header`·`query`·`queryInHeader`), `x_padding_method` (`repeat-x`·`tokenish`) |
| tuning | `sc_max_each_post_bytes`, `sc_min_posts_interval_ms`, `sc_stream_up_server_secs`, `sc_max_buffered_posts`, `no_grpc_header`, `no_sse_header` |
| `xmux{}` | `max_concurrency`, `max_connections`, `c_max_reuse_times`, `h_max_request_times`, `h_max_reusable_secs`, `h_keep_alive_period` |

Xray aliases: `sessionIDPlacement`/`sessionIDKey` → `session_placement`/
`session_key` (the canonical name beats the alias).

## Inputs / Outputs

**Inputs:** a `type=xhttp|splithttp` link with flat parameters and `extra`
(URL-encoded JSON); Xray `xhttpSettings`/`splithttpSettings` (with `extra`);
sing-box `transport`.
**Outputs:** `transport{type: xhttp, …}` only with the set fields (`xmux` —
only when non-empty); codes `xhttp_param_reset`,
`xhttp_mode_forced_packet_up`; into the exported link — flat camelCase fields
that differ from the default, without `extra`.

## Rules and invariants

- The three inputs read one set of keys; a field is added to all at once.
- `extra` is merged over the flat parameters, but: a broken/non-object
  `extra` is ignored, the node lives on the flat ones; an empty value from
  `extra` does not override the flat one; `host`, `path`, `mode` are not read
  from `extra` at all (that is what Xray does). `xmux` as a nested object in
  `extra` or JSON unfolds into the same fields as the flat keys.
- `path` is passed verbatim, including `?…`: per the Xray contract,
  everything after the first `?` is the request query (relays read their
  parameters from it, `/?proxyip=…`); `?ed=N` means no early data for
  xhttp. Without the `path` parameter the key is not emitted; an explicit
  `path=%2F` → `/`. Same for links, Xray JSON and sing-box JSON (contract
  1.1.115, [§620](../../../tasks/620-xhttp-path-query-verbatim.md)). In an exported
  link the path's `?` and `&` are encoded inside `path=`.
- `host` — only from an explicit `host=`, without substituting the SNI.
- Numbers: `30.0` → `"30"`, without exponent; a `"N-N"` range is kept;
  `sc_max_buffered_posts` and `h_keep_alive_period` — integers, `0` is
  significant and emitted, absence — not emitted.
- A value outside the enum (`mode`, `session_placement`, `seq_placement`,
  `uplink_data_placement`, `x_padding_placement` case-sensitively,
  `x_padding_method`) is removed with `xhttp_param_reset`, the node lives.
- `uplink_data_placement` = `header`/`cookie` requires `packet-up`: without
  `mode` → `mode: packet-up` with `xhttp_mode_forced_packet_up`; with an
  explicit other `mode` the placement is removed. `body`/`auto` — with any
  mode.
- `xmux.max_concurrency` and `xmux.max_connections` are mutually exclusive
  (`field_conflict`).
- Emission is deterministic: two runs yield the same body.

## Boundaries

- Parsing the link as a whole —
  [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).
- The transport itself, the modes and `xmux` are executed by the core (core:
  FEATURE 002-XHTTP).
- `downloadSettings` is not read; XHTTP nodes only with `alpn=h3` — a
  transport limitation per §127F (not re-checked in the code); there is no
  XHTTP field editor in the UI (editing — via the node JSON).
- VLESS Vision over XHTTP — [vless-flow-encryption.md](vless-flow-encryption.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [127F](../../../tasks/127F-xhttp-full-url-params/spec.md) | Implementation | 15 extended fields, `extra`, cutting the path's `?` tail |
| 2 | [214](../../../tasks/214-libbox-rc16-xhttp-fields.md) | Implementation | Core with XHTTP SPEC 002 v2 fields |
| 3 | [217](../../../tasks/217-xhttp-normalize-invalid-params.md) | Implementation | Parameters invalid for the core do not bring down the config |
| 4 | [399](../../../tasks/399-xhttp-fields-lost-in-json-branches.md) | Implemented | The JSON branches read the same set of fields |
| 5 | [410](../../../tasks/410-xhttp-extra-empty-not-clobber.md) | Done | An empty value in `extra` does not overwrite; `host`/`path`/`mode` only flat |
| 6 | [416](../../../tasks/416-xhttp-packet-up-guard.md) | Done | header placement without a mode → `packet-up` |
| 7 | [463](../../../tasks/463-contract-w2c-corpus-conformance.md) | Released v2.25.0 | `splithttp` = `xhttp` |
| 8 | [508](../../../tasks/508-xhttp-sessionid-aliases.md) | Released v2.25.1 | Aliases `sessionIDPlacement`/`sessionIDKey` |
| 9 | [522](../../../tasks/522-kernel-lx9-xmux-local-cancel.md) | Released v2.25.3 | Core: the XMUX breaker does not count a local cancel as a failure |
| 10 | [573](../../../tasks/573-xray-finalmask-tcp-fragment.md) | Released v2.25.7 | `extra.mode`/`path`/`host` are read without a code |
| 11 | [620](../../../tasks/620-xhttp-path-query-verbatim.md) | Implemented | `?query` in `path` verbatim (Xray contract, core SPEC 119); the §127F cut is removed |
