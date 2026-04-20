# 011 — Local Rule Set Cache (manual download)

| Поле | Значение |
|------|----------|
| Статус | Реализовано (v1.4.0) |
| Связано | [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md) |

## Problem

Remote `.srs` rule sets из community-репозиториев нужны для пресетов типа Block Ads, Russia-only, etc. Три проблемы с auto-download:

- **Slow first launch** — VPN не стартует, пока все файлы не скачались.
- **Offline failure** — нет интернета до поднятия VPN → cold cache → fail.
- **Rate-limits / bans** — GitHub и зеркала блокируют клиенты которые дёргают `.srs` без контроля.
- **Невидимые автообновления** — sing-box `update_interval: 24h` качает в фоне, юзер не контролирует когда и что.

## Solution (v1.4.0)

**Local-only, manual download.** Никаких `type:remote` в sing-box-конфиге, никаких `update_interval`. Юзер явно жмёт ☁ → файл качается в `$documents/rule_sets/<rule.id>.srs` → в конфиг эмитим `type:local, path:<abs>`.

### Ключевые инварианты

- **sing-box ничего не качает сам** — все rule_set'ы либо `inline`, либо `local`.
- **Нет auto-update** (см. memory `feedback_no_unplanned_autoupdates`). Refresh — только по тапу юзера.
- **Rule enable gate** — правило нельзя включить (switch disabled) если cached файла нет.
- **Identity = `CustomRule.id` (UUID)** — файл на диске привязан к id, не к URL. Rename/URL-change не ломает кэш; URL-change явно стирает кэш.

## API — `RuleSetDownloader`

`lib/services/rule_set_downloader.dart`:

```dart
class RuleSetDownloader {
  static Future<bool> isCached(String id);
  static Future<String?> cachedPath(String id);
  static Future<DateTime?> lastUpdated(String id);
  static Future<String?> download(String id, String url);  // atomic (tmp-rename)
  static Future<void> delete(String id);                   // no-op if absent
}
```

Файлы: `$documents/rule_sets/<id>.srs`. Атомарная запись (tmp file + rename) — сетевой обрыв не оставляет частично записанный кэш.

## Flow

```
User taps ☁ on rule tile (или long-press → Refresh):
  └─ RuleSetDownloader.download(rule.id, rule.srsUrl)
      ├─ HTTP GET with 30s timeout
      ├─ On 200 + non-empty body → write <tmp> → rename to <final>
      └─ On fail → null; tile shows red ☁ (cloud_off)

Build config (lib/services/builder/build_config.dart):
  ├─ For each CustomRule of kind=srs:
  │   └─ srsPaths[rule.id] = RuleSetDownloader.cachedPath(rule.id) or skip
  └─ applyCustomRules(registry, rules, srsPaths: srsPaths)
      └─ Rules with path emit {type:"local", path:...}
      └─ Rules without path → skip + warning ("no cached file")

Rule delete (routing_screen.dart):
  └─ RuleSetDownloader.delete(rule.id)   // cleanup orphan file

URL change in editor (custom_rule_edit_screen._openCustomRuleEditor):
  └─ if srsUrl changed: RuleSetDownloader.delete(old.id) + reset enabled=false
```

## UI

**Routing tab → Rules list:**
- srs tile показывает ☁ (cloud_download) / ✅ (cloud_done) / ❌ (cloud_off) / progress
- tap ☁ = download/retry
- switch disabled пока `!isCached`
- long-press row → Delete (cached file удаляется вместе)

**Edit screen (URL field):**
- prefix-icon 🔗 tap = copy URL
- suffix-icon ☁ tap = download, long-press = menu (Refresh / Clear cached file)
- Clear cached file удаляет только файл (не правило), сбрасывает switch

## Файлы

| Файл | Что |
|------|-----|
| `lib/services/rule_set_downloader.dart` | `download` / `isCached` / `cachedPath` / `delete` / `lastUpdated` |
| `lib/services/builder/post_steps.dart` | `applyCustomRules(..., srsPaths: Map<id, path>)` → эмит `type:local` |
| `lib/services/builder/build_config.dart` | Pre-resolve srsPaths (Future.wait) → вызов applyCustomRules |
| `lib/screens/routing_screen.dart` | UI состояний ☁ + `_downloadSrs` + delete cleanup |
| `lib/screens/custom_rule_edit_screen.dart` | Cloud в URL-поле + long-press menu |

## Acceptance

- [x] Sing-box-конфиг не содержит `"type":"remote"` и `"update_interval"` ни для каких CustomRule.
- [x] Rule enable switch disabled пока нет cached файла.
- [x] Tap ☁ триггерит скачивание, статус меняется на ✅/❌.
- [x] Re-tap ✅ = re-download (overwrite).
- [x] Long-press ☁ в editor → меню с Refresh + Clear cached file.
- [x] Delete правила чистит cached файл.
- [x] URL change при save стирает старый кэш + сбрасывает enabled.
- [x] Build warnings: rule с srs без кэша → `warnings += ["SRS rule X skipped..."]`.

## История

**v1.3.x (deprecated).** `applySelectableRules` делал pre-download всех SRS в cache, писал `type:local` в конфиг. Был автофеч через reload-interval. Плюс sing-box-side `update_interval:24h` для enabled selectable rules.

**v1.4.0.** Selectable rules распущены в CustomRule (см. spec 030). Pre-download убран — теперь ручной per-rule. Никаких интервалов/фонового фетча.
