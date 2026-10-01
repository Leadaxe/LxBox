# §594 — Save узла из INI (WireGuard/AWG) отказывал с «Invalid JSON»

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | D (done) |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.ru.md) |
| Дата | 2026-09-30 |
| Связанные | §455, §456 (INI-источник пишется как есть) |

## Проблема

Отчёт из чата 29.09.2026: узел, импортированный из файла `.conf` (AWG 3.1),
работает, но любая правка в экране узла — даже смена тега — на Save даёт
«Invalid JSON: Unexpected character». С WARP, созданным в приложении, не
воспроизводится.

## Диагностика

Save вкладки Source (`node_settings_screen.dart`, `_saveSource`) выбирал
JSON-ветку по первому символу: `{` или `[`. INI начинается с `[Interface]` и
уходил в `prepareNodeDocumentForSave` → `jsonDecode` → отказ. Ветка INI
(§456, текст как есть) была недостижима. WARP хранится JSON-телом, поэтому
его это не касалось.

## Решение

Чистая функция `isJsonSourceText` в `node_settings/node_document.dart`:
`{` — JSON; `[` — JSON, только если `originKindOf` не `wg_ini`. Экран
решает ею. Битый JSON-массив по-прежнему идёт JSON-веткой и получает
осмысленный отказ.

## Проверка

`app/test/screens/node_settings/node_document_test.dart`, группа
«ссылка и INI»: INI с `[Interface]` и ссылка — не JSON; объект, массив и
битый массив — JSON.
