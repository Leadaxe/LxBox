# §226 — горизонтальный скролл табов в Add server wizard

> **СТАТУС: РЕАЛИЗАЦИЯ.** Чисто UI, одна строка. Ядро/storage не трогаем.

## Проблема

TabBar в Add server wizard (`add_server_wizard_screen.dart`) по умолчанию
растягивает вкладки на всю ширину экрана (`isScrollable: false`). Сейчас табов
четыре (SOCKS5 / HTTP / Paste URI / Paste JSON), и при добавлении новых
протоколов (§222 добавил HTTP — счёт растёт) подписи начнут сжиматься и
переноситься/обрезаться, а не помещаться.

## Решение

Сделать TabBar прокручиваемым:

- `isScrollable: true` — вкладки берут естественную ширину по подписи и
  скроллятся по горизонтали, когда не влезают.
- `tabAlignment: TabAlignment.start` — при прокручиваемом TabBar Material 3 по
  умолчанию добавляет отступ и «подвешивает» первую вкладку; `start` прижимает
  их к левому краю. Тот же приём, что уже применён к TabBar в App Settings
  (§158).

## Файлы

- `app/lib/screens/add_server_wizard_screen.dart` — `bottom: TabBar(...)` в
  `AppBar`: добавлены `isScrollable: true` + `tabAlignment: TabAlignment.start`.

## Связано

- Фича [074 add-server-wizard](../features/074%20add-server-wizard/spec.md).
- §222 (HTTP-таб — рост числа вкладок, из-за которого скролл и нужен).
- §158 (тот же `TabAlignment.start`-паттерн в App Settings).
