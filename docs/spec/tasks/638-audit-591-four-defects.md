# §638 — Четыре дефекта из аудита 591: Quit воскрешает VPN, диалог удаления цепочки, адрес в VPN_ERROR, устаревший SNI MASQUE

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | D (done), выпущено в v2.25.14 |
| Фичи | [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md), [006-DETOUR_AND_BALANCE](../features/006-DETOUR_AND_BALANCE/FEATURE.md) / [026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md), [014-AUTOMATION](../features/014-AUTOMATION/FEATURE.md), [015-WARP](../features/015-WARP/FEATURE.md) |
| Дата | 2026-10-13 |
| Связанные | §591 (аудит, источник находок), §428 (сторож VPN), §404, §014, §393 (SNI MASQUE на RU-каналах) |

Принцип: «не ломай то, что работает» — правки точечные, вокруг ничего не
рефакторится.

## 1. «Quit & reopen app» воскрешает VPN

**Проблема.** `VpnPlugin.quitApp` убивает процесс, но не снимает признак
«VPN желателен» (`BootReceiver.setVpnDesired`) и будильник сторожа §428.
Через 2–3,5 мин `VpnWatchdogReceiver` видит мёртвый сервис при
`desired=true` и сам поднимает VPN, хотя диалог обещает «VPN service will
stop». Комментарий в `quitApp` («Android сам его остановит») описывал только
половину картины.

**Решение.** В `quitApp` до `finishAffinity` —
`BootReceiver.setVpnDesired(context, false)` и `VpnWatchdog.disarm(context)`;
комментарий переписан. `setVpnDesired` пишет через `apply()`: запись в
памяти мгновенная, на диск — до `onStop` activity (Android дожидается
`QueuedWork`), а `finishAffinity` идёт раньше убийства процесса.

## 2. Диалог удаления цепочки врёт

**Проблема.** `chain_edit_screen.dart` `_delete`: текст «Other chains using it
as a position will stop building until you fix them». Фактически
`_deleteChain` (`settings_storage/chains.dart`) снимает позицию из других
цепочек (P10 фичи 006): цепочки из 3+ хопов собираются укороченными.

**Решение.** Текст `Remove "%s"? Chains using this node will be rebuilt
without it.` (+ ru/zh в `assets/l10n/*/ui.json`). Поведение кода не менялось.

## 3. `VPN_ERROR(tunnel_error)` раскрывает адрес сервера

**Проблема.** `home_controller.dart` передаёт сырой `errorReason` ядра
(`dial tcp <ip>:<port>: …`) в `emitVpnError('tunnel_error', …)`, событие
уходит broadcast'ом любому подписчику. Решение владельца в §591 (2026-10-13,
вопрос 52 → A): маскировать адреса/хосты.

**Решение.** В `url_mask.dart` добавлена `maskNetworkAddresses` (IPv4, IPv6
в скобках и без, доменные имена → `***`; порт и остальной текст остаются);
готового маскировщика адресов в произвольном тексте в коде не было —
`maskSubscriptionUrl` работает только с URL целиком. `emitVpnError`
прогоняет `message` через неё только при `code == 'tunnel_error'`: тексты
провала команд (`conflict`, `switch_failed`, …) несут теги узлов, их не
трогаем. Обещание P14 в 014.

## 4. Рекомендованный SNI MASQUE устарел

**Проблема.** `assets/warp_endpoints.json` `masque.recommended_sni =
consumer-masque.cloudflareclient.com`; §393 зафиксировал, что с ним h3 не
встаёт на RU-каналах, дефолт ядра — `www.cloudflare.com` (`node_spec.dart`).

**Решение.** `recommended_sni` = `www.cloudflare.com`; родной домен остаётся
в `sni_pool` для перебора. Комментарии в `warp_wizard_screen.dart` и
`scan/scan_pool.dart` обновлены. Тестов, фиксирующих значение из ассета, нет
(тесты пула используют свои фикстуры).

## Проверка

- `test/services/automation/event_emitter_test.dart` — новый тест
  «VPN_ERROR(tunnel_error) hides server address (014 P, §638)»: IPv4, IPv6 и
  хост в тексте ошибки не доходят до `message`.
- Пункты 1, 2, 4 — без юнитов (Kotlin-путь убийства процесса, строка UI,
  значение в ассете). Ручная приёмка п. 1: подключить VPN → Quit & reopen
  app → через 4 мин VPN не поднялся сам.

## Документация

- 010 `FUNCTIONS/autostart-and-exit(.ru).md` — правило и ревизия 4.
- 006 `FUNCTIONS/chain-editor(.ru).md` — строка «Удаление» и ревизия 4.
- 014 `FEATURE(.ru).md` — P14; `FUNCTIONS/outbound-events(.ru).md` — правило
  про `message`, обещания, ревизия 8.
- 015 `FUNCTIONS/endpoint-pool(.ru).md` — `recommended_sni`, ревизия 9.
