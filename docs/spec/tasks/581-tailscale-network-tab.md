# 581 — Узел Tailscale: вкладка Network и проверка устройств

| Поле | Значение |
|------|----------|
| Статус | Implemented (проверка на устройстве: DEVICE-PENDING) |
| Дата старта | 2026-09-27 |
| Дата завершения | — |
| Коммиты | — |
| Контракт | Не затрагивается: форма конфига и реестр не меняются |
| Связанные spec'ы | [§579](579-networks-pseudo-direction.md) (мост состояния узла), [§578](578-tailscale-preset-template-for-each.md), [features/392](../features/392%20node-diagnostics/spec.md) (вкладка Diagnostics) |

## Проблема

Узел Tailscale в приложении это строка JSON. Пользователь не видит, вошёл ли
узел в сеть, какие в ней устройства, через что идёт выход. Сменить exit node
можно только правкой JSON. Проверка узла запросом к внешнему адресу у узла без
выхода всегда даёт отказ без пояснения.

## Решение владельца (27.09.2026)

Состав принят по списку ниже. Отвергнуто: трафик по каждому устройству,
перечень соединений через узел. Отложено: SSH на устройство, Taildrop,
сертификаты `*.ts.net`.

## Источник данных

API ядра апстримное, дельты нет. Приложение получает его через
`CommandClient`.

| Вызов | Для чего |
|---|---|
| `SubscribeTailscaleStatus` | состояние узла, свой узел, устройства сети; мост сделан в §579 и расширяется |
| `SetTailscaleExitNode(tag, stableID)` | выбор и снятие exit node на ходу |
| `TailscaleLogout(tag)` | выход из аккаунта |
| `StartTailscalePing(tag, peerIP)` | проверка устройства |

## Решение

### 1. Когда вкладка видна

Вкладка Network видна, когда выполнены оба условия:

1. тип узла `tailscale`;
2. открыт экран узла: `node_settings_screen` (свой сервер, член папки) или
   `node_inspect_screen` (узел подписки).

Место: перед вкладкой Diagnostics.

### 2. Что вкладка показывает без данных

| Условие | Что показывается |
|---|---|
| VPN выключен | строка «Start VPN to see the network.» |
| VPN включён, данных об узле от ядра ещё нет | индикатор ожидания |
| узел выключен или его нет в работающем конфиге | строка «The node is not in the running config.» |

### 3. Блок Status

| Элемент | Условие показа | Источник |
|---|---|---|
| состояние текстом | всегда | `BackendState`, значения как в §579 раздел 3 |
| имя сети | есть | `NetworkName` |
| отметка «signed in with a key» | `KeyAuth` истинно | `KeyAuth` |
| кнопка Sign in | состояние `NeedsLogin` и `AuthURL` не пуст | открывает `AuthURL` в браузере |
| кнопка Log out | состояние `Running` | `TailscaleLogout`, после подтверждения |

Текст подтверждения Log out называет следствие: узел выйдет из сети; если в
узле записан ключ входа, при следующем запуске узел войдёт снова.

### 4. Блок This device

Имя, MagicDNS-имя, адреса, срок ключа (`Self`: `HostName`, `DNSName`,
`TailscaleIPs`, `KeyExpiry`). Нажатие на имя или адрес копирует значение.

### 5. Блок Exit node

Список: устройства с `ExitNodeOption`, первым пунктом «None».

Два значения:

- записанное: `exit_node` в теле узла;
- действующее: `ExitNode` из состояния ядра.

| Действие или условие | Поведение |
|---|---|
| выбор пункта списка | `SetTailscaleExitNode`, выход переключается на ходу; тело узла не меняется |
| действующее и записанное совпадают | знака нет, кнопки записи нет |
| действующее и записанное различаются | знак предупреждения (треугольник с восклицательным знаком) у блока и кнопка Save choice |
| Save choice | действующее значение пишется в `exit_node` тела узла (пункт «None» убирает поле), конфиг пересобирается |

Текст у знака предупреждения зависит от случая:

| Случай | Текст |
|---|---|
| в узле выхода нет, на ходу выбран | «Not saved. Traffic is not routed through this node until you save the choice.» |
| в узле выход записан, на ходу снят | «Not saved. The node stays in the lists, but has no exit until you save the choice.» |
| в узле записан один, на ходу выбран другой | «Not saved. The choice is lost after restart.» |

