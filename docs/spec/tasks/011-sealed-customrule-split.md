# 011 — Sealed CustomRule split + preset SRS cache

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-04-21 |
| Связанные spec | [`030 custom routing rules`](../features/030%20custom%20routing%20rules/spec.md) (обновляется), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`011 local ruleset cache`](../features/011%20local%20ruleset%20cache/spec.md) |
| Лэндинг | v1.4.1 |

## Контекст

В v1.4 landed unified `CustomRule` — один класс с enum-дискриминатором `kind: inline | srs | preset`. В v1.4.0 (spec 033) к нему добавился третий kind `preset` для bundle-пресетов с тонкой ссылкой. Результат — класс несёт:

- Match-поля (domain/suffix/kw/cidr/port/package) — только для `inline`.
- `srsUrl` — только для `srs`.
- `presetId` + `varsValues` — только для `preset`.
- Общие: `id`, `name`, `enabled`, `outbound`.

**Проблема:** игнорируемые поля per kind + runtime checks вместо compile-time exhaustive dispatch. Ошибки типа «для preset `outbound` не используется, а `target` где-то читается» — катят в code review, не в компилятор.

**Вторая проблема:** в spec 033 bundle-пресеты с `type: "remote"` rule_set'ом (Block Ads, Russia-only services) теперь попадают напрямую в config — sing-box качает сам. Это нарушает инвариант spec 011 «sing-box ничего не качает сам, всё через ☁».

## Решение

Разбить `CustomRule` в **sealed-иерархию** и внедрить SRS cache для `CustomRulePreset`:

```
sealed class CustomRule {
  String id;
  String name;
  bool enabled;
  Map<String, dynamic> toJson();
  factory CustomRule.fromJson(Map<String, dynamic>);
}

class CustomRuleInline extends CustomRule {
  List<String> domains, domainSuffixes, domainKeywords, ipCidrs;
  List<String> ports, portRanges, packages, protocols;
  bool ipIsPrivate;
  String outbound;
}

class CustomRuleSrs extends CustomRule {
  String srsUrl;
  List<String> ports, portRanges, packages, protocols;
  bool ipIsPrivate;
  String outbound;
}

class CustomRulePreset extends CustomRule {
  String presetId;
  Map<String, String> varsValues;
  // name read-only в UI; snapshot label из шаблона, обновляется при build'е.
  // outbound не хранится — берётся из varsValues['outbound'] через @outbound subst.
}
```

### Inference-по-дискриминатору

`CustomRule.fromJson(j)` смотрит на `j['kind']` и делегирует в соответствующий `fromJson` подкласса. Backward-compat:
- Отсутствует `kind` или значение `inline` → `CustomRuleInline.fromJson`.
- `srs` → `CustomRuleSrs.fromJson`.
- `preset` → `CustomRulePreset.fromJson`.
- Старое поле `target` (до rename в 1.4.1) читается как fallback для `outbound`.

### `CustomRulePreset` и SRS cache

Восстанавливаем spec 011 инвариант для bundle-пресетов:

- `RuleSetDownloader` получает новый namespace ключей: `preset:<presetId>:<rule_set_tag>`. Физический путь: `$docs/rule_sets/preset_<presetId>_<tag>.srs`.
- `CustomRulePreset.cachedSrsPaths(SelectableRule preset): Map<String, String?>` — для каждого `preset.ruleSets[i]` с `type: "remote"` → cached path или null.
- `expandPreset` при обработке remote-rule_set: если есть path → заменяет на `{type: "local", tag: ..., format: "binary", path: "<cache>"}`. Нет → rule_set skip + warning, правило может не работать но не валится sing-box.
- UI: ☁-иконка у preset-правила если в шаблоне хоть один remote rule_set. Tap/long-press — как у `CustomRuleSrs`. Switch enabled блокируется пока не скачан **хотя бы один** (или все? — TBD).

### Invariants

- `CustomRulePreset.name` — **read-only в UI**. Snapshot `preset.label` при добавлении; при каждом `buildConfig` или открытии редактора проверяем и обновляем если `preset.label` поменялся в шаблоне.
- `outbound` отсутствует как поле у `CustomRulePreset`. Эффективный outbound = `varsValues['outbound']` (после `@outbound` substitution).
- Backward-compat: `CustomRule.fromJson` принимает и старые `target`-JSON, и новые `outbound`-JSON.

## План

### Модель
- [x] `sealed class CustomRule` с 3 наследниками.
- [x] `fromJson` дискриминация по `kind` + fallback на `target` для legacy.
- [x] `toJson` — полиморфный, `if` только для не-обязательных полей в конкретном подклассе.
- [x] `copyWith` — per-subclass (возвращает свой же тип).
- [x] `summary` — @override per-subclass.
- [x] **Convenience getters на base-class** (domains/srsUrl/presetId/outbound/…) для read-only доступа без pattern-match. Упрощает UI/builder без потери type-safety.
- [x] **`withEnabled` / `withName` / `withOutbound` type-preserving mutators** — UI пишет `rule.withEnabled(v)` вместо `switch(cr) { case Inline() => cr.copyWith(enabled: v), ... }`.

