# 574 — `tls.fragment` уступает `detour` сборки и системному TLS-движку (контракт 1.1.84)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-27 |
| Дата завершения | 2026-09-27 |
| Коммиты | `chore(contract): синк 1.1.84 (c5f489df)`; `feat(574): tls.fragment уступает detour сборки и системному TLS-движку` |
| Контракт | 1.1.84, коммит лаунчера `c5f489df`, `TASKS_LXBOX.md` §81 |
| Связанные spec'ы | [§573](573-xray-finalmask-tcp-fragment.md) (исследование ядра и факты для этой задачи), [§488](488-xray-dialer-proxy-freedom-fragment.md) |

## Проблема

Узел, получивший `tls.fragment: true` из Xray (§488, §573), может при сборке
конфига получить ещё и `detour` — от цепочки или от `override_detour` подписки.
В конфиг уходят оба поля. Установлено тестом в §573.

Для ядра это плохое сочетание (обоснование — §573, «Исследование: логика
ядра»):

- Под `detour` ядро не может ждать ACK сегмента и после каждого спит
  `fragment_fallback_delay` — 500 мс.
- Явный флаг отключает дефолт ядра для узлов под `detour` (`record_fragment`,
  защита от потери большого ClientHello из-за PMTU).
- Jump-узел и так выводит трафик из-под DPI, фрагментация там не нужна.

Второй случай той же нормы: фрагментация вместе с системным TLS-движком
(`tls.engine` = `apple` / `windows`) роняет старт конфига.

## Диагностика

- Глобальная настройка фрагментации (`applyTlsFragment`,
  `app/lib/services/builder/post_steps/tls_transforms.dart`) outbound с `detour`
  уже пропускает. Узловой флаг этой проверки не проходит: он приходит в теле
  узла из разбора.
- Связи полей реестра (`conflicts`) исполняет санитайзер
  (`app/lib/services/contract/body_sanitizer.dart`, там же `fieldAllowedOn`).
- Такая же связь с `detour` уже есть у `listen_port` (контракт 1.1.65):
  `detour` пишет сборка, связь проверяется по готовому телу.
- Probe-конфиг (`app/lib/services/probe/probe_config.dart`) назначает `detour`
  в обход `buildConfig`.

## Решение

Норма — `TASKS_LXBOX.md` §81, исполняется как записана.

### Правила

| Случай | Что происходит | Код |
|---|---|---|
| `tls.fragment` и `detour`, назначенный сборкой | Снимается `fragment` | `detour_with_tls_fragment`, info, параметры `tag`, `target` |
| `tls.record_fragment` и `detour` | Ничего: связи нет | — |
| `fragment` или `record_fragment` и `tls.engine` = `apple` / `windows` | Снимается фрагментация, движок остаётся | `tls_fragment_system_engine`, warning, параметры `path`, `with` |
| `detour`, написанный во входе sing-box, и `fragment` там же | Ничего: `fragment` остаётся | — |

Последняя строка — норма санитайзера: управляемое поле (`detour`) во входе для
связей соседей считается отсутствующим, потому что `detour` входа до ядра не
доезжает.

Уведомление `detour_with_tls_fragment` остаётся информационным — решение
владельца 27.09.2026.

### Работа

1. Синк контракта на `c5f489df`: `app/tool/sync_contract.sh --to c5f489df`,
   сверка `app/contract.lock`, зеркала.
2. Снятие `tls.fragment` под `detour` сборки — по связи реестра, тем же путём,
   что `listen_port` × `detour`. Вместе с флагом снимается осиротевший
   `fragment_fallback_delay`, если `record_fragment` не задан. Правило действует
   на любой узловой флаг, а не только выведенный из Xray.
3. Код `detour_with_tls_fragment` попадает в предупреждения сборки узла и виден
   в его уведомлениях.
4. Санитайзер: `detour` входа в связях соседей не учитывается (п. 3 нормы);
   код `tls_fragment_system_engine`.
5. Probe-конфиг: то же снятие `fragment` под `detour`. Кода там нет — у
   probe-сессии нет поверхности уведомлений.

### Как сделано

- Правило 1 исполняет прежний путь связи `listen_port` × `detour`: `applyDetourYields` (`post_steps/tls_transforms.dart`) → новая `yieldToBuildDetour` (`builder/detour_yields.dart`) → `yieldToManaged` (`body_sanitizer.dart`); сам код связи берётся из реестра. `yieldToBuildDetour` вслед за `tls.fragment` снимает осиротевший `fragment_fallback_delay`.
- `build_config.dart`: коды `applyDetourYields` кладутся и в `emitWarnings`, и в `registryReport.warningsByEmittedTag` → `nodeBuildWarningsByEmittedTag` → `lastBuildWarningsByTag`, то есть в уведомления узла.
- Правило 4: `_presentInSource` санитайзера считает `managed`-поле (`_managedAt`) отсутствующим для связей соседей. Правило 3 заработало само, от данных реестра.
- Probe: `_assemble` в `probe_config.dart` зовёт `yieldToBuildDetour` сразу после назначения `detour`, код отбрасывается.
- Генератор тел круга §476 (`test/contract/body_field_generator.dart`) учитывает `when` у `conflicts`.

## Риски и edge cases

- **Узел с `detour` из входа sing-box** после сборки может получить `detour`
  уже от приложения. Тогда связь срабатывает: `detour` в готовом теле написан
  сборкой.
- **Оба флага под `detour`.** Снимается только `fragment`; `record_fragment`,
  заданный явно, остаётся и уходит одним `Write` без пауз.
- **Значок `ⓘ` на узлах подписки с `override_detour`** появится у каждого узла
  с фрагментацией. Принято владельцем.

## Верификация

- Кейсы корпуса `body/singbox/tls_fragment_detour_in_body` и
  `body/singbox/tls_fragment_system_engine` зелёные.
- Тест сборки: узел из Xray с `finalmask` и `override_detour` — в конфиге есть
  `detour`, нет `tls.fragment`, есть предупреждение `detour_with_tls_fragment`.
- Тест сборки: тот же узел без `detour` — `tls.fragment: true`, предупреждений
  нет.
- Тест сборки: узел с явным `record_fragment` под `detour` — флаг на месте.
- Регрессия: тесты `listen_port` × `detour` и `applyTlsFragment` без изменений.

## Нерешённое / follow-up

Нет.
