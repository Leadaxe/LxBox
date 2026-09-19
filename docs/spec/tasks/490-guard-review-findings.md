# §490 — находки ревью страховки ядра (478)

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | независимое ревью `/tmp/lx_review/guard_builder_api.md` |
| **Связанные** | фича 478, `docs/api/debug-api-reference.md`, `help.dart` |

## Проблема

Независимое ревью кода страховки от отказа ядра и Debug API выявило 11
находок: гонки при повторном Start, зависание на 45 с при сбое `startVPN`,
дыра в обратной карте тегов для хопов цепочки, отмена после `checkConfig`,
утечка секретов в `/nodes/link`, несимметричный enable по emitted-тегу,
неработающий снятие предела кругов на headless-пути, долгий HTTP на
`?guard=true`, неполный GC оверлея `warnings`, проглатывание error-несущего
`Stopped` в stale-terminal, устаревший текст `/help`.

## Решение

По каждой находке — красный тест, затем минимальный фикс. Видимые строки UI
не менялись.

| № | Находка | Воспроизвелось? | Фикс |
|---|---|---|---|
| 1 | Повторный Start затирает `_startOutcome` | да | `runCoreRejectGuard` single-flight; join в `startAndAwaitVerdict`; `guardActive` блокирует кнопку |
| 2 | Сбой `startVPN` — 45 с зависания | да | `_settleStartOutcome` при `lastError` после `start()` |
| 3 | `?guard=true` — HTTP-таймаут vs долгий прогон | да | async `{started, async}` + `GET /core_reject` |
| 4 | Предел 10 кругов на API | да | `askKeepChecking` → `CoreRejectState.askPrompt`; очередь `answer=keep` |
| 5 | enable/notifications не принимают emitted-тег | да | `enableNodeByCoreTag` через `lastEmittedTagMap` + `revertVerdict`; notifications lookup |
| 6 | Хоп цепочки нет в `nodeByEmittedTag` | да | `noteEmittedAlias` при сборке detour |
| 7 | Отмена после успешного check поднимает VPN | да | проверка `_cancelled` после `check` и перед `finalStart` |
| 8 | `/nodes/link` без `reveal` отдаёт секреты | да | `{error:"reveal required"}` без `uri` |
| 9 | GC `warnings` не вместе с `disabled` | да | `gcNodeWarnings` на refetch |
| 10 | Stale-terminal глотает `core_error` | да | `_settleStartOutcome` в stale-ветке |
| 11 | `/help` врёт про prompt | да (текст) | help + debug-api-reference |

## Критерии приёмки

- Таблица выше: все «да» закрыты тестами в `test/controllers/home_core_reject_test.dart`, `test/services/core_reject_*`, `test/services/debug/core_reject_review_test.dart`.
- `flutter analyze` — без новых issues (baseline 19).
- `help_json_test` зелёный; затронутые тесты зелёные.
- Спека 478 и `docs/api/debug-api-reference.md` обновлены.
