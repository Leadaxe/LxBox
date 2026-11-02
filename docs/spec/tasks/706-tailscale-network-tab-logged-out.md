# 706 — Вкладка Network узла Tailscale вне сети: exit node не стирается, Replace key

| Field | Value |
|-------|-------|
| Status | Итерация 2: выключатель и Restart проверены на эмуляторе; Replace key ждёт исправления ядра |
| Start date | 2026-11-02 |
| End date | итерации 1 и 2 — 2026-11-02 |
| Commits | `fix(tailscale): вкладка Network вне сети — exit node не стирается, Replace key (§706)`; итерация 2: `b086e8ca`, `fd3a0e61` |
| Related specs | [030-TAILSCALE · networks-tab](../features/030-TAILSCALE/FUNCTIONS/networks-tab.ru.md), P21 |

## Problem

Скрины с телефона владельца (02.11.2026): узел Tailscale вне сети,
`backendState = NeedsLogin`, health «You are logged out. The last login error
was: invalid key: API key does not exist». В теле узла записаны `exit_node` и
`auth_key`.

1. В блоке Exit node красный текст «Not saved. The node stays in the lists,
   but has no exit until you save the choice.» и кнопка Save choice. Нажатие
   пишет в узел None и стирает сохранённый exit node.
2. Чип «signed in with a key» виден, хотя ключ отвергнут.
3. Исправить ключ с вкладки нельзя: Sign in только при `AuthURL` (при заданном
   ключе он пуст), Log out только в Running. Остаётся правка JSON.
4. This device → Name: `localhost`, имени ядро ещё не знает.

## Diagnosis

Код до правки — `app/lib/widgets/tailscale_network_tab.dart` на `b9ada1ae`:

- `_exitNodeBlock` (стр. 491–561) строится в любом состоянии и сверяет
  `recordedExitNode(body)` с `s.exitNode`. Вне сети `s.exitNode == null`,
  `exitNodeMismatch` даёт «записан, снят на ходу», и Save choice зовёт
  `_save(null)` → `exit_node` убирается из тела.
- `_statusBlock` (стр. 361–397): `trailing` берёт только `s.keyAuth`;
  кнопки — `needsLogin && authUrl` и `running`, третьей ветки нет.
- `_thisDeviceBlock` (стр. 435–451) показывает `self.hostName` как есть.

## Solution

`app/lib/widgets/tailscale_network_tab.dart`:

- В `build` блок Exit node с радио, знаком и Save choice — только при
  `backendState == 'Running'`; иначе `_savedExitNodeBlock`: «Saved: <значение>»
  и «Applies when the node is online.»; ничего не записано — блока нет.
- Чип «signed in with a key» — при `keyAuth && running`.
- Кнопка Replace key в Status: `NeedsLogin` и `onSaveFields != null` (тот же
  критерий, что у Save choice и Settings: оба экрана отдают колбэки вместе,
  у узла подписки их нет). Диалог `_ReplaceKeyDialog`: одно поле Auth key,
  скрытое, с Show/Hide, как в мастере Add server; Save неактивна при пустом
  или пробельном вводе. Save → `onSaveFields({'auth_key': key})` (путь Save
  choice) → при успехе `TailscaleNetworkActions.applyNewKey(tag)`.
- `applyNewKey` — одна точка «применить новый ключ»: сейчас
  `generateConfig` → `saveParsedConfig` → `HomeController.reloadVpn` через
  `DebugRegistry.I` (реестр долгоживущих контроллеров, им же пользуются
  automation и дамп; `NodeSettingsScreen` своего `HomeController` не имеет).
  Перезапуск безусловный, без галки авто-применения: пользователь сам
  попросил применить ключ. Когда ядро даст ручку входа с новым ключом,
  меняется только тело `applyNewKey`.
- Name вне Running: пустое или `localhost` → «—»; в Running как раньше.

`onSaveFields` возвращает `Future<bool>` (записано или нет), чтобы после
неудачной записи не перезапускать VPN: `node_settings_screen.dart`
(`_saveTailscaleFields` → результат `_saveSource`), `outbound_view_screen.dart`
(`_storeTailscaleFields` → `err == null`).

l10n: «Replace key», «Saved: %s», «Applies when the node is online.», «The VPN
restarts to sign in with the new key.» в `ru`/`zh`.

## Risks and edge cases

