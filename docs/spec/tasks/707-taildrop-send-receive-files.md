# 707 — Taildrop: отправка и приём файлов (итерация 1)

| Field | Value |
|-------|-------|
| Status | Done (итерация 1; на устройстве не проверено) |
| Start date | 2026-11-02 |
| End date | 2026-11-02 |
| Commits | `1d30e211` `feat(taildrop): отправка и приём файлов — «Поделиться», Send file…, входящие узла (§707)` |
| Related specs | [032-TAILDROP](../features/032-TAILDROP/FEATURE.ru.md): [send-files](../features/032-TAILDROP/FUNCTIONS/send-files.ru.md), [inbox](../features/032-TAILDROP/FUNCTIONS/inbox.ru.md), [share-text](../features/032-TAILDROP/FUNCTIONS/share-text.ru.md) |

## Problem

Владелец 02.11.2026: «сделай возможность передать/получить файл». Ядро в пине
lx.29 уже несёт Taildrop и молча принимает файлы в общую папку `Taildrop`
рабочего каталога ядра; в приложении их не видно, отправить нечем.

## Diagnosis

API ядра в `app/android/app/libs/libbox.aar` (javap, `CommandClient`):

- `subscribeTaildropInbox(tag, TaildropInboxHandler)` → `TaildropInbox`
  (`files()`: name, size, senderName, modifiedAt; `receiving()`: name, size,
  receivedBytes, senderID, senderName);
- `sendTaildropFiles(TaildropSendOptions, TaildropSendHandler)` →
  `TaildropSendSession` (`writeChunk(bytes)`, `finishFile()`); опции:
  `endpointTag`, `peerStableID`, `addFile(name, size)` (size < 0 — неизвестен);
  порция — `Libbox.TaildropChunkSize`; хендлер `onProgress(fileIndex, sent)`,
  `onFileCompleted`, `onFinish(errorMessage)`;
- `downloadTaildropFile(tag, name, destinationPath, handler)`,
  `deleteTaildropFile(tag, name)`, `cancelTaildropReceiving(tag, senderID,
  name)`, `markTaildropInboxRead(tag)`;
- статус узла: `canShareFiles`, `waitingFileCount`, `receivingFileCount`,
  `unreadFileCount`; пир: `canReceiveFiles`, `shareeNode`, `online`.

Ядро само шлёт уведомления приёма через `PlatformInterface.sendNotification`
(`identifier = "taildrop/<tag>/<name>"`, `openURL =
"sing-box:taildrop?endpoint=<tag>"`); в `BoxService.sendNotification` они
сейчас становятся обычным уведомлением ядра.

Каталог приёма: опция endpoint'а `taildrop_directory`, дефолт `Taildrop`
относительно рабочего каталога ядра (`protocol/tailscale/endpoint.go:190`).
`state_directory` узлам Tailscale подставляет `build_config.dart` (§435/§445,
стр. ~681–707); каталог состояния удаляется вместе с узлом (§445).

Мост к CommandClient — `BoxCommandClient.kt` / `VpnPlugin.kt` /
`lib/vpn/cc_channel.dart` (как `startTailscalePing`, `setTailscaleExitNode`).

## Solution

**A. Каталог входящих на узел.** В `build_config.dart` рядом с подстановкой
`state_directory`: если в теле нет `taildrop_directory`, ставить
`<state_directory>/taildrop`. Хранимое тело не трогать (как `state_directory`).
Разовый перенос: файлы из старой общей папки ядра (`<рабочий каталог
ядра>/Taildrop`, без `.partial`) перенести в `taildrop` первого по порядку
конфига узла Tailscale, общую папку удалить; один раз, без флага —
признак = существование старой папки.

**B. Отправка.**
- Цель «Поделиться»: intent-filter `ACTION_SEND` / `ACTION_SEND_MULTIPLE`
  (`*/*`) на отдельной активности (не на MainActivity с `singleTask`, чтобы
  не ломать её запуск). Текст (`text/plain` с `EXTRA_TEXT` без `EXTRA_STREAM`)
  — заметка `note-YYYY-MM-DD-HHMM.txt` (share-text, P8).
- Экран отправки: VPN выключен или нет работающего узла Tailscale → причина
  и кнопка закрыть, без очереди (P7). Узлов несколько → выбор узла. Список
  пиров: `online && canReceiveFiles && !shareeNode` (ядро уже учло право
  отправки). У узла `canShareFiles == false` → «File sharing is off for this
  tailnet. Turn on Taildrop in the Tailscale admin console.» вместо списка.
- Строка пира на вкладке Network: пункт «Send file…» (только у пира,
  прошедшего тот же фильтр) → системный выбор файлов (`OPEN_MULTIPLE_DOCUMENTS`
  / `GET_CONTENT` с `ALLOW_MULTIPLE`) → та же отправка.