После Save choice состав списков меняется сборкой: узел с `exit_node` входит в
списки выбора, узел без него уходит в NETWORKS (§579).

Запись значения в тело узла: у узла с источником `singbox_outbound` правится
поле в тексте источника; у остальных видов источника правка идёт тем же путём,
что правка полей узла на вкладке Settings.

Исполнитель проверяет по исходникам ядра и вносит в спеку:

1. что ядро делает при старте, когда в конфиге `exit_node` нет, а в каталоге
   состояния узла от прошлого запуска остался выбранный на ходу;
2. каким значением задаётся `exit_node` в конфиге: имя, адрес или `StableID`;
   в тело узла пишется то, что ядро принимает в конфиге.

Ответы (исходники `sing-box-lx` `protocol/tailscale/endpoint.go`, tailscale
`v1.102.1-sing-box-1.14-mod.5`, 27.09.2026):

1. **Выбор на ходу переживает перезапуск.** `SetTailscaleExitNode` пишет
   `ExitNodeID` в prefs tailscaled; prefs хранятся в каталоге состояния узла
   (`tsnet.Server.Dir`, файл состояния). При старте `editPrefs` выставляет
   только `ExitNodeIPSet` с пустым адресом, `ExitNodeIDSet` не трогает, поэтому
   сохранённый `ExitNodeID` остаётся, и узел снова выходит через выбранное на
   ходу устройство. Когда в конфиге `exit_node` задан, при переходе в `Running`
   `applyExitNode` ставит его адрес, и значение конфига побеждает. Исключение —
   `ephemeral: true`: состояние не переживает перезапуск, выбор теряется.
   Следствие для текстов: «The choice is lost after restart» точен для случая
   «записан один, выбран другой»; в случае «в узле нет, выбран на ходу» выход
   на деле сохраняется, но узел остаётся вне списков выбора до Save choice —
   текст первой строки это и говорит.
2. **`exit_node` — адрес или имя устройства, не `StableID`**
   (`Prefs.SetExitNodeIP` → `exitNodeIPOfArg`): адрес Tailscale, либо базовое
   имя, либо MagicDNS-имя с точкой в конце или без (без учёта регистра). Имя
   разрешается только при непустом списке устройств, при старте — ошибка
   `cannot resolve exit node by hostname while Tailscale is starting up`
   (ядро повторяет попытку на изменениях списка). Save choice пишет адрес
   Tailscale устройства (IPv4 первым), при его отсутствии — MagicDNS-имя.

### 6. Блок Devices

Устройства сети без своего узла.

| Элемент строки | Источник | Условие показа |
|---|---|---|
| имя | `HostName` | всегда |
| MagicDNS-имя, первый адрес | `DNSName`, `TailscaleIPs` | всегда |
| ОС | `OS` | не пусто |
| online | `Online` истинно | |
| last seen и время | `LastSeen` | `Online` ложно |
| отметка key expired | `Expired` | истинно |
| отметка shared | `ShareeNode` | истинно |
| отметка exit node | `ExitNodeOption` | истинно |

Порядок: сначала устройства в сети, затем остальные; внутри по имени.

Группировка по владельцам (`UserGroups`) показывается, когда владельцев больше
одного. Заголовок группы: `DisplayName`, при пустом `LoginName`. Картинка
профиля не загружается.

Нажатие на строку открывает меню: Copy name, Copy address, Ping.

### 7. Проверка устройства (Ping)

Вызов `StartTailscalePing`. Результат показывается в листе поверх вкладки:

| Поле | Источник |
|---|---|
| задержка | задержка ответа |
| путь: direct или relay | `IsDirect` |
| адрес при прямом пути | `Endpoint` |
| регион ретранслятора | `DERPRegionCode` |

Проверка идёт до закрытия листа или до пяти ответов.

### 8. Вкладка Diagnostics

| Условие | Поведение |
|---|---|
| узел Tailscale, действующего exit node нет | проверка запросом к внешнему адресу скрыта; вместо неё строка «This node has no exit. Check devices on the Network tab.» |
| узел Tailscale, действующий exit node есть | проверка доступна, как у обычного узла |

