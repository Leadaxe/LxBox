# §613 — Пиры WireGuard/AWG, путь и health пиров Tailscale, advertise/LAN в UI

| Поле | Значение |
|------|----------|
| Тип | F (доработка), наблюдаемость от ядра lx.12 |
| Статус | P (в работе) |
| Фича | [030-TAILSCALE](../features/030-TAILSCALE/FEATURE.md), [006 OBSERVABILITY ядра] |
| Дата | 2026-10-08 |
| Связанные | §611 (ядро lx.12), §392 (три экрана узла), §557 (вкл/выкл endpoint), §579/§581/§608 (Tailscale Network) |

## Проблема

Ядро lx.12 отдаёт то, чего раньше не было:

- `CommandClient.GetWireGuardStatus(tag)` → `endpointState`, `idleSinceSeconds`,
  `peers[]` {`publicKey`, `endpoint`, `lastHandshakeUnix`, `rxBytes`, `txBytes`}.
  Руководство потребителя ядра: `SPECS/TASKS/114-WG_PEER_STATUS/CONSUMERS.md`
  в репо sing-box-lx (ветка `lx`) — читать через `gh api` или raw URL.
- У `TailscalePeer` — `path` (DIRECT / PEER_RELAY / DERP / NONE), `endpoint`,
  `peerRelay`, `derpRegionCode`, `lastHandshake`; у `TailscaleEndpointStatus` —
  `health[]`. Те же поля в потоке `SubscribeTailscaleStatus`. Руководство:
  `SPECS/TASKS/115-TAILSCALE_PEER_PATH_STATUS/CONSUMERS.md`.

У нас для WG показывается только `endpointState`/простой
(`outbound_view_screen.dart` ~532–590); у Tailscale путь виден лишь в ручном
Ping, health нет, в строке узла §608 путь сознательно не выводился «потому что
ядро не отдаёт» — основание снято.

## Решения (Fable, автономно, 08.10.2026)

**A. Пиры WG/AWG в окне узла.**
1. Сначала javap по `classes.jar` нового AAR (`app/android/app/libs/libbox.aar`
   после §611): точные имена `GetWireGuardStatus`, класса статуса, итератора
   пиров и геттеров. Kotlin пишется по javap, не по памяти.
2. Kotlin `BoxCommandClient` → метод по тегу → `VpnPlugin` → MethodChannel →
   Dart `cc_channel.dart`: `CcWireGuardStatus {endpointState, idleSinceSeconds,
   peers: [CcWireGuardPeer]}`. Ошибки ядра мапятся: `NotFound`,
   `InvalidArgument`, `FailedPrecondition`, `Unimplemented` — в Dart
   различимы.
3. Секция «Peers» на экране узла типа wireguard/awg, там же, где сейчас
   `endpointState` (`outbound_view_screen.dart`). Показывать только при
   работающем VPN и `endpointState ∈ {up, asleep, disabled}`; при пустом
   `peers` — строка по `endpointState` (таблица §3.6 руководства).
   Опрос раз в 2 с, пока экран виден; при уходе в фон/dispose — стоп.
   **Пробой (`urltest`/GET) ради статуса не будить** — только статус.
4. Строка пира: имя пира по таблице `publicKey → имя` из конфига узла, если
   у нас есть имена; иначе ключ сокращённо как в логе ядра (символы 0–3 и
   39–42 base64); `endpoint` (пусто → «—»); возраст хендшейка
   («42 s ago», `0` → «never»); ↓/↑ байты; вердикт по §2 руководства:
   `age ≤ 180 s` или rx растёт между опросами → «connected»; иначе «no active
   session (last handshake N min ago)»; `lastHandshakeUnix == 0` → «never
   connected». Порог 180 с заменяется верхней границей `reject_after_time`,
   если у AWG-узла оно задано (число или диапазон `min-max`). Счётчик, ставший
   меньше прежнего, — новая база, не отрицательная скорость.
5. Долгое нажатие/меню ⋯ на строке пира: копировать endpoint, ключ, всю строку.
6. `Unimplemented` → секцию не показывать (ядро без `with_lx_command`), без
   ошибок в UI.

**B. Tailscale: путь, health, подзаголовок.**
7. Kotlin `tailscalePeerMap` + Dart `CcTailscalePeer`: добавить `path`
   (строка), `endpoint`, `peerRelay`, `derpRegionCode`, `lastHandshake`;
   у статуса — `health` (список строк). Имена — по javap.
8. Вкладка Network (`tailscale_network_tab.dart`): устройство — две строки:
   сверху как сейчас (имя, online/last seen, пометки), снизу путь по
   таблице §2 руководства: `direct 1.2.3.4:41641`, `peer relay`,
   `relay fra` (регион), для `NONE` — пусто (строка не рисуется). Активность
   — по `active`, как раньше. `lastHandshake` — возрастом, `0` → не показывать.
9. Health: если `health` непуст — блок предупреждений вверху вкладки Network
   (оранжевый, по строке на запись). Пуст — блока нет.
10. Выход (exit node), выбранный в узле, в общем списке устройств не
    дублируется: он показан в блоке Exit node, из списка владельцев убирается.
11. Подзаголовок узла в списке серверов (`node_list.dart` ~633–645): к
    `via <exit>` дописать путь до exit-пира тем же форматом:
    `tailscale · via gl-mt2500 · direct 31.184.97.44:41641`. При `NONE` —
    как сейчас. Задачу §608 дополнить строкой: «путь выводится с §613 —
    ядро lx.12 отдаёт его в потоке». Pull-опрос `GetTailscaleStatus` не
    вводить: наш поток событийный и живой; Kotlin-обёртку для
    `GetTailscaleStatus` можно добавить, но без потребителя — не нужно.

**C. Advertise exit node и LAN access в UI.**
12. На вкладке Network блок **Settings** с двумя переключателями:
    «Advertise this device as exit node» (`advertise_exit_node`) и
    «Allow LAN access while using exit node» (`exit_node_allow_lan_access`,
    активен только при выбранном exit node). Запись — в тело узла тем же
    путём, что «Save choice» у exit node (config-significant, пересборка).
    Поля — по реестру `protocols/tailscale.json`; если реестр их не знает —
    доложить, не придумывать.
13. `FEATURE.md` фичи 030 (EN и `FEATURE.ru.md`): границу «нет полей
    advertise/LAN в мастере» переписать — переключатели на вкладке Network,
    `advertise_routes` по-прежнему только JSON.

## Ограничения

- `app/contract/**` не трогать. Версионный гейт по ядру не вводить: AAR едет
  в APK, `Unimplemented` обрабатывается молча.
- Память проекта: `CommandClient` — наносекунды в полях времени у части API,
  дельты, single-sink, no-throw; перед вызовом любого нового метода —
  javap. Тесты Kotlin не писать; Dart-разбор ответа покрыть тестом.

## Проверка

- `flutter analyze` всего проекта, новых issue 0; локально — только свои
  тест-файлы по одному.
- Эмулятор — отдельный прогон после волны (§611–§614): WG-узел с синтетическим
  пиром в TEST-NET показывает секцию Peers с «never connected» и растущим ↑.

## Нерешённое / хвосты

- Привязка соединения к пиру Tailscale (`Connection.tailscalePeerID`) — у ядра
  следующая спека, у нас не делать.
