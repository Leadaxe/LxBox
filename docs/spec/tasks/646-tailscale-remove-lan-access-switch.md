# §646 — Tailscale Network: убрать переключатель Allow LAN access

| Поле | Значение |
|------|----------|
| Тип | B (UI вводит в заблуждение) |
| Статус | D (done); выпущено в v2.25.16 |
| Фича | [030-TAILSCALE](../features/030-TAILSCALE/FEATURE.md) |
| Дата | 2026-10-14 |
| Связанные | §613 (блок Settings), §437 (поле в форке не влияет на маршрутизацию) |

## Проблема

На вкладке **Network** узла Tailscale (`app/lib/widgets/tailscale_network_tab.dart`,
блок Settings, добавлен в §613) есть переключатель «Allow LAN access while using
exit node». Он пишет `exit_node_allow_lan_access` в тело узла, но на маршруты
это поле не влияет. Пользователь включает его и ждёт, что локальная сеть
станет доступной через выходной узел, а ничего не меняется.

## Диагностика

- В форке ядра `local.go:6552-6558` вырезает exit/LAN-маршруты; у tsnet на
  Android нет системного роутера. Это зафиксировано ещё в
  [§437](437-tailscale-bundle-import.md) (п. 4): поле в мастер не добавляли.
- В LxBox трафик раскладывают правила sing-box. Локальные адреса уходят direct
  пресетом «Private IPs» (позиция 950); то, что дошло до узла Tailscale, и
  должно идти в tailnet. Доступ к локальной сети при выходном узле от поля не
  зависит.

## Решение

Решение владельца (14.10.2026): переключатель убрать, спеку обновить.

- Из блока Settings убран переключатель `tailscale-exit-lan`; остаётся один —
  «Advertise this device as exit node», его поведение и блокировка при
  записанном `exit_node` не менялись.
- Удалены ставшие ненужными строки l10n `Allow LAN access while using exit node`
  и `Needs a saved exit node.` (ru, zh).
- Поле `exit_node_allow_lan_access` остаётся JSON-only: импорт, тело узла,
  эмит, реестр и проверка «requires exit_node» не тронуты — для совместимости с
  чужими конфигами. `app/contract` не менялся.
- Спека 030 (`FEATURE.md` / `FEATURE.ru.md`): таблица настроек и абзац о ключах
  конфига без второго переключателя; в Boundaries записано, что поле
  принимается из JSON, но ядром на Android не применяется, а локальную сеть
  ведёт пресет «Private IPs» или правило пользователя.
- USER_GUIDE переключатель не упоминал — без правок.

## Верификация

- `test/widgets/tailscale_network_tab_test.dart` — переключателя нет ни без
  выхода, ни с записанным выходом; advertise пишется и блокируется как раньше.
- `ui_check` и `hardcoded_check` — 0 failures / 0 warnings, orphan 0.
- `flutter analyze` — без замечаний.
