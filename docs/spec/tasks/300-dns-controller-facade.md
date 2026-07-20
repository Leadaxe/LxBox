# §300 — DnsController: фасад DNS под probe-эталон (load/snapshot + чистые статики)

**Тип:** structural refactor (Шаг 2a фичи [§291](../features/291%20layered-architecture-facades/spec.md); эталон — ProbeController §296) · **Статус:** D1+D3 РЕАЛИЗОВАНЫ; D2 остаётся · **Размер:** S–M · **Зависит от:** [§294](294-dns-typed-model.md) (done) · **Разблокирует:** [§295](295-dns-dual-write-fix.md)

> **Реализовано (D1+D3, коммит ниже):** `lib/services/dns/dns_controller.dart` —
> `DnsController.load()` → `DnsSettingsSnapshot` (тело `_load` ~175 строк verbatim,
> типизация краёв §294); `stage()` trio (byte-identical, без custom_rules).
> `dns_settings_screen._load` → присвоение snapshot, `stageChanges` → `stage()`;
> экран сдулся 985→811. 2 теста на `stage()` (пишет ключи; custom_rules не тронут).
> Поведение identical по построению. **D2** (чистые статики `ruleDisplayRows/
> reorderRules/ruleRefsByTag`) — остаётся, отдельным шагом. §295 (custom_rules
> в staged-путь) разблокирован, но device-required.
> **Известный долг:** `DnsController` импортит resolver из `screens/` (§294 VIEW);
> перенос resolver в `services/` — отдельный шаг, scope D1 не расширяли.

Приводит `dns_settings_screen` (985 строк, screen==controller) к **probe-эталону**:
контроллер владеет storage + чистой логикой, экран тонкий. Выделено из §295,
чтобы отделить **code-provable** часть (вынос load/статик — identical) от
**device-required** dual-write (§295, custom_rules staging).

## Probe-эталон → DNS (маппинг)

| Probe (§296) | DNS (§300) |
|---|---|
| `probeNodesOf` — ОДИН domain-shape адаптер | `DnsController.load()` — единственное место, где сырой `List<Map>` → §294 `DnsServerRef/DnsRuleRef.fromJson` |
| `loadThresholds/saveThresholds` (storage trio) | `load()`/`stage()` над `dns_servers`/`dns_rules`/dns-vars |
| чистые статики `unreachableIndexes/slowerThan/…` | `ruleDisplayRows/reorderRules/ruleRefsByTag/resetOrphanedResolvers` |
| экран держит `_probe`, зовёт статики, применяет к мутатору | экран держит `_servers/_rules`, зовёт статики, применяет к себе |
| `ProbeGateMixin` | **нет аналога** — DNS не нужен VPN-гейт, не выдумывать |

## Что входит (code-provable)

1. **`DnsController.load()` → `DnsSettingsSnapshot`** — тело `_load()` экрана
   (~200 строк, `:134-333`) verbatim в контроллер; типизация краёв через §294
   `fromJson`. Экран: `final s = await DnsController.load(); setState(from s)`.
   Golden-тест: вывод идентичен текущему setState-блоку.
2. **Чистые статики** — `_ruleDisplayRows`(:490)→`ruleDisplayRows`,
   `_onReorderRules` math(:616)→`reorderRules`, `_ruleRefsByTag`(:359)→
   `ruleRefsByTag`, §121 resolver-reset(:300-307)→`resetOrphanedResolvers`.
   Referentially transparent, покрываются фикстурами.
3. **`stage()`** — `stageChanges()` trio (`saveDnsServers`/`saveDnsRulesList`/
   dns-vars + `cleanDnsRulesForPersist`) в контроллер. Пока БЕЗ custom_rules
   (это §295). Byte-identical (§221 round-trip).

## Что НЕ делать (scope-cuts из ресёрча)

- **НЕ создавать `DnsDraft`-класс** — экран уже владеет `_servers/_rules/
  _customRules`; отдельный draft-carrier дублирует их (слабейший new type, как
  folder_detail держит `_probe` локально). Один snapshot-DTO (возврат `load()`),
  не два.
- **НЕ поглощать** `resolveDisplayedServers`/`ResolvedServer`/
  `dns_server_resolver.dart` — §294 оставил их downstream-VIEW; кормить
  типизированными refs, не сворачивать внутрь.
- **НЕ переписывать** `renameDnsServerTagRefs`/`renameRuleDnsServerTag`/
  `cleanDnsRulesForPersist` — фасад ОБОРАЧИВАЕТ существующие pure-функции.
- **НЕ трогать** форму хранилища (§221); custom_rules остаётся routing-owned
  (это §295).
- `edit_controller.dart` (dns_server_edit presenter) — оставить, не overlap.
- Strategy/dnsFinal/defaultResolver — тривиальные var'ы, несём полями snapshot,
  не оборачиваем в отдельные getter/setter.

## Что остаётся в экране (presentation)

setState/rebuild, виджеты (MergedServerTile/DnsRuleTile/DnsMirrorGroupCard/
ResolverPicker/…), навигация в редакторы, `LazyPersistMixin` +
`stageChanges()=>_controller.stage(...)` (тонкая glue), `_confirmClearDnsCache`
(device-action).

## План (strangler, каждый шаг shippable)

- **D1 (S, code-provable):** `DnsSettingsSnapshot` + `load()` verbatim +
  типизация краёв. Golden output-identical.
- **D2 (S, code-provable):** чистые статики в контроллер; экран зовёт.
- **D3 (S, code-provable):** `stage()`; `stageChanges()` → `_controller.stage`.
  Пока trio без custom_rules. Byte-identical.
- **D4 → это §295 (DEVICE-REQUIRED):** custom_rules в staged-путь; 4 dual-write
  → чистые статики. Отдельная таска, device.

## Приёмка

- `load()` возвращает типизированный snapshot; golden-тест = текущий вывод.
- Статики referentially transparent, покрыты фикстурами.
- `stage()` trio byte-identical (§221 round-trip).
- Экран сдут; probe-storage-логика вынесена; поведение неизменно (D1-D3).
- Разблокирует §295 (custom_rules теперь адресуем через контроллер).

## Docs to update

- `docs/ARCHITECTURE.md` — `DnsController` в карте, под `services/dns`.
