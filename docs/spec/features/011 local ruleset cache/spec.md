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

Refresh happens together with subscription updates (triggered by `AutoUpdater` — see [spec 027](../027%20subscription%20auto%20update/spec.md)) или вручную через `SubscriptionController.generateConfig()`.

## Files

| File | Change |
|------|--------|
| `lib/services/rule_set_downloader.dart` | Download + cache logic (parallel, v1.3.0+) |
| `lib/services/builder/post_steps.dart` (`applySelectableRules`) | Rewrite remote→local entries + trigger downloader (v2; ранее был `config_builder.dart::_applySelectableRules`) |
| `lib/services/builder/build_config.dart` | Оркестратор: после `applySelectableRules` — `_cacheRemoteRuleSets` на `rule_set_downloader` |

## Acceptance

- [x] Enabled remote rule_sets are downloaded to local storage before config is saved.
- [x] Generated config has `"type": "local"` for all previously-remote rule_sets.
- [x] Re-download happens when cache is older than `parser.reload` interval.
- [x] Download errors are non-fatal — falls back to remote in generated config.
