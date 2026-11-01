# 706 — Вкладка Network узла Tailscale вне сети: exit node не стирается, Replace key

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-02 |
| End date | 2026-11-02 |
| Commits | `fix(tailscale): вкладка Network вне сети — exit node не стирается, Replace key (§706)` |
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

## Unresolved / follow-up

- Вход с новым ключом без перезапуска VPN — ручка ядра запрошена у сессии
  ядра; после неё заменить тело `applyNewKey`.
