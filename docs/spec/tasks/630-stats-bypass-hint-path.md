# §630 — Подсказка в Statistics вела к Allow VPN bypass не на ту вкладку

| Поле | Значение |
|------|----------|
| Тип | Дефект |
| Статус | D (done), выпущено в v2.25.13 |
| Дата | 2026-10-12 |
| Связанные | §069 (предупреждение о bypass в текущей сессии), §188 (Tunnel options на вкладке Mode) |

## Проблема

`app/lib/screens/stats_screen.dart:219-226` — подсказка у значка-предупреждения
в шапке Statistics (виден, когда bypass включён в текущей VPN-сессии) отправляла
пользователя в «VPN Settings → System → Allow VPN bypass». На вкладке System
такого тумблера нет: пользователь не находит, где выключить bypass.

Второй недостаток — текст не по `docs/EDITORIAL_POLICY.ru.md` 8.3: расплывчатое
«Some traffic may not go through VPN» вместо факта и канцелярское «to enforce
strict tunnel».

## Диагностика

- Тумблер **Allow VPN bypass** — `app/lib/screens/vpn_mode_tab.dart:378-409`:
  вкладка Mode, группа Tunnel options; группа видна только в режимах с TUN
  (`_cfg.hasTun`). Название вкладки — `settings_screen.dart:364` (`"Mode"`).
- Путь с «System» остался с §069, до переноса тумблеров на вкладку Mode в §188.
- Строка подсказки — сырой литерал в `Tooltip.message`, не через
  `getLocalText.s(...)`: ключей в словарях ru/zh нет, перевод не затрагивается.
- `grep` по `app/lib` на «System → … bypass» — других вхождений нет.

## Решение

Новый текст подсказки (`stats_screen.dart`), факт → действие:

> VPN bypass is on in this session: apps that call bindProcessToNetwork()
> (banking apps, WhatsApp, system services) send their traffic outside the tunnel.
>
> To keep all traffic in the tunnel, turn off VPN Settings → Mode → Tunnel
> options → Allow VPN bypass and reload the VPN.

## Риски и граничные случаи

- Значок появляется только при активной сессии с bypass, то есть в режиме с TUN —
  группа Tunnel options в этот момент видна, путь достижим.
- Перевод строки на ru/zh вне задачи (строка и раньше была не локализована).

## Проверка

- `dart run tool/l10n/hardcoded_check.dart` — failures: 0, warnings: 0.
- Ручная: включить Allow VPN bypass, переподключить VPN, открыть Statistics,
  тапнуть значок — путь в подсказке ведёт к тумблеру.
