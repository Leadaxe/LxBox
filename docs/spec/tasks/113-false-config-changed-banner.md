# 113 — Ложный баннер «config changed» после kill приложения

| Поле | Значение |
|------|----------|
| Статус | In progress — код и тесты готовы, девайс-smoke pending |
| Дата старта | 2026-06-11 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | tasks/107 (staging + автопересборка на возврате), features/076 (settings/config lifecycle, mtime-bootstrap), features/046 (tunnel apps — частый триггер) |

## Проблема

Field report (4PDA): пользователь правит Tunnel apps, смахивает приложение
из recents, запускает снова — вверху красный баннер «config changed,
restart VPN», хотя ничего не менялось. Воспроизводится и без подписок
(значит автообновление подписок ни при чём), и с подписками (другой
триггер того же ложного флага).

## Механика (root cause)

Два дефекта в связке.

**1. Эвристика `isDirty` устарела после §107.** Bootstrap на старте
определяет «конфиг устарел?» сравнением mtime файлов
([config_dirty_check.dart](../../app/lib/services/config_dirty_check.dart)):
`settings.mtime > config.mtime → грязно`. Семантика заложена под старый
порядок записи: «настройки записаны, конфиг ещё не пересобран».

§107 **инвертировал порядок дисковых записей**. Теперь при правке на
lazy-экране:

```
правка        → мутация только в _cache (память), dirty=true. ДИСК НЕ ТРОНУТ.
возврат home  → пересборка из _cache → ЗАПИСЬ конфига             ⏱ T1
уход (dispose)→ ЗАПИСЬ настроек на диск                            ⏱ T2 > T1
```

Конфиг пишется на возврате к home (раньше), настройки — на `dispose`
после анимации (~300 мс позже). Итог: `settings.mtime (T2) > config.mtime
(T1)` после **любой** правки — хотя конфиг уже содержит эти настройки
(пересборка читала их из `_cache`). Эвристика систематически читает это
как «грязно».

**2. Флаг живёт не там, где меняются настройки.** `configDirty` — поле
`SubscriptionController`, а настройки мутируются в `SettingsStorage`. Из-за
разрыва писатель настроек может «поменять, но не пометить»: любой
config-значимый сейвер, не прошедший через `markDirty` экрана, оставляет
конфиг устаревшим без сигнала.

**Почему именно после kill.** Пока процесс жив, `configDirty` в памяти
сброшен успешной пересборкой — баннера нет. Swipe убивает процесс, память
теряется; на старте флаг **передеривается из mtime** — и врёт «грязно».
Туннель пережил swipe (foreground service) → автопересборка + баннер.

## Решение

Без диффа содержимого (сознательно — чтобы аномалии были видны, а не
маскировались). Два изменения.

### A. Touch конфига при записи настроек, если `!configDirty`

В единственном дисковом чокпоинте `SettingsStorage._save()`: после записи
настроек, если флаг **не** поднят — выровнять mtime конфига к **mtime файла
настроек** (`ConfigDirtyCheck.touchConfig()` → `setLastModified(settingsMtime)`,
не `now()`).

Плюс `isDirty` сравнивает mtime с **секундной резолюцией** (флор обоих до
секунды). Причина: `setLastModified` усекает mtime до целой секунды, а
`stat().modified` натуральной записи настроек хранит суб-секунду — прямой
`isAfter` ловил бы эту разницу как ложное «грязно» даже после touch. Флор:
правка в одной секунде с последней чистой записью → equal → чисто; реальное
изменение (≥ следующая секунда) → грязно.

`configDirty` на момент записи — авторитет «в синхроне ли конфиг»:

| Сценарий | dirty при `_save` | Действие | Итог |
|---|---|---|---|
| правка → home → уход | уже снят пересборкой на возврате | touch | чисто |
| фоновый писатель (сортировка/таймстемп обновления) | не ставился | touch | чисто |
| свернул посреди правки (paused-flush без возврата) | стоит | не трогаем | честно грязно → следующий старт пересоберёт |

Дифф не нужен: к моменту `dispose`-flush в обычном потоке пересборка на
возврате уже сняла флаг, поэтому `!dirty → touch` срабатывает корректно.

### B. Владение флагом → в `SettingsStorage`, авто-dirty на config-ключах

Флаг переезжает в хранилище (там же `_save` с touch, там же знание про
config-ключи). `SubscriptionController.configDirty` становится **делегатом**
— все существующие места чтения/записи (49 обращений в 13 файлах)
компилируются без правок.

Config-значимый сейвер хранилища сам поднимает dirty — «поменять
настройку, не задев флаг» становится структурно невозможно:

