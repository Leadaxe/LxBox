# §397 — OOM report bodies in the diagnostic dump

## Why

A field dump (`lxbox-dump-2026-08-12`, app 2.20.7, core 1.14.0-lx.25-rc.3)
carried five OOM entries, each a seven-field summary — `name`, `mtime`,
`size`, `core_version`, `memory_usage`, `heap_inuse`, `num_goroutine` — and
nothing else. That is by design (§318: pprof profiles are binary, "who needs
them uses per-snapshot share"), but the design failed in practice:

- The dump showed 514–552 MB RSS against a 136–178 MB Go heap — three
  quarters of the memory lived outside the heap, and the dump had no data to
  say where. The full `metadata.json` sitting on the device (with `sys`,
  `heapSys`, `stackInuse`, `gcSys`…) would have answered that; the heap
  profiles would have named the allocators.
- Getting those files requires the user to open Debug → OOM → tap a
  snapshot → tap its own share button — per snapshot. One extra round-trip
  per snapshot with a non-technical reporter does not happen.

Acceptance criterion: from a single user upload one can run
`go tool pprof` on the heap profile of at least the latest OOM without
asking the user for anything else.

## What changes

`DumpBuilder._oomReports()` keeps the summary for every snapshot and adds
the snapshot **bodies** for at most `kOomKeep` (5) freshest ones. Older
entries (possible when OOMs piled up since the last app start — prune runs
at startup only) stay summary-only.

Per body-carrying entry, on top of the existing summary fields:

| Field | Source file | Encoding |
|---|---|---|
| `metadata` | `metadata.json` | full JSON object, verbatim |
| `go_log` | `go.log` | text, **tail** capped at 64 KB (`go_log_truncated: true` when cut) |
| `connections` | `connections.json` | full JSON object |
| `configuration` | `configuration.json` | full JSON object |
| `cmdline` | `cmdline` | text, NUL separators shown as spaces |
| `files` | `*.pb` + anything unrecognized | map `name → {encoding: "gzip+base64", raw_size, data}` |

Notes:

- `go.log` keeps the **tail**, not the head: the OOM moment is at the end.
  (Crash reports keep the head — the panicking goroutine comes first; the
  two limits share the 64 KB constant but not the direction.)
- The `.pb` profiles are **uncompressed** protobuf (`oomprofile.WriteFile`
  writes raw proto, unlike stdlib `pprof.WriteTo`), so gzip shrinks them
  severalfold before the +33% of base64. Expected cost: ~1–1.3 MB of
  base64 for five full snapshots on top of a ~2 MB dump.
- Unrecognized future files fall into `files` (binary-safe default) rather
  than being dropped — a core bump must not silently lose evidence.
- A file that vanished or failed to read is skipped; the entry itself
  survives (same stance as the summary and `crash_archive`).
- No `files_included` marker — a reader distinguishes versions by the
  presence of the body fields themselves (decided in review, 17.08.2026).

To read a profile back:

```bash
jq -r '.oom_reports[0].files["heap.pb"].data' dump.json | base64 -d | gunzip > heap.pb
go tool pprof heap.pb
```

## Files

- `app/lib/services/dump_builder.dart` — `_oomReports()` grows the body
  branch; the section builder becomes `oomReportsSection()` (public static)
  so tests can drive it without mocking the whole `build()`.
- `app/test/services/dump_builder_oom_test.dart` — new; fake path provider
  + on-disk snapshot fixtures, same pattern as `oom_reports_test.dart`.

## Out of scope

- Compressing the dump file itself, or switching it to a zip container.
- Changing `kOomKeep`, prune timing, or the per-snapshot share flow.
- `crash_archive` stays as is.
