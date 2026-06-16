# 137 — WARP node naming: «Cloudflare WARP» + гроза для AWG + накопление узлов

| Field | Value |
|------|----------|
| Status | Implemented |
| Started | 2026-06-16 |
| Trigger | Запрос юзера: переименовать WARP-узлы в осмысленный шаблон с эмодзи в теге; разные иконки plain vs AWG-обфускация (облако ☁️ vs гроза ⛈️); убрать авто-удаление старых WARP при перерегистрации (юзер сам решает, нужны ли дубли — может регать несколько конфигов с разными endpoint/SNI). |
| Related | [§025 warp integration](../features/025%20warp%20integration/spec.md) (тег WARP/WARP+); [§126](126-warp-amneziawg-obfuscation.md) / [§136](136-warp-quic-i1-generator.md) (AWG-обфускация); [node_emoji.dart](../../../app/lib/services/node_emoji.dart) (эмодзи по тегу) |
| Files touched | `services/warp/warp_account.dart` (tag), `controllers/subscription_controller.dart` (тег + убрать removeWhere + коллизии), `services/node_emoji.dart` (backward-compat матч) |

## Шаблон тега (с эмодзи ВНУТРИ тега)

| Случай | Тег |
|---|---|
| plain WARP | `🔥☁️ WARP` |
| plain WARP+ | `🔥☁️ WARP+` |
| AWG-обфускация | `🔥⛈️ WARP (AWG 1.5)` |
| AWG WARP+ | `🔥⛈️ WARP+ (AWG 1.5)` |
| коллизия (тег занят) | `… 2`, `… 3`, … (суффикс) |

**Гроза ⛈️ вместо облака ☁️** при включённой AWG-обфускации — визуальный сигнал
«этот узел маскируется от DPI».

## Изменения

### 1. Убрать идемпотентность (накопление вместо замены)
[subscription_controller.dart](../../../app/lib/controllers/subscription_controller.dart)
`addWarp` — **удалить** блок `_entries.removeWhere(... тег WARP/WARP+)`. Каждый
Get WARP добавляет НОВЫЙ узел. Юзер сам удаляет лишние свайпом (решение юзера:
«пользователь сам решит, нужны ли дубли — а если он разные генерирует?»).

### 2. Тег-билдер + коллизии
Хелпер `_warpTag(warpPlus, hasAwg)` → базовый тег по таблице. Коллизия:
если тег уже есть среди `_entries`-узлов — суффикс ` 2`/` 3`/… (инкремент до
свободного). Применяется и к plain-пути (`toWireguardUri`/`addFromInput`), и к
обфусцированному (`_addWarpObfuscated`).

### 3. Эмодзи в теге → node_emoji не дублирует
`withDefaultEmoji` уже no-op если в теге есть эмодзи ([node_emoji.dart](../../../app/lib/services/node_emoji.dart)).
Эмодзи 🔥☁️/🔥⛈️ внутри тега → авто-эмодзи не сработает (правильно). Старый
точный матч `bareTag == 'WARP'` в `defaultEmojiFor` оставляем для backward-compat
(узлы, созданные до §137, имеют голый тег `WARP`).

## Acceptance

- [ ] Plain WARP → тег `🔥☁️ WARP` (+ `+` для WARP+).
- [ ] AWG → тег `🔥⛈️ WARP (AWG 1.5)` (гроза).
- [ ] Повторный Get WARP НЕ удаляет прежние узлы (накопление).
- [ ] Коллизия тега → суффикс ` 2`/` 3`.
- [x] node_emoji не дублирует эмодзи (он уже в теге); старые `WARP`-узлы не теряют иконку (backward-compat матч сохранён).
- [x] `flutter analyze` чисто; тесты зелёные (1133).

## Implementation (2026-06-16)

| Spec item | Code |
|---|---|
| Тег-билдер (☁️/⛈️, +, AWG) | `warp_account.dart` — `static nodeTag({warpPlus, hasAwg})` |
| Эмодзи во фрагменте URI | `toWireguardUri` — `nodeTag(...)` + `Uri.encodeComponent` фрагмент |
| Убрана идемпотентность | `subscription_controller.dart` — `removeWhere(... WARP)` удалён |
| Коллизия-суффикс | `_uniqueWarpTag(base)` → ` 2`/` 3` против активных тегов |
| Раздельные add-пути с тегом | `_addWarpObfuscated(account, tag)` + новый `_addWarpPlain(account, tag)`; `rawBody = tagged.toUri()` (тег во фрагменте → переживает reload) |
| Тесты | `warp_client_test.dart` — `§137 nodeTag` + обновлён URI-тег тест |

**NB:** `rawBody` теперь `toUri()` (не `rawUri`) — `toUriWireguard` кладёт `s.label`
во фрагмент, так тег с эмодзи переживает re-parse при перезагрузке.