- Перезапуска нет в cooldown 3 с после прошлого reload, при не-connected
  туннеле и при неудачной сборке: `applyNewKey` возвращает `false`, ключ
  записан, вкладка показывает «Key saved. It applies when the VPN restarts.».
- Состояния кроме Running и NeedsLogin (`Starting`, `NeedsMachineAuth`,
  `Stopped`): записанный выход строкой, Replace key нет.
- Блок Settings (advertise) не трогали.

## Verification

- `flutter test test/widgets/tailscale_network_tab_test.dart` — 33 зелёных,
  новая группа «§706 — узел вне сети» (9 случаев: строка Saved без радио и
  Save choice, блока нет без записи, чипа нет и имя «—», Replace key у
  редактируемого и нет у подписки, пустой ключ, Save пишет `auth_key` и
  применяет, неудачная запись не применяет, Running как раньше).
- `flutter analyze` — без замечаний; `ui_check --strict`, `hardcoded_check
  --strict` — 0/0.
- На устройстве не проверено (DEVICE-PENDING).

## Итерация 2 — вход без перезапуска VPN, выключение и перезапуск узла

Ядро `v1.14.4-lx.30-rc.1` (SPEC 149, пин `1aad3339`):
`CommandClient.tailscaleLogin(tag, authKey)` и `setEndpointEnabled(tag,
enabled)` для Tailscale (WantRunning; выключенный узел отвергает дайлы сразу;
`endpointState` up/disabled/down в `GetOutbounds`; не переживает перезапуск
сервиса). Коды ошибок `tailscaleLogin`: `failed_precondition` (сервис или
узел не запущен, узел выключен, уже вошёл — «log out first»), `not_found`,
`invalid_argument`, `unavailable`; отказ ключа виден асинхронно в
`backendState`/health.

**Решение.**

1. Мост: `cc_channel.dart` `tailscaleLogin(tag, authKey)` →
   `VpnPlugin.kt` / `BoxCommandClient.kt` → `CommandClient.tailscaleLogin`;
   ошибки ядра — `PlatformException` с кодом как у `setEndpointEnabled`
   (gRPC-статус → `failed_precondition` / `not_found` / `invalid_argument` /
   `unavailable` / `error`).
2. `TailscaleNetworkActions.applyNewKey` — вместо сборки и `reloadVpn`:
   туннель не поднят → не звать ядро, вернуть «ключ применится при старте
   VPN»; иначе `tailscaleLogin(liveTag, key)`. Результат — тип с тремя
   исходами (вошёл в работу / отложено до старта VPN / отказ с кодом), не
   `bool`. Снеки: успех — «Signing in with the new key…»; отложено — «Key
   saved. It applies when the VPN starts.»; `failed_precondition` при
   выключенном узле — «Turn the node on first.»; прочее — «Could not sign in
   with the new key.». Ключ в тело узла пишется как в итерации 1 (до вызова
   ядра), чтобы пережить перезапуск. `DebugRegistry`-путь сборки и
   `reloadVpn` из `applyNewKey` убрать.
3. Вкладка Network, блок Status, пока туннель поднят и ядро отдало
   `endpointStates[liveTag]`:
   - переключатель «Node enabled» с подписью «Stays off until you turn it on
     or stop the VPN.» — тот же текст и поведение, что у WG/AWG на экране
     узла (`outbound_view_screen.dart` `_endpointBlock`), через
     `HomeController.setEndpointEnabled` (множество выключенных, переприменение
     после reload — уже там) и `toggleEndpoint`-снеки;
   - кнопка «Restart node» рядом с Sign in / Log out / Replace key, видна при
     узле не `disabled`: `setEndpointEnabled(false)` → `setEndpointEnabled(true)`,
     снек «Node restarted.» или текст отказа как у `toggleEndpoint`; на время
     вызова кнопка неактивна.
   Связь вкладки с `HomeController` — через `TailscaleNetworkActions` (как
   сейчас `applyNewKey`), чтобы тесты подменяли фейком.
4. `node_actions.dart` `toggleEndpoint`: текст `invalid_argument` — «Only
   WireGuard, AmneziaWG and Tailscale nodes can be turned off.» (старую строку
   из l10n убрать). Пункт Turn off / Turn on в списке узлов уже общий (по
   `endpointStates`) — Tailscale получает его без правок.
5. l10n `ru`/`zh` для новых строк; неиспользуемые убрать («The VPN restarts
   to sign in with the new key.», «Key saved. It applies when the VPN
   restarts.», если больше не нужны).

