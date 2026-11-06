# §644 — Дефолтные пресеты засеваются до первого открытия Routing

| Поле | Значение |
|------|----------|
| Тип | Дефект |
| Статус | D (done), выпущено в v2.25.15 |
| Дата | 2026-10-14 |
| Связанные | §159 (метка `presets_migrated`), §578 (поздние дефолты `late_presets_seeded`), [024-TEMPLATE · template-lifecycle](../features/024-TEMPLATE/FUNCTIONS/template-lifecycle.md) («A clean install»), `docs/STORAGE.md` (`presets_migrated`) |

## Проблема

Чистая установка (эмулятор, v2.25.14): пользователь добавляет узел и жмёт
Connect, не открывая экран Routing. Пресеты шаблона с `ui.default: true`
(`ru-direct`, `bittorrent`, `tailscale`, `unknown-traffic`, `vowifi`) в
собранный конфиг не попадают: `/state/rules` пуст, в `route.rules` только
обязательный `traffic-processing` (sniff / hijack-dns / resolve), `rule_set`
пуст. После первого открытия Routing и пересборки пресеты появляются. Узел
Tailscale, добавленный до открытия Routing, правил пресета `tailscale` не
получает.

Спека обещает иное: «A clean install. Presets with `ui.default: true` are
added once (the marker `presets_migrated`)» — без привязки к экрану.

## Диагностика

- Первый seed дефолтов жил только в экране:
  `RoutingScreen._seedDefaultPresets` (`routing_srs_cache.dart`, вызов из
  загрузки экрана), он же ставил `presets_migrated`.
- Сборка (`SubscriptionController`, перед `BuildSettings`) звала только
  `seedLateDefaultPresets` (§578), а тот на свежей установке — no-op по
  построению: `if (data['presets_migrated'] != true) return false`
  (`sources_rules.dart`). Досевались лишь несортируемые пресеты
  (`seedRequiredPresets`), отсюда один `traffic-processing`.
- Воспроизведено на AVD: `pm clear`, запуск без Routing, `POST /subs`
  (vless), `POST /action/rebuild-config` → `/state/rules` = `[]`, в
  `/state/storage` нет `presets_migrated`, в конфиге три служебных правила.

## Решение

Seed перенесён в хранилище: `SettingsStorage.seedDefaultPresets([template])`
(`sources_rules.dart`). Если `presets_migrated` не стоит — добавить в правила
все `default: true` пресеты шаблона (`selectableRuleToCustom`, как делал
экран), пропуская уже лежащие в правилах по `presetId` (импорт, Debug API),
и поставить метку через `_markDefaultsSeeded` (она же закрывает поздние id
§578). Шаблон недоступен — предупреждение в лог, метка не ставится, попытка
повторится.

Вызовы:

1. `main()` — после миграции Направлений, до первого билда.
2. `SubscriptionController` — перед `seedLateDefaultPresets` и
   `BuildSettings` (покрывает слоты workspace, импорт, сборку из фона).
3. Экран Routing — перед `seedLateDefaultPresets` и `getCustomRules`;
   экранный `_seedDefaultPresets` удалён.

`seedLateDefaultPresets` не менялся. Разовость прежняя: метка
`presets_migrated`, удалённый пользователем пресет не возвращается.

## Риски и граничные случаи

- Пресет с не скачанным `.srs` (`ru-direct`) теперь попадает в конфиг до
  открытия Routing — так же, как раньше после открытия экрана; ожидание
  файла — по §601 (P11).
- Импорт бэкапа без `presets_migrated` на свежей установке: дефолты
  досеваются к импортированным правилам, но уже лежащие по `presetId` не
  дублируются (раньше экран добавлял копию, и §398 оставлял последнюю —
  дефолтную).

## Проверка

- `app/test/services/late_default_presets_test.dart`, группа «§644 первый
  seed дефолтов»: свежая установка получает все `default: true` пресеты, и
  поздний шаг после этого ничего не добавляет; повторный вызов не
  возвращает удалённый пресет; при `presets_migrated` ничего не делает;
  пресет, уже лежащий в правилах, не дублируется и сохраняет выбор
  пользователя.
- `flutter analyze` чистый.
- На устройстве после сборки с правкой: `pm clear` → запуск без Routing →
  `/state/rules` содержит дефолтные пресеты, `route.rules` — правила
  `bittorrent` и др.

## Нерешённое

—