### 9. Что не попадает в журнал и выгрузки

Имена устройств, адреса, имя сети, имена владельцев и ссылка входа не пишутся
в журнал приложения, в дамп поддержки и в ответы Debug API. В Debug API
отдаётся только состояние узла и число устройств.

### 10. Порядок работы исполнителя

1. Опись: что из моста §579 готово, чего не хватает; названия методов
   биндинга по `classes.jar`. Опись вносится в спеку.
2. Расширение моста: полное состояние, три вызова.
3. Вкладка Network: блоки 3, 4, 6.
4. Блок Exit node и запись в тело узла.
5. Проверка устройства и правка вкладки Diagnostics.

## Опись (исполнитель, 27.09.2026)

- **Мост §579 готов:** отдельный `CommandClient` с подпиской
  `subscribeTailscaleStatus`, снапшот через `SnapshotEmitter` в EventChannel
  `lxbox/cc/tailscale`, `CcChannel.tailscaleStatus` (общий поток с кэшем),
  `HomeController._syncTailnetStatus` держит подписку при VPN включён и узле
  NETWORKS. Снапшот нёс только `tag`, `backend_state`, `state_text`.
- **Не хватало:** полного состояния (`AuthURL`, `NetworkName`,
  `MagicDNSSuffix`, `KeyAuth`, `Self`, `ExitNode`, `UserGroups` → `Peers`);
  удержания подписки несколькими потребителями (вкладка открыта у узла с
  `exit_node`, которого нет в NETWORKS); трёх вызовов.
- **Биндинг (`javap` по `classes.jar` `v1.14.2-lx.4`):**
  `CommandClient.subscribeTailscaleStatus(TailscaleStatusHandler)` →
  `TailscaleStatusSubscription.close()`; `setTailscaleExitNode(String, String)`;
  `tailscaleLogout(String)`; `startTailscalePing(String, String,
  TailscalePingHandler)` → `TailscalePingSession.close()`.
  `TailscaleEndpointStatus`: `getEndpointTag/getBackendState/getStateText/
  getAuthURL/getNetworkName/getMagicDNSSuffix/getSelf/getExitNode/getKeyAuth`,
  итератор `userGroups()`. `TailscaleUserGroup`: `getUserID/getLoginName/
  getDisplayName/getProfilePicURL`, итератор `peers()`. `TailscalePeer`:
  `getStableID/getHostName/getDNSName/getOS/getOnline/getExitNode/
  getExitNodeOption/getShareeNode/getExpired/getActive/getKeyExpiry/
  getLastSeen/getRxBytes/getTxBytes`, итераторы `tailscaleIPs()`,
  `sshHostKeys()`. `TailscalePingResult`: `getLatencyMs` (double, мс),
  `getIsDirect/getEndpoint/getPeerRelay/getDERPRegionID/getDERPRegionCode/
  getError`. Времена `KeyExpiry`/`LastSeen` — Unix-секунды (`Time.Unix()` в
  `protocol/tailscale/status.go`), 0 — нет значения. Свой узел в `UserGroups`
  не входит.

## Реализация

- **Мост (Kotlin):** `BoxCommandClient` — снапшот расширен до полного
  состояния (`tailscalePeerMap`), `setTailscaleExitNode` / `tailscaleLogout`
  (через `ensurePingClient`, ответ `null` или текст ошибки ядра),
  `startTailscalePing` / `stopTailscalePing` на своём клиенте, ответы — в новый
  EventChannel `lxbox/cc/tailscale_ping` (`ccTailscalePingSink`);
  `shutdownAll` закрывает и проверку. `VpnPlugin`: методы
  `ccSetTailscaleExitNode`, `ccTailscaleLogout` (на `Dispatchers.IO`),
  `ccStartTailscalePing`, `ccStopTailscalePing`. Имена и адреса в лог не
  пишутся.