### Builder
- [x] `applyCustomRules` → pattern-match `switch(cr) { case CustomRuleInline(): ..., case CustomRuleSrs(): ..., case CustomRulePreset(): continue; }`.
- [x] `applyPresetBundles` фильтрует `cr is CustomRulePreset`, принимает `presetSrsPaths: Map<String, String>` (ключ `<presetId>|<tag>`).
- [x] `buildConfig.customRules` — pre-resolve `presetSrsPaths` через `RuleSetDownloader.cachedPathForPreset`.

### SRS cache (preset)
- [x] `RuleSetDownloader.{presetCacheId, cachedPathForPreset, downloadForPreset, deleteForPreset}` — namespace `preset__<presetId>__<tag>`.
- [x] `expandPreset`: `type: "remote"` + есть cache → `{type: "local", path: ...}`; нет cache → skip + warning.
- [x] **Dangling-rule_set guard** — если `preset.rule.rule_set` ссылается на tag, который был дропнут (remote без кэша), `routing_rule` тоже дропается целиком. Без этого sing-box падал: `initialize rule[N]: rule-set not found: <tag>`.
- [x] **UI ☁-кнопка** в `routing_screen._buildCustomRuleTile` для preset'ов с remote rule_set(ами): Tap → скачивает все remote rule_set пресета (`RuleSetDownloader.downloadForPreset`). Long-press → меню Refresh (повторный download) / Clear (удалить все cached файлы + disable switch). Switch toggle-on при uncached → auto-download + enable.

### UI
- [x] `CustomRuleEditScreen` — `_snapshot()` строит конкретный subclass по `_kind`.
- [x] `CustomRulePreset` редактор: name `readOnly: true` + 🔒 (см. `_buildPresetParams`).
- [x] `routing_screen._buildCustomRuleTile` — subtitle учитывает preset, existing-check по `presetId`.
- [x] Switch auto-download для preset — toggle-on при uncached rule_set'ах скачивает через `_enableAfterDownload` и включает правило на успехе (как у `CustomRuleSrs`).
- [x] Delete preset-rule очищает и preset-cache файлы (`RuleSetDownloader.deleteForPreset` для каждого remote rule_set пресета).
- [x] **Preset с remote rule_set'ами через «Add to Rules» добавляется disabled** — по аналогии с `CustomRuleSrs`. Пока не скачан хоть один `.srs` — правило не может матчить, switch OFF намекает юзеру нажать ☁.
- [x] **Auto-disable на load** — `_refreshSrsCache` проходит по `_customRules` и для каждого правила с недостающим кэшем выставляет `enabled: false` + persist. Важный фикс: `_template` устанавливается **до** `_refreshSrsCache` (раньше был после → `_presetFor` возвращал null и auto-disable для preset'ов не срабатывал).
- [x] **☁-кнопка через `InkWell`, не `GestureDetector`** — `HitTestBehavior.opaque` у GestureDetector перехватывал tap ДО вложенного IconButton. Перешли на InkWell с `onTap` + `onLongPress` — один нод для обоих жестов.

### Тесты
- [x] `custom_rule_test.dart` — sealed dispatch round-trip, legacy `target`-JSON read.
- [x] `preset_expand_test.dart` — SRS-replacement с cache, skip без cache.
- [x] `apply_preset_bundles_test.dart` — sealed sig, inline/preset/srs dispatch.
- [x] `custom_rules_test.dart` — switched to `CustomRuleInline` / `CustomRuleSrs`.
- [x] `selectable_to_custom_test.dart` — возвращает `CustomRulePreset`.

### Docs
- [x] Spec 030 — раздел «v1.4.1: sealed-split» (см. §Sealed split ниже в этом файле).
- [ ] Spec 033 — обновить с замечанием о SRS cache.
- [ ] ARCHITECTURE.md — pipeline учитывает presetSrsPaths.
- [x] CHANGELOG.md — `[1.4.1]` раздел с описанием sealed + SRS cache.
- [ ] RELEASE_NOTES.md — подготовить body для GH Release.
- [ ] docs/releases/v1.4.1.md — детальный файл.

### Релиз
- [x] `flutter analyze` без ошибок (19 info/annotate_overrides, не блокирует).
- [x] `flutter test` — 262 passed.
- [ ] `./scripts/build-local-apk.sh` — собрать.
- [ ] `adb install -r` на CE8XX48PCI79U4XG.
- [ ] Smoke: Russian domains direct работает (bundle, vars), Block Ads — rule_set пустой до implementation UI-☁.

## Риски

- **Миграция storage.** Старые `CustomRule` (1.4.0) с `target` полем — `fromJson` должен их проглотить без потерь. Пишу тест.
- **name у preset.** Snapshot в storage может устареть если юзер не открывал правило после update шаблона. Декомпозиция: в `buildConfig` вторично обновлять `name = preset.label` и сохранять. Тест.
- **SRS ключ-конфликт.** `RuleSetDownloader` использует `id` как ключ. Для preset используем префикс `preset:` — гарантирует отсутствие коллизий с UUID-id от `CustomRuleSrs`.
- **UI edge case.** Preset c remote rule_set'ом и кэшем → switch auto-enable после download. Без remote rule_set (как ru-direct — только inline rule_set) → ☁ не показывается вообще.
- **Migration flag.** Старый `enabled` у preset-правила с uncached remote rule_set → при первом билде правило skip + warning. Юзер увидит через debug API. Документировать.
