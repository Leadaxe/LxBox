# 107 — Lazy-persist: rebuild на возврате к home читает несфлашенный storage

**Дата:** 2026-06-10 · **Статус:** DONE (released v2.0.2; проверено на устройстве)
**Симптом (field report, 4PDA, v2.0.x):** после изменения routing-правил
трафик не идёт; рестарт туннеля НЕ лечит. Лечится «танцем»: Routing →
Tunnel Applications → выключить всё → выйти на home → зайти снова →
включить как было → выйти → Start. Регрессия введена §076 (v1.9.0),
до пользователей доехала в v2.0.0/v2.0.1.

## Root cause (подтверждён построчным чтением)

§076 рассматривал эту гонку и счёл её безопасной (spec 076, секция «Lazy
pattern: реализация в State», bullet «Race window»: «`SettingsStorage._cache`
обновлён в microtask раньше чем handler дойдёт до `generateConfig`»).
Предпосылка неверна — flush привязан не к pop'у, а к dispose:

1. `NavigatorObserver.didPop` стреляет **синхронно в момент `Navigator.pop`**
   (`home_return_observer.dart:35`) → `home_screen._onReturnToHome` →
   `_rebuildAndClearDirty` → `generateConfig` читает
   `getCustomRules`/`getTunApps`/`getAllVars` и пр.
   (`subscription_controller.dart:438-445`) через единицы мс — это
   микротаски по in-memory `SettingsStorage._cache`.
2. `State.dispose()` popped-роута вызывается **после exit-анимации**
   (~300 мс). Только тогда `LazyPersistMixin._flush()` → `persistChanges()`
   переносит локальный буфер экрана в `SettingsStorage._cache` + диск
   (`lazy_persist_mixin.dart:56-62`).
3. Итог: rebuild детерминированно (анимация всегда длиннее микротасок)
   собирает конфиг из состояния «до последней правки» и сбрасывает
   `configDirty` (`subscription_controller.dart:421` + безусловно
   `home_screen.dart:540`). **Конфиг хронически отстаёт на один визит
   editing-экрана.**
4. Start не пересобирает — `_startInternal` это голый native start
   (`home_controller.dart:280`) → рестарт туннеля не лечит.

Почему «танец» помогает: каждый визит на lazy-экран + возврат на home —
ещё один rebuild, подхватывающий flush **предыдущего** визита. Два визита
в Tunnel Applications протаскивают в конфиг изменение правил; финальное
состояние per-app при этом само отстаёт («всё выключено» с визита №1 →
TUN без `include_package` → туннелится всё → «работает»).

Затронуты все lazy-экраны: `routing_screen`, `tun_apps_tab`,
`dns_settings_screen`, `settings_screen` (Core template vars,
собственная копия скелета — `_pendingVars`).

Смежные подтверждённые баги (фиксим заодно):

- **R2.** `_rebuildAndClearDirty` сбрасывает `configDirty` **безусловно**
  (`home_screen.dart:540`) — даже когда `generateConfig` вернул null
  (ошибка сборки / lock §037): синий banner гаснет, конфиг старый, юзер
  не узнаёт.
- **R3.** `_onReturnToHome` при `_subController.busy` молча скипает
  rebuild без перепроверки (`home_screen.dart:553`) — например, во время
  фонового fetch'а подписки.
- **R4.** Окно «rebuild в полёте, юзер жмёт Start»: native стартует со
  старым `singbox_config.json`, юзер получает плашку «restart to apply»
  постфактум вместо старта со свежим конфигом.

## Fix

Принцип: **staging** — мутация сразу обновляет in-memory
`SettingsStorage._cache` (это и есть то, что читают все читатели);
лениво-отложенной остаётся только дисковая запись. После этого rebuild на
возврате к home — чистая оптимизация задержки; корректность держат
мгновенный `_cache` + мгновенный `configDirty` + гейт на Start.

