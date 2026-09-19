# §500 — причина отбраковки одиночного ввода на экране Servers

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | явное поручение владельца: «Could not parse direct link» без объяснения при известной причине в `dropped[]` |
| **Связанные** | §484 (`field_missing` в `dropped[]`), §479 (`NodeNotificationsView`), §482 (тексты из реестра) |

## Проблема

На экране Servers (Subscriptions & proxy) вставка одиночной ссылки, JSON-узла
или `.conf` при отбраковке конвейером показывала только «Could not parse
direct link» (или соседние фразы для WG/JSON) — без объяснения. У подписок
причина доезжает в уведомления узла; у одиночного ввода узла нет, поэтому
причина должна быть видна сразу.

## Решение

- `addFromInput` при `null` от `parseUri` / `parseWireguardIni` / пустом
  `parseAll` читает `XrayDropVerdict` / `dropped[]` и кладёт в `lastError`
  [ParseInputRejectedMsg] со списком причин и меткой входа (`#fragment` или
  схема/тип).
- Под полем — прежняя красная фраза (без деталей); при известной причине
  сразу открывается нижняя шторка с [NodeNotificationsView] (§479), тап по
  строке открывает её снова. В шапке шторки — метка входа вместо тега узла.
  Несколько причин — все, по уровню error → warning → info. Без причины
  (ввод не распознан) — прежний [ErrMsg], шторки нет.
- Поле ввода при отказе не очищается.
- Debug API `POST /subs`: при отказе `addFromInput` в теле ошибки
  `dropped: [{code, path, value, title_en}]` (секреты в `value` — `***`).

## Критерии приёмки

- [x] Негодный CIDR в `wireguard://` — под полем «Could not parse direct
  link», шторка с `type_invalid` / `address`; метка `wg-bad-cidr`.
- [x] Ссылка без обязательного поля — `field_missing` в шторке.
- [x] Мусорная строка — «Input is not…» без шторки.
- [x] JSON / `.conf` — тот же путь (`noValidOutboundsInJson` /
  `invalidWireguardConfig`).
- [x] `POST /subs` при отказе — `dropped[]` в JSON ошибки.
- [x] Тесты контроллера и виджета; `flutter analyze` без новых issues.