| Сейвер | config-значим | dirty |
|---|---|---|
| `setTunApps`, `saveDnsServers`, `saveDnsRulesList`/`saveDnsRules`, `saveCustomRules`, `saveEnabledRules`, `saveEnabledGroups`, `saveRouteFinal`, `saveRuleOutbounds`, `saveExcludedNodes` | да (типизированные, целиком) | авто |
| `setVar(name, …)` | только если `name ∈` config-vars allowlist | авто при попадании |
| `saveServerLists` | **двойного назначения** (узлы — да, метаданные обновления — нет) | НЕ авто; узловые call-sites ставят явно + ребилдят инлайн |
| `setNodeSort`, `savePingOptions`, `setGlobalPing*`, `setLastGlobalUpdate`, update-checker vars, wifi_history, debug/backup | нет | не ставят |

**Config-vars allowlist** (12) — template-`@var`, реально подставляемые в
`config` (`wizard_template.json`), минус машинно-генерируемые
`clash_api`/`clash_secret` (выходы сборки, не пользовательский ввод;
иначе writeback в `generateConfig` сам бы крутил флаг):
`auto_detect_interface`, `dns_default_domain_resolver`, `dns_final`,
`dns_strategy`, `log_level`, `resolve_strategy`, `tun_address`,
`tun_auto_route`, `tun_mtu`, `tun_name`, `tun_stack`, `tun_strict_route`.

## Затронутые файлы

- [config_dirty_check.dart](../../app/lib/services/config_dirty_check.dart) — `touchConfig()`.
- [settings_storage.dart](../../app/lib/services/settings_storage.dart) — `_configDirty` бит + getter/setter + `markConfigDirty()` + config-vars allowlist + reset в `resetCacheForTesting`/`clearCache`; import `config_dirty_check`.
- [settings_storage/io.dart](../../app/lib/services/settings_storage/io.dart) — touch в `_save` при `!_configDirty`.
- [settings_storage/network.dart](../../app/lib/services/settings_storage/network.dart), [sources_rules.dart](../../app/lib/services/settings_storage/sources_rules.dart), [backup_tun.dart](../../app/lib/services/settings_storage/backup_tun.dart), [vars.dart](../../app/lib/services/settings_storage/vars.dart) — `markConfigDirty()` в config-значимых сейверах + allowlist-проверка в `_setVar`.
- [subscription_controller.dart](../../app/lib/controllers/subscription_controller.dart) — `configDirty` field → getter/setter-делегат на `SettingsStorage`.

## Locked decisions

1. Без диффа содержимого — аномалии видимы, не замаскированы.
2. Модель записи настроек (флаш-на-уходе, без debounce) **не трогаем** —
   для редких осознанных правок это норм; `paused` — надёжный хук перед
   kill; debounce платит лишними записями за редкий «краш на экране».
3. config-значимость — свойство **ключа/сейвера**, не места вызова
   (нельзя разойтись «тут true, там false»).
4. `saveServerLists` вне авто-dirty (двойного назначения); узловые правки
   ставят флаг явно и ребилдят инлайн (`_regenerateAndSave`).

## Риски и edge cases

- `touchConfig` при отсутствии конфиг-файла (VPN ни разу не стартовал) —
  no-op; `isDirty` вернёт true (config==null) → корректно (надо собрать).
- `setLastModified` усекает до целой секунды, `stat().modified` хранит
  суб-секунду → touch к точному mtime не round-trip'ится; решено
  секундной резолюцией в `isDirty` (флор обоих). Узкий tradeoff: реальная
  config-правка + kill-до-пересборки **в ту же секунду** что и предыдущая
  чистая запись → не детектится (< 1 c окно). На практике редактирование
  занимает больше; в живом процессе ловится пересборкой на возврате —
  mtime лишь kill-recovery.
- generated-vars writeback (`clash_api`/`clash_secret`) — вне allowlist,
  плюс `configDirty=false` ставится **после** `_generate()`, самоиндукции
  нет в любом случае.
- Делегат — статический бит процесса; `resetCacheForTesting` его сбрасывает.

## Верификация

- Unit [config_dirty_flag_test.dart](../../app/test/services/config_dirty_flag_test.dart)
  (6 кейсов): config-значимый сейвер поднимает dirty; не-config
  (sort/ping/timestamp) — нет; `setVar` config-var → dirty, прочий var
  (вкл. `clash_secret`) → нет; `_save` при `!dirty` → config выровнен,
  `isDirty=false`; при dirty → config не тронут, `isDirty=true`;
  репро-сценарий (правка → пересборка снимает флаг → flush → холодный
  старт → `isDirty=false`). ✅
- `flutter analyze` чистый, полный `flutter test` — 959 passed. ✅
- Local release APK + установка на устройство: правка Tunnel apps → kill
  из recents → запуск → баннера нет; реальная правка → баннер есть.
  **Pending** (девайс-smoke).

## Нерешённое / follow-up

- Allow-list, глушащий свои приложения (отдельный field report Михаила) —
  **не этот баг**; диагностируется отдельно (гипотеза: DNS на tun-адрес
  не проходит OS-фильтр allow на части прошивок). Нужна версия приложения
  + Android/прошивка репортеров + тест `http://1.1.1.1` из allow-списка.