| # | Файл | Изменение |
|---|---|---|
| F1 | `services/settings_storage/*` | Параметр `{bool flush = true}` у методов, используемых lazy-экранами: `saveCustomRules`, `saveEnabledGroups`, `saveRouteFinal`, `setTunApps`, `saveDnsServers`, `saveDnsRulesList`, `setVar`. `flush: false` → обновить `_cache`, пропустить `_save()`. Новый `static Future<void> flushToDisk()` → `_save()` (no-op при `_cache == null`). Default `true` — все eager-пути не меняются |
| F2 | `screens/lazy_persist_mixin.dart` | Контракт: `persistChanges()` → **`stageChanges()`** (тела экранов те же, но с `flush: false`). `markDirty()` дополнительно `unawaited(stageChanges())` — буфер уезжает в `_cache` в момент мутации. `_flush()` (dispose/paused) → `await stageChanges(); await SettingsStorage.flushToDisk();` (stage перед flush — safety-net, идемпотентно) |
| F2 | `routing_screen/routing_srs_cache.dart`, `tun_apps_tab.dart`, `dns_settings_screen.dart` | Механическая миграция `persistChanges` → `stageChanges` + `flush: false` |
| F2b | `settings_screen.dart` (Core vars, не на mixin'е) | `_onVarChanged` дополнительно `unawaited(SettingsStorage.setVar(name, value, flush: false))`; `_persist` → `SettingsStorage.flushToDisk()` (цикл по снапшоту `_pendingVars` с N×`_save()` умирает; map остаётся как pending-маркер) |
| F3 | `home_screen.dart` | Single-flight + гейт на Start: поле `Future<void>? _rebuildInFlight`; `_rebuildAndClearDirty` оборачивается (повторный вызов await'ит существующий Future). `_startWithAutoRefresh` перед `_controller.start()`: `if (_rebuildInFlight != null) await _rebuildInFlight;` затем `if (_subController.configDirty) await _rebuildAndClearDirty();`. Сбой сборки / lock §037 (null) → стартуем со старым конфигом, флаг остаётся, синий banner горит |
| F4 | `home_screen.dart` | `_onReturnToHome` при `busy` чужой операцией (fetch): вместо молчаливого скипа — one-shot listener на `subController`; на `!busy && configDirty && mounted` → `_rebuildAndClearDirty()` |
| F5 | см. ниже | Удаление `auto_rebuild` (вся связанная логика) |
| F6 | `home_screen.dart` | `_rebuildAndClearDirty`: убрать безусловный `configDirty = false` (`:540`) — на success его уже сбросил `generateConfig` (`subscription_controller.dart:421`); при `saveParsedConfig` → `ok == false` re-set'ить `configDirty = true` (banner остаётся) |

### F5 — удаление `auto_rebuild`

Флаг потерял смысл: после F1-F3 авто-rebuild на возврате — безопасная
оптимизация, а корректность гарантирует гейт на Start. Поведение «OFF»
(только banner, ручной tap) удаляется.

| Файл | Что убрать |
|---|---|
| `app_settings_screen/widgets/general_tab.dart` | `SwitchListTile` «Auto-rebuild config» (`:91-97`) + props `autoRebuild`/`onAutoRebuildChanged` (`:17,35`) |
| `app_settings_screen.dart` | Поле `_autoRebuild` (`:42`), load (`:120,138`), проброс (`:421`), handler (`:432-433`) |
| `home_screen.dart` | Поле `_autoRebuild` (`:52`), чтения var (`:320-321`, `:555-556`); `_onReturnToHome` упрощается до прямого `_rebuildAndClearDirty()` |
| `settings_storage/io.dart` `_save()` | Cleanup stale-ключа по образцу `node_overrides`: `(_cache?['vars'] as Map?)?.remove('auto_rebuild')` |
| `test/services/debug/serializers_test.dart` | Sample-ключ `auto_rebuild` (`:38,45`) → живой var (например `auto_update_subs`) |
| `docs/spec/features/022 app settings/spec.md` | Описание тумблера + строка в таблице ключей — пометить удалённым (§107) |
| `docs/spec/features/076 .../spec.md` | Пометки [§107]: неверный race-анализ, листинг `_onReturnToHome`, bullet про `auto_rebuild`, acceptance-пункт; addendum-секция |

## Почему staging закрывает гонку

- `markDirty()` ставит `configDirty` синхронно (как было) и **сразу**
  стартует `stageChanges()` — обновление `_cache` завершается в ближайших
  микротасках, до обработки следующего pointer-события. Pop (отдельный
  жест юзера) приходит заведомо позже.
- Любой читатель — rebuild на pop'е, гейт на Start, bootstrap, background
  updater — видит свежие данные автоматически, без знания о flush'ах.
- Гарантии при kill процесса не меняются: несфлашенное на диск теряется
  (как сейчас), §072-атомарность внутри `_save()` не трогается,
  mtime-self-heal (§076) работает как раньше.
- Если eager-путь (например AutoUpdater) вызовет любой `setX(flush: true)`
  посреди editing-сессии — staged-правки уедут на диск раньше dispose.
  Безвредно: данные корректны, просто лишняя запись.

## Поведенческие изменения

- Rebuild на возврате к home теперь всегда автоматический. У юзеров с
  `auto_rebuild=false` поведение меняется (banner-only режим удалён) —
  пункт в release notes.
- Start при `configDirty` достраивает конфиг перед запуском — старт
  дольше на время сборки (доли секунды на фоне establish ~1-2 с), зато
  всегда со свежими правилами. Плашка «restart to apply» остаётся только
  для сбоя сборки / lock §037.
- Ошибка сборки больше не гасит синий banner (R2/F6).
- Disk writes: `settings_screen` exit — было N×`_save()` (по числу
  изменённых vars), станет 1×`flushToDisk()`. Остальные lazy-экраны: 1
  write на exit, как было.

## Tests (фактические)

```
test/services/settings_storage_staging_test.dart (NEW, 7 тестов)
  - setVar(flush:false): _cache обновлён, файла нет
  - staged-серия (setVar+saveRouteFinal+saveEnabledGroups) + flushToDisk →
    файл содержит всё
  - default (flush:true) пишет сразу — поведение не изменилось
  - flushToDisk без загруженного кэша — no-op
  - регрессия §107: staged custom rules видны читателю ДО дисковой записи
  - staged tun_apps + flushToDisk → round-trip с диска
  - cleanup: vars.auto_rebuild выбрасывается на первом save

test/screens/lazy_persist_mixin_test.dart (UPDATE → staging-контракт)
  - markDirty: configDirty/pending sync + stage стартует сразу
  - каждый markDirty re-stage'ит буфер
  - dispose-flush: stage safety-net вызван повторно
  - clean exit без pending — без записи; paused-flush идемпотентен

test/services/debug/serializers_test.dart (UPDATE)
  - sample-ключ auto_rebuild → auto_update_subs
```

**Отступление от плана**: `home_start_gate_test.dart` не написан —
widget-тест HomeScreen требует полного native-channel harness'а
(BoxVpnClient, path_provider, Clash API), которого в suite нет
(home_screen не пампится ни в одном существующем тесте). Гейт и
single-flight покрыты построчным ревью + local smoke release-сборки.
Follow-up: вынести гейт-логику в тестируемый helper, если harness
появится.

## Не в скопе

- Native side (`ConfigManager.cachedConfig` и пр.) — проверено: сервис в
  том же процессе, `save()` обновляет кэш+файл когерентно, не участвует.
- Изменение семантики `configChangedNeedRestart` / розового banner'а.
- Eager-экраны (subscriptions, custom_rule_edit, node_filter,
  app_settings кроме auto_rebuild) — поведение не меняется.
- Schema `lxbox_settings.json` — не меняется (только cleanup мёртвого
  ключа `vars.auto_rebuild`).