- **Мост (Dart):** `CcTailscaleStatus` с полным состоянием, `CcTailscalePeer`,
  `CcTailscaleUserGroup`, `CcTailscalePingResult` в `cc_channel.dart`;
  подписка ядра по счётчику (`acquireTailscaleStatus` /
  `releaseTailscaleStatus` / `restartTailscaleStatus`), главный экран и
  вкладки держат её вместе. `HomeController` перерисовывает главный экран
  только при смене состояния узла или числа устройств.
- **Логика:** `app/lib/services/tailscale_network.dart` — строка таблицы
  раздела 5 (`exitNodeMismatch`, сравнение по адресу и именам как у ядра),
  тексты, значение для записи (`exitNodeConfigValue`), правка тела
  (`withExitNode`), порядок устройств, признак выхода для Diagnostics
  (`tailscaleHasExit`), сводка для Debug API.
- **Вкладка:** `app/lib/widgets/tailscale_network_tab.dart` —
  `TailscaleNetworkTab` (Status, This device, Exit node, Devices; список
  ленивый, перерисовка не чаще раза в секунду) и `TailscalePingSheet` (до
  пяти ответов или закрытия). Подключена в `node_settings_screen` (Save choice
  → `withExitNode` над источником и путь Save вкладки Source: тег, проверка
  ядром, запись) и `node_inspect_screen` (без Save choice); Network стоит
  перед Diagnostics, индекс Diagnostics сдвигается.
- **Diagnostics:** `NodeDiagnosticsTab` у `TailscaleSpec` слушает состояние
  узла; без действующего выхода секция Check скрыта, вместо неё строка
  раздела 8. VPN выключен или данных нет — решает записанный `exit_node`.
- **Debug API:** `GET /state` → `tailscale: {тег: {backend_state, devices}}`.
- **Тесты:** `app/test/services/tailscale_network_test.dart` (разбор сообщения,
  четыре строки и три текста раздела 5, запись поля, порядок, Diagnostics по
  данным, Debug API без имён и адресов), `app/test/widgets/
  tailscale_network_tab_test.dart` (состояния без данных, знак и Save choice,
  узел подписки, выбор на ходу без записи, отметки и порядок устройств, оба
  условия раздела 8 на виджете).
- **DEVICE-PENDING:** эмулятор с настоящей сетью: состояние, список
  устройств, смена exit node на ходу, Save choice и пересборка, проверка
  устройства, Log out.

## Риски и edge cases

- **Сеть из сотен устройств.** Список строится лениво; поток состояния не
  перерисовывает вкладку чаще раза в секунду.
- **Узел подписки.** Save choice правит тело узла подписки; при обновлении
  подписки правка теряется. Кнопка Save choice у узла подписки скрыта, выбор
  на ходу доступен.
- **Два узла в одной сети.** Каждая вкладка показывает данные своего узла, по
  тегу.
- **Log out у узла с ключом входа.** Узел войдёт снова при следующем запуске.
  Текст подтверждения это называет.
- **Правила биндинга.** Один приёмник потока, исключения наружу не выходят,
  времена в наносекундах.

## Верификация

Тесты (гонять только затронутые файлы):

- разбор состояния из сообщения канала: узел, свой узел, устройства, группы;
- блок Exit node: четыре строки таблицы поведения и три текста;
- Save choice: поле появляется, меняется, убирается в теле узла;
- порядок и отметки в списке устройств;
- вкладка Diagnostics: оба условия раздела 8;
- раздел 9: в ответе Debug API нет имён и адресов.

Критерии приёмки:

1. Конфиг меняется только после Save choice, и только полем `exit_node`.
2. Проверка на эмуляторе с настоящей сетью: состояние, список устройств,
   смена exit node на ходу, запись выбора, проверка устройства.

## Docs to update

| Файл | Что |
|---|---|
| `docs/PROTOCOLS.md` §9.7 | вкладка Network, exit node |
| `docs/KERNEL.md` | используемые вызовы `CommandClient` |
| `docs/api/debug-api-reference.md` | состояние узла Tailscale |
| `CHANGELOG.md` | запись в Unreleased |

## Нерешённое / follow-up

- SSH на устройство, Taildrop, сертификаты `*.ts.net`.
- Лаунчер: та же вкладка через gRPC демона `lxd`. Решение владельца
  27.09.2026: делать. Состав и поведение те же (разделы 3–9); спека лаунчера
  ссылается на эту.
