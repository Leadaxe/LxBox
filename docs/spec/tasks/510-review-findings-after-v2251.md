# §510 — Находки независимого ревью после v2.25.1

| | |
|---|---|
| **Статус** | В работе |
| **Дата** | 2026-09-24 |
| **Источник** | независимое ревью `develop` после v2.25.1: блоки «страховка 478 / сборка / Debug API» (H1, M2, M3, L1, L2) и «движок разбора» (M1, m1–m3) |
| **Связанные** | фича [478](../features/478%20core-rejected-node-auto-disable/spec.md), задачи [494](494-debug-api-debts.md), [503](503-core-reject-list-disabled-node-navigation.md), §208 (`/pool`), фича 480 (движок) |

## Docs to update

- эта задача — таблица находок
- [478](../features/478%20core-rejected-node-auto-disable/spec.md) — «Как
  сделано → Автомат» (H1), «Связка и контроллер» (M2)
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased → Fixed, строка на
  каждый видимый дефект

## Правило приёмки

Каждая починка — отдельный коммит с тестом, который КРАСНЫЙ на прод-файле до
правки и зелёный после (проверено откатом прод-файла). Идентичность и тела
существующих фикстур не меняются: стражи `before_480_identity_snapshot`,
`engine_emit_shape`, `golden_config` зелёные на каждом шаге.

## Находки

| Находка | Воспроизведена | Фикс / отказ |
|---|---|---|
| **H1** — защита от зацикливания страховки по строке тега: у тёзок `Dup`/`Dup-1` после выключения первого тег `Dup` переезжает ко второму, прогон обрывается, VPN не поднимается | да: реальный `buildConfig` отдаёт второму литеральный `Dup`; автомат — `failed` на первом круге | повтор судится по `CoreRejectNodeRef` из `disableNode` (`_seenRefs`), а не по тегу. Тест `core_reject_retag_test.dart` (хост поверх настоящей сборки): оба тёзки выключены за один прогон, VPN поднят |
| **M2** — Stop мимо кнопки фазы цикла (`POST /action/stop-vpn`, плитка QS, Intent API, Locale) не гасит идущий прогон: автомат доводит цикл до чистого `check` и финальным стартом поднимает туннель через секунды после Stop | да: Stop в фазе `checking` → `startedWithDisabled`, два реальных старта | `HomeController.stop()` зовёт `CoreRejectState.cancelRun()` (кнопка Stop, `/action/stop-vpn`); нативная воронка `BoxVpnService.stop` шлёт в Dart `vpn-stop-requested` (`VpnPlugin.notifyStopRequested` → `automation_dispatcher`) → тот же `cancelRun`. Кнопка Stop в шторке ходит в сервис напрямую (`ACTION_STOP`), но шторка живёт только в фазах реального старта, где Stop и так кончает прогон (`realStart` → unavailable → `failed`, без следующего старта). Тесты в `home_core_reject_test.dart`: оба пути, `realStarts == 1`, прогон не активен |