**Проверка.** Тесты `tailscale_network_tab_test.dart` (applyNewKey: три
исхода и снеки; переключатель и Restart node видны только при поднятом
туннеле и состоянии ядра; Restart зовёт off→on), тест моста при наличии
образца. Эмулятор: узел Tailscale с живым tailnet — Replace key из NeedsLogin
без перезапуска VPN, Turn off → трафик через узел отвергается, Turn on и
Restart node возвращают Running (SPEC 149 п.7 TASKS — первая живая проверка).

**Сделано** (`b086e8ca` код + l10n + тесты вкладки, `fd3a0e61` тест моста):

1. Мост: `CcChannel.tailscaleLogin(tag, authKey)` → `ccTailscaleLogin`
   (`VpnPlugin.kt`) → `BoxCommandClient.tailscaleLogin` → ядро; отказ —
   `PlatformException` с кодом из `endpointToggleErrorCode` (как у
   `setEndpointEnabled`). Ключ в лог не пишется.
2. `applyNewKey(tag, key)` → `TailscaleKeyApply` (`signingIn` / `deferred` /
   `failed(code)`); туннель не поднят (`HomeController.state.tunnelUp`) —
   ядро не зовётся. Путь через `DebugRegistry` к сборке и `reloadVpn` снят.
   Снеки по ТЗ; «Turn the node on first.» — при `failed_precondition` и
   состоянии узла `disabled`. Подсказка «The VPN restarts…» в диалоге снята.
3. `TailscaleNetworkActions`: `endpointChanges` (сам `HomeController`),
   `endpointState(tag)` (только при `tunnelUp`), `setEndpointEnabled` →
   `HomeController.setEndpointEnabled`. Блок Status под `ListenableBuilder`:
   переключатель Node enabled (ключ `tailscale-node-enabled`) при известном
   состоянии, Restart node (`tailscale-restart-node`) при состоянии не
   `disabled`; на время вызова оба неактивны; Restart — off→on, при отказе
   выключения включения нет.
4. `node_actions.dart`: тексты отказа вынесены в
   `endpointToggleErrorText(code, tag, enable:)` (общий для списка узлов и
   вкладки); `invalid_argument` — «Only WireGuard, AmneziaWG and Tailscale
   nodes can be turned off.».
5. l10n `ru`/`zh`: три ключа переименованы (старые «Only WireGuard and
   AmneziaWG…», «Key saved… VPN restarts.», «The VPN restarts to sign in…»
   ушли), четыре новых. `ui_check --strict`, `hardcoded_check --strict` —
   0/0.

**Проверено.** `flutter test test/widgets/tailscale_network_tab_test.dart` —
50 зелёных (applyNewKey: три исхода и снеки; новая группа «§706 —
выключатель и перезапуск узла», 7 случаев: нет состояния / VPN выключен —
ни выключателя, ни Restart; выключение гасит Restart; текст отказа;
Restart off→on с неактивной кнопкой; отказ выключения — без включения);
`test/vpn/cc_endpoint_toggle_test.dart` — 5 зелёных (проброс tag/ключа,
код отказа). `flutter analyze` по изменённым файлам — без замечаний.
Kotlin локально не собирался (CI).

**Эмулятор, 02.11.2026** (Android 14 arm64, ядро lx.30-rc.1, живой tailnet,
два узла Tailscale в одном конфиге):
- Node enabled выкл → `disabled`, backendState Stopped, Restart node скрыта;
  вкл → `up`, Running. Restart node → `false → disabled`, `true → up`
  (~20 мс), узел Running. Выключатель и Restart на обоих экранах
  (настройки узла, вид узла с главной).
- NeedsLogin после Log out: Sign in, Replace key, Restart node, имя «—».
- **Replace key НЕ входит:** ключ записан в узел верно (сверен побайтно),
  `tailscaleLogin` вернул успех, но узел остался в NeedsLogin с health «You
  are logged out. The last login error was: invalid key: API key does not
  exist», ядро ушло во вход по ссылке («Tailscale Authentication»). Тот же
  ключ после reload VPN — Running за ~6 с. Дефект ядра SPEC 149
  (`TailscaleLogin`: `Start` с ключом после явного Logout), передан сессии
  ядра; ждём rc.2.
- Мелочь: в Devices у узла в NeedsLogin пустая строка без имени («0 online /
  1»).
