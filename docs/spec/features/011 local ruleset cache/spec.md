# 011 — Local Rule Set Cache

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Problem

Selectable rules reference remote `.srs` binary rule sets (e.g. `ads-all`, `ru-inside`).
Currently these are passed as `"type": "remote"` in the generated sing-box config — sing-box
downloads them on first start. This causes:

- Slow first launch (multiple HTTP fetches before VPN is ready).
- Offline failure (if cache is cold and no internet without VPN).
- No visibility or control from the app.

## Solution

Pre-download all remote `.srs` files used by enabled selectable rules into the app's
local storage during config generation. Replace `"type": "remote"` with `"type": "local"`
+ `"path": "<absolute_path>"` in the generated config so sing-box reads files instantly.

## Flow

```
Config generation (ConfigBuilder.generateConfig)
  ├─ Collect all remote rule_set entries from enabled selectable rules
  ├─ RuleSetDownloader.ensureCached(url) for each
  │   ├─ If file exists and age < reload interval → skip
  │   └─ Else → HTTP GET → save to <app_dir>/rule_sets/<tag>.srs
  ├─ Rewrite rule_set entries: type=remote → type=local, path=<local>
  └─ Continue with normal config assembly
```

Refresh happens together with subscription updates (same trigger: `updateAllAndGenerate`
or auto-refresh on Start).

## Files

| File | Change |
|------|--------|
| `lib/services/rule_set_downloader.dart` | Download + cache logic |
| `lib/services/config_builder.dart` | Call downloader, rewrite entries |

## Acceptance

- [x] Enabled remote rule_sets are downloaded to local storage before config is saved.
- [x] Generated config has `"type": "local"` for all previously-remote rule_sets.
- [x] Re-download happens when cache is older than `parser.reload` interval.
- [x] Download errors are non-fatal — falls back to remote in generated config.