- Сама отправка — в Kotlin, в scope сервиса VPN (переживает закрытие
  активности): `content://` читается `ContentResolver.openInputStream`
  порциями `TaildropChunkSize`, имя — `OpenableColumns.DISPLAY_NAME`, размер —
  `SIZE` или −1. Уведомление прогресса «Sending to <peer>» с процентом,
  итог «Sent to <peer>» / «Couldn't send to <peer>: <причина>»; Cancel в
  уведомлении отправки — закрыть сессию.

**C. Входящие.**
- На вкладке Network узла блок «Inbox» под Devices: подписка
  `subscribeTaildropInbox(tag)` пока вкладка открыта; принимаемые — строка с
  прогрессом и Cancel (`cancelTaildropReceiving`); принятые — имя, размер,
  отправитель, Save и Delete. Открыли блок — `markTaildropInboxRead`.
  Пусто — блок не показывать; `canShareFiles == false` — строка причины.
- Save: API 29+ — `downloadTaildropFile` во временный файл кэша, затем
  `MediaStore.Downloads` (без разрешений), временный файл удалить, файл из
  входящих удалить (`deleteTaildropFile`); API 24–28 — системный «Сохранить
  как» (`ACTION_CREATE_DOCUMENT`), запись туда, затем то же удаление.
  Снек «Saved to Downloads» / «Saved».
- Delete — `deleteTaildropFile`.
- Тап по уведомлению ядра с `openURL` `sing-box:taildrop?endpoint=<tag>` →
  приложение открывает вкладку Network узла с этим тегом.

l10n: все новые строки — `ru`/`zh` (`app/assets/l10n/...`), правила
`docs/l10n.md`. Имена файлов, содержимое и имена устройств не пишутся в
AppLog, дамп и Debug API (правило 030).

## Out of scope (итерация 2 и дальше)

- Кнопки Cancel / Save / Delete в уведомлениях приёма ядра.
- Синхронизация буфера и плитка (clipboard-sync).
- Маршруты Debug API для Taildrop.

## Risks and edge cases

- Узел без `state_directory` (корень не известен) — `taildrop_directory` не
  подставляется, ядро пишет в общий дефолт; перенос не делается.
- Два узла Tailscale — входящие и уведомления по тегу узла; тап открывает
  нужный узел.
- Отправка, когда VPN гаснет посреди передачи, — `onFinish` с ошибкой →
  уведомление «Couldn't send».
- Чужой/расшаренный пир, оффлайн пир — в списках не появляются.

## Verification

- Тесты: подстановка `taildrop_directory` в сборке (есть / нет корня, явный
  ключ в теле не трогается), фильтр пиров, блок Inbox (widget, на фейке
  действий), имя заметки. Только затронутые файлы, полный прогон — CI.
- Эмулятор: отправка из «Поделиться» на устройство tailnet и приём с него —
  если есть живой tailnet; иначе DEVICE-PENDING.

### Result (2026-11-02)

Сделано: A (подстановка `taildrop_directory`, перенос старой папки на старте
VPN — `Taildrop.migrateLegacyInbox` до `startOrReloadService`), B
(`TaildropShareActivity` — цепочка системных диалогов узел → устройство,
заметка из текста; «Send file…» в меню устройства; передача в нативе
`Taildrop.send`, уведомление с процентом и Cancel), C (блок Inbox под
Devices, Save/Delete/Cancel приёма, `markTaildropInboxRead`, тап по
уведомлению ядра → вкладка Network узла).

Решения исполнителя (в ТЗ не было):
- Экран «Поделиться» — системные диалоги без Flutter (второй движок на
  отдельной активности обнулял бы статические sink'и плагина основного).
- Уведомления приёма ядра: свой канал `lxbox-taildrop` и своё id на файл
  (ядро шлёт все с одним `typeID`, снятие «receiving» снимало бы и
  «received»); тело с именами в журнал не пишется.
- Потоки `content://` открываются до закрытия активности «Поделиться»
  (право на URI живёт, пока жива активность).
- Нет поля `can_share_files` в записи — право не отрицается; строка
  причины в Inbox только у узла в Running.

Проверено:
- `flutter test test/builder/node_sections_build_test.dart` — подстановка
  (есть/нет корня, свой `state_directory`, явный `taildrop_directory`);
- `test/widgets/tailscale_network_tab_test.dart` — фильтр пиров, разбор
  канала, блок Inbox (подписка, чужой тег, Save/Delete, Cancel приёма,
  причина), «Send file…» только у цели;
- эталоны `golden_config_test` / `golden_backup_test` (обновлён
  `rich_v0.config.json`), тесты миксинов на этом эталоне;
- `flutter analyze` по изменённым файлам, `hardcoded_check`, `ui_check`,
  `kotlin_check` — 0/0; компиляция Kotlin (`compileDebugKotlin`).

Не проверено: имя заметки (только Kotlin, своего тестового стенда у
Kotlin нет); эмулятор и живой tailnet — DEVICE-PENDING (отправка из
«Поделиться», приём, Save в Downloads, Save as на API 24–28, перенос старой
папки, тап по уведомлению).
