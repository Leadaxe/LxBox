# §301 — Единый регистр для regex-фильтров нод (case-insensitive)

**Тип:** bugfix (несогласованность поведения) · **Статус:** ✅ реализовано · **Размер:** S · **Область:** node-filter (UI + билдер)

Один и тот же regex-паттерн фильтра нод компилируется с **разным** учётом регистра в разных местах. В основном окне поиска — без учёта регистра, в фильтре канала (и в билдере, который строит реальный конфиг) — с учётом. Юзер вводит `warp`, ждёт одинакового поведения, получает разное.

## Проблема

Репро (4PDA #1155): слово в фильтре основного окна матчит без учёта регистра, а сохранённое как фильтр канала — уже с учётом. Приходится писать `warp|Warp|WARP`. Обход `(?i)warp` не работает — Dart `RegExp` не понимает inline-флаги, только именованный параметр `caseSensitive`.

Расхождение по коду:

| Место | Файл:строка | `caseSensitive` |
|---|---|---|
| Основное окно: живой поиск | [`node_filter_view_model.dart:99`](../../../app/lib/screens/home/node_filter_view_model.dart) | `false` |
| Основное окно: сохранённый фильтр | [`node_filter_view_model.dart:283`](../../../app/lib/screens/home/node_filter_view_model.dart) | `false` |
| Фильтр канала: UI-превью | [`channel_edit_screen.dart:238`](../../../app/lib/screens/channel_edit_screen.dart) | голый (= `true`) |
| Фильтр канала: UI-подсчёт нод | [`routing_screen.dart:334`](../../../app/lib/screens/routing_screen.dart) | голый (= `true`) |
| **Билдер: `nodeFilter` + `defaultFilter`** | [`build_config.dart:583/650/746`](../../../app/lib/services/builder/build_config.dart) | голый (= `true`) |

Билдерская ветка — не косметика: `_tryCompileRegex` (`:746`) регистрозависимо решает, **какие ноды реально попадают в канал** в итоговом конфиге. То есть регистр фильтра канала влияет на маршрутизацию, а не только на превью.

## Решение

Сделать все node-filter regex регистронезависимыми — привести к поведению основного окна (`caseSensitive: false`).

Точки правки:
- `channel_edit_screen.dart:238` `_compile` → `RegExp(pattern, caseSensitive: false)`.
- `routing_screen.dart:334` `_nodeCountFor` → `RegExp(channel.nodeFilter, caseSensitive: false)`.
- `build_config.dart:746` `_tryCompileRegex` → `RegExp(pattern, caseSensitive: false)` (покрывает и `nodeFilter`, и `defaultFilter`).

Один флаг в трёх точках компиляции. Основное окно уже такое — не трогаем.

**Вариант «галка /i» отклонён:** три-четыре места компиляции + сериализация состояния галки в canal-модель и подписки = несопоставимо больше кода ради опции, которую в этом домене (фильтр по тегам нод) никто не просил в обратную сторону. Регистронезависимость — разумный дефолт для поиска по именам; нужен точный матч — пользователь всё равно уточнит паттерн. Если позже понадобится per-filter регистр — отдельная спека.

**Совместимость:** переход `true → false` только **расширяет** матч (больше тегов подпадает). Риск — паттерн, который у кого-то намеренно отсекал ноду регистром (напр. фильтр канала завязан на `WARP`, но не `warp`). Маловероятно для тегов нод, но упомянуть в release notes: «regex-фильтры нод теперь регистронезависимы».

## Файлы

- `lib/screens/channel_edit_screen.dart` — `_compile`.
- `lib/screens/routing_screen.dart` — `_nodeCountFor`.
- `lib/services/builder/build_config.dart` — `_tryCompileRegex`.

## Приёмка

- Фильтр канала `warp` матчит `WARP-01`, `Warp-tokyo`, `warp-x` одинаково в UI-превью, подсчёте нод и в собранном конфиге.
- Основное окно и фильтр канала для одного паттерна дают одинаковый набор нод.
- `defaultFilter` (fallback-нода) — тоже регистронезависим.
- Невалидный regex по-прежнему деградирует как раньше (превью null / билдер «все ноды»), поведение ошибки не меняется.
- Builder-тест: канал с фильтром в другом регистре, чем теги нод → ноды попадают (раньше — пустой набор). ✅ `channel_groups_test.dart` (`nodeFilter: 'berlin'`/`'nyc'` + `defaultFilter: 'premium'`).

**Тесты:** добавлены два кейса в `test/builder/channel_groups_test.dart` (F2 nodeFilter + F3 defaultFilter). Побочно: `detour_channel_gates_test.dart` завязывал разделение каналов на регистр (`BL Helsinki` содержал «in» → после §301 попал бы и в фильтр `IN`); фикстура переименована `BL Helsinki`→`BL Varna` — ровно тот класс совместимости, о котором предупреждает заметка выше.

## Docs to update

- Release notes — «Node-filter regex теперь case-insensitive» (см. заметку о совместимости выше).
