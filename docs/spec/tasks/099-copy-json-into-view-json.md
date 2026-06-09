# 099 — Copy-JSON варианты из контекстного меню ноды → в View JSON

| Поле | Значение |
|------|----------|
| Тип | UI cleanup (уменьшение контекстного меню) |
| Триггер | Юзер: «уменьшим контекстное меню — Copy JSON / Copy detour / Copy server detour уберём внутрь View JSON; на Copy-иконке выпадашка если есть detour, просто copy если нет» |

## Было

Контекстное меню ноды (`node_row.dart` long-press popup) содержало 4 copy-пункта:
`Copy URI`, `Copy server (JSON)`, `Copy detour`*, `Copy server + detour`* (*только
при detour). Перегружено.

## Стало

- **Контекстное меню:** убраны `copy_server` / `copy_detour` / `copy_both`
  (+ их switch-кейсы + неиспользуемый `onCopy`-параметр `NodeRow`). Остался
  `Copy URI` (это URI-ссылка, не JSON).
- **View JSON** (`OutboundViewScreen`): Copy-аффорданс в AppBar стал умным —
  - **есть detour** → `PopupMenuButton` (выпадашка): `Copy JSON` (server) /
    `Copy detour` / `Copy server + detour`;
  - **нет detour** → простая `IconButton` Copy (= `Copy JSON`).
- `viewOutboundJson` считает `hasDetour = intro.detourOf(tag) != null` и
  пробрасывает `onCopy: (mode) => copyNodeJson(context, tag, state, mode)`
  (`mode`: `server`|`detour`|`both` — та же логика, что была в меню).

## Файлы

| Файл | Что |
|------|-----|
| `widgets/node_row.dart` | −3 copy-пункта, −switch-кейсы, −`onCopy` field/param |
| `screens/outbound_view_screen.dart` | +`hasDetour`/`onCopy`; Copy → dropdown / plain |
| `screens/home/node_actions.dart` | `viewOutboundJson` пробрасывает `hasDetour`+`onCopy` |
| `screens/home/widgets/node_list.dart` | убран `onCopy:` из `NodeRow(...)` |

`copyNodeJson` (server/detour/both логика) не тронут — переиспользован из View JSON.
analyze clean, 843 теста.

## Статус — DONE ✅ (device-verify на юзере)
