# §611 — Снять `passive_check` и поднять ядро на v1.14.2-lx.12

| Поле | Значение |
|------|----------|
| Тип | F (доработка) + бамп ядра |
| Статус | D (done; эмулятор 08.10.2026 — ОК) |
| Фича | [006-DETOUR_AND_BALANCE](../features/006-DETOUR_AND_BALANCE/FEATURE.md), `docs/KERNEL.md` |
| Дата | 2026-10-08 |
| Связанные | §272 (passive_check введён), §273 (энергоаудит), §612 (режим `failover`, миграция), §613 (пиры WG, путь Tailscale) |

## Проблема

Ядро [v1.14.2-lx.12](https://github.com/Leadaxe/sing-box-lx/releases/tag/v1.14.2-lx.12)
удалило ключ `urltest.passive_check` без периода совместимости (SPEC 116 ядра):
ключ неизвестен, конфиг с ним **не загружается**. LxBox по умолчанию пишет
`passive_check: true` в каждую авто-группу (§272):
`services/builder/server_list_build.dart:288`,
`services/builder/source_replace_build.dart:163`, параметр `passiveCheck`
в `build_config.dart:1195`, настройка на экране Optimization
(`settings_screen.dart` §272), ключ хранилища `urltest_passive_check`
(`settings_storage/network.dart`, `settings_storage.dart`), экспорт в бэкап
(`backup_service.dart:45`).

Бамп ядра без выпила ключа = неработающий VPN у всех с авто-группами. Два
изменения идут одним пакетом, в одной задаче.

Что ещё даёт lx.12 (используют §612/§613, здесь только фиксируем Java-поверхность):
`CommandClient.GetWireGuardStatus(tag)`, `GetTailscaleStatus(tag)`,
`TailscalePeer.Path/Endpoint/PeerRelay/DERPRegionCode/LastHandshake`,
`TailscaleEndpointStatus.Health()`, режим `urltest.mode = failover`. Форк
пересобран на scope-жизненный цикл апстрима (SPEC 117): сон WG-эндпоинтов,
ленивая сборка и ручное выключение регистрируются в scope.

## Решения (Fable, автономно, 08.10.2026)

1. Ключ `passive_check` из эмиттера снимается полностью: ни по настройке, ни
   по умолчанию. Параметр `passiveCheck` из сборщиков удаляется вместе с
   протаскиванием.
2. Настройка «Passive health check» с экрана Optimization удаляется вместе с
   l10n-строками (EN-источник и `ru`-перевод).
3. Значение в хранилище (`urltest_passive_check`) **НЕ стирать и не
   переименовывать**: §612 читает его один раз для миграции режима авто-групп
   (true/отсутствует → `failover`), после чего сам удалит ключ. В §611 ключ
   перестаёт писаться и показываться, геттер остаётся как `@Deprecated`-чтение
   с комментарием «§612 снимет».
4. Бэкап: ключ больше не экспортируется. При импорте старого бэкапа с этим
   ключом — молча игнорировать, без предупреждения. Если ключ упомянут в
   `app/contract/docs/BACKUP.md` или корпусе бэкапа — `app/contract/**` НЕ
   править (read-only), оставить разбор терпимым и записать в отчёт строкой
   «для лаунчера: снять `urltest_passive_check` из BACKUP.md».
5. Ядро: `app/android/libbox.version` → `v1.14.2-lx.12`;
   `kCoreBuildTagsPin` в `services/builder/core_chain_capability.dart` → то же
   (тест `test/contract/node_core_gate_test.dart` сверяет).
6. `docs/KERNEL.md`: пин, строка истории версий, Java-поверхность lx.12
   относительно lx.11 — **по javap, списком, одним вызовом** (регламент в
   KERNEL.md; `xargs -a` молча пуст, только `$(cat list)`). Перечислить новые
   классы/методы: ожидаются `WireGuardEndpointStatus`, итератор пиров WG,
   новые геттеры `TailscalePeer`, `TailscaleEndpointStatus.Health`,
   `CommandClient.GetWireGuardStatus/GetTailscaleStatus`. Удалений не
   ожидается — если javap покажет удаление, остановиться и доложить.
7. `CHANGELOG.md`: запись в Unreleased, EN+RU, без «§611» в видимом тексте
   пользователю (внутренняя ссылка в скобках допустима по образцу соседних
   записей).

## Что сделать

- Эмиттер: убрать запись `passive_check` в обоих местах и параметр
  `passiveCheck` во всей цепочке вызовов; комментарии про §272 в
  `direction.dart:149`, `build_config.dart:160,1420`,
  `source_replace_build.dart:145` переписать: «passive_check снят в §611,
  замена — режим failover (§612)».
- Настройки: удалить поле `_passiveCheck`, секцию UI, ключ из списка
  config-significant (`settings_storage.dart:185`) и из бэкапа
  (`backup_service.dart:45`). Чтение из `network.dart` оставить (п. 3).
- Тесты: найти тесты, ожидающие `passive_check` в emit (grep по `passive_check`
  в `test/`), перевернуть на «ключа нет»; тест на импорт бэкапа с лишним
  ключом — ключ игнорируется, импорт успешен.
- Ядро: пп. 5–6. AAR тянет `scripts/fetch-libbox.sh`; при обрыве curl —
  `gh release download v1.14.2-lx.12 --repo Leadaxe/sing-box-lx
  --pattern 'libbox-1.14.2-lx.12.aar'` и ручная сверка с `SHA256SUMS`.
- Спека §272: в таблицу статуса строку «passive_check снят в §611 (ядро lx.12
  удалило ключ), замена — §612».
- Доки фичи 006: если `passive_check` упомянут — заменить на отсылку к
  failover (§612) без описания самого режима (его опишет §612).

## Риски и границы

- `app/contract/**`, `app/contract.lock`, `pubspec.lock`,
  `analysis_options.yaml` не трогать. Корпус контракта пока на
  `body.core = 1.14.2-lx.11` — если какой-то тест сверяет версию ядра с
  контрактом и краснеет, **не чинить контракт**, а доложить: это закроет синк
  в §612.
- Миграцию режима авто-групп НЕ делать здесь — §612.
- `tolerance`/`balancer` в failover — §612.

## Проверка

- `flutter analyze` всего проекта (из `app/`), новых issue 0.
- Локально — только изменённые/новые тест-файлы, по одному.
- Эмулятор: отдельный прогон после волны §611–§614 (запуск VPN с авто-группой
  из синтетических WG-эндпоинтов, старт ядра без ошибки «unknown key»).

## Итог

- Эмиттер: `passive_check` не пишется ни в двойники Направлений, ни в свёртки
  (`buildAutoGroup`), ни в узлы автовыбора папок; `passiveCheck` снят из
  `BuildSettings`, `_BuildCtx`, `EmitContext`, `materializeReplaceGroups`,
  `_buildDirectionGroups`.
- Настройка «Passive health check» снята с экрана Optimization вместе со
  строками `ru`/`zh` (EN-ключи жили только в коде).
- Сторадж: `savePassiveCheck` удалён, `getPassiveCheck` — `@Deprecated`
  (читатель — миграция §612). Ключ выведен из import-allowlist
  (`allowedTopLevelKeys`, это и был «список settings_storage.dart:185») и из
  экспорта бэкапа; заведён `SettingsStorage.retiredTopLevelKeys`: при импорте
  старого бэкапа ключ молча пропускается (в `droppedKeys` не попадает), при
  замене (`merge=false`) значение получателя переносится — §612 его прочтёт.
- Ядро: `libbox.version` и `kCoreBuildTagsPin` → `v1.14.2-lx.12`; javap
  lx.11 → lx.12 — только добавления (254 → 258 классов), записано в
  `docs/KERNEL.md`.
- Эталоны `avd_v0.config.json` и `rich_v0.backup_roundtrip.json`
  перезаписаны (`UPDATE_GOLDEN=1`): ушли только строки `passive_check`.
- Доки: кроме фичи 006 поправлены текущие описания в 009 (urltest-group,
  FEATURE), 026 (direction-health, direction-groups-in-config) и STORAGE.md.

## Нерешённое / хвосты

- `test/contract/direction_corpus_test.dart` держит `passive_check` в
  `_templateOnlyKeys` — безвредно (в корпусе контракта ключа нет); снять при
  синке контракта в §612.
- Секция Optimization сохранила описание «Health checks, memory and VPN
  lifecycle» — проверка здоровья вернётся туда режимом `failover` (§612).
