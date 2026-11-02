# 707 — Taildrop: отправка и приём файлов (итерация 1)

| Field | Value |
|-------|-------|
| Status | Done (итерации 1–5; эмулятор 02.11.2026); итерация 6 (отправка с телефона: плитка, ссылка) — не начата |
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

**Эмулятор, 02.11.2026** (Android 14 arm64, ядро lx.30-rc.1, живой tailnet,
два узла Tailscale `ts-a`/`ts-b` в одном конфиге — два устройства одного
владельца):
- `taildrop_directory = <state_directory>/taildrop` у обоих узлов в
  собранном конфиге.
- «Поделиться» текстом: диалог узла (работают два) → список устройств — только
  свои в сети (nanopi вне сети отсутствует) → «Sent to lxbox-emu-b»;
  получатель — уведомление «note-…txt received from lxbox-emu-a».
- Тап по уведомлению приёма (развёрнутая группа) → вкладка Network узла ts-b;
  Inbox: имя, 21 B, отправитель; Save → `/sdcard/Download`, содержимое
  совпало, файл ушёл из входящих. Delete — удалён, в Downloads нет.
- «Send file…» из строки устройства → системный выбор → 8 МБ за <1,5 с,
  Save, sha256 совпал с оригиналом. Обратное направление (ts-b → ts-a) тоже.
- Не проверено: Save as на API 24–28, перенос старой общей папки, Cancel
  отправки/приёма (передачи слишком быстрые), отправка на чужую ОС.
- Наблюдения: тап по строке в свёрнутой группе уведомлений L×Box открывает
  приложение без перехода (поведение Android); уведомления «Sent to X»
  копятся по одному на отправку.

## Итерация 2 — автосохранение в Downloads и кнопки в уведомлениях приёма

Владелец 02.11.2026: «да делать и в той же спеке, новые не плодить» — на
предложение переключателя автосохранения; кнопки уведомлений — пункт «Out of
scope» итерации 1.

### Diagnosis

Уведомления приёма шлёт ядро (`protocol/tailscale/taildrop.go`,
`sendNotification`, `cancelNotification`), `identifier`:

- идёт приём: `taildrop/<tag>/receiving/<senderID>/<baseName>`; ядро снимает
  его само по окончании приёма (`defer cancelNotification`);
- принят: `taildrop/<tag>/<finalName>`; `finalName` — имя во входящих (ядро
  может переименовать при совпадении).

Тег узла надёжнее брать из `openURL` (`Taildrop.tagFromOpenUrl`), остаток
`identifier` после `taildrop/<tag>/` — имя. Сейчас оба уведомления рисует
`BoxService.sendTaildropNotification` (свой канал `lxbox-taildrop`, id по
`identifier`), кнопок нет. Сохранение уже есть в нативе: `Taildrop.save(ctx,
tag, name, target)` (API 29+ → `MediaStore.Downloads`, затем файл из входящих
удаляется).

Ядро сообщает о принятом файле только этим уведомлением; Flutter может быть
не запущен. Значит автосохранение и кнопки живут в нативе, в сервисе VPN.

### Solution

**A. Переключатель «Save received files to Downloads».**
- Где: вкладка Network узла Tailscale, блок Settings (рядом с «Advertise this
  device as exit node»). Блок показывается и там, где сейчас его нет
  (`onSaveFields == null`), если есть этот переключатель; переключатель — свой
  у каждого узла.
- Хранится на устройстве по узлу, НЕ в теле узла и НЕ в бэкапе (как цель
  буфера и «Accept clipboard from», решение владельца 02.11). Нативный сервис
  читает его без Flutter. Ключ — тег узла; переименованный узел
  переключатель теряет (по умолчанию выкл.). Удаление узла убирает запись.
- По умолчанию выключен.
- На API < 29 переключатель неактивен, подпись «Needs Android 10 or later.»
- Включён и пришло уведомление «принят» → в сервисе `Taildrop.save(ctx, tag,
  name, null)` в фоне. Успех: уведомление этого файла заменяется на «Saved to
  Downloads: <name>», тап открывает файл (`ACTION_VIEW` на uri из MediaStore,
  MIME по имени; нет обработчика — открыть вкладку узла). Ошибка: обычное
  уведомление «принят» с кнопками (п. B) и текстом причины; файл остаётся во
  входящих.
- Файлы, уже лежащие во входящих на момент включения, не трогаются.

**B. Кнопки в уведомлениях приёма** (переключатель выключен, или
автосохранение не удалось):
- «идёт приём» — Cancel → `cancelTaildropReceiving(tag, senderID, baseName)`;
- «принят» — Save и Delete. Save — `Taildrop.save` (API 29+); на API < 29 Save
  в уведомлении нет (нужен «Сохранить как» из активности), только Delete и тап.
  Delete — `deleteTaildropFile(tag, name)`. После Save/Delete уведомление
  снимается; после Save — показать «Saved to Downloads: <name>» с тем же
  открытием файла, что в A.
- Кнопки — `PendingIntent` на неэкспортируемый receiver (по образцу
  `TaildropCancelReceiver`), работа — не на главном потоке.
- Сервис не запущен (VPN выключили, уведомление осталось) → кнопка не падает:
  Save/Delete/Cancel недоступны без ядра, уведомление снимается, тап по нему
  открывает вкладку узла.

**C. Тексты.** Новые строки — `en`/`ru`/`zh` по `docs/l10n.md` (нативные — в
`values*/strings.xml`). Имена файлов и устройств — только в уведомлениях, не
в AppLog, logcat, дампе и Debug API (правило 030).

### Out of scope

- Синхронизация буфера (clipboard-sync), плитка.
- Автосохранение на API 24–28.
- Своя папка внутри Downloads, выбор места сохранения.
- Маршруты Debug API для Taildrop.

### Verification

- Тесты на затронутые файлы: переключатель в блоке Settings (виден без
  `onSaveFields`, неактивен на API < 29 — через фейк), запись/чтение
  настройки, разбор `identifier` (обе формы, тег с `/` невозможен — тег из
  `openURL`). Полный прогон — CI.
- Эмулятор (живой tailnet, узлы `ts-a`/`ts-b`): включить на `ts-b`, отправить
  с `ts-a` → файл в `/sdcard/Download`, sha256 совпал, во входящих пусто,
  уведомление «Saved to Downloads», тап открывает файл; выключить → кнопки
  Save/Delete в уведомлении работают; Cancel приёма — большим файлом
  (≥ 500 МБ).

### Result (итерация 2)

Сделано:
- **A.** Переключатель «Save received files to Downloads» в блоке Settings
  вкладки Network; блок показывается и без `onSaveFields` (узел подписки),
  если натив отдал настройку. Хранение — отдельный файл SharedPreferences
  `lxbox_taildrop`, ключ `autosave.<тег>`, хранится только `true`
  (`Taildrop.isAutoSave/setAutoSave/forgetAutoSave`, методы канала
  `taildropAutoSaveState` / `taildropSetAutoSave` / `taildropForgetAutoSave`).
  Принятый файл узла с включённым переключателем — `Taildrop.save` в фоне,
  успех — «Saved to Downloads: <имя>» (имя записи `MediaStore`, тап —
  `ACTION_VIEW`, нет обработчика — вкладка узла); неудача — «принят» с
  кнопками и строкой «Couldn't save: <причина>».
- **B.** `Taildrop.parseCoreNotification` (тег из `openURL`, остаток —
  `receiving/<senderID>/<baseName>` или имя), кнопки на
  `TaildropNoteReceiver` (неэкспортируемый): Cancel → `cancelTaildropReceiving`,
  Save (API 29+) → `Taildrop.save`, Delete → `deleteTaildropFile`; работа —
  в scope Taildrop на IO. Без ядра кнопка снимает уведомление.
- **C.** Нативные строки `taildrop_save/delete/saved_title/save_failed/
  delete_failed` (en/ru/zh), строки Flutter «Save received files to
  Downloads», «Needs Android 10 or later.» (ru/zh). Имена файлов — только
  в уведомлениях и экстрах их интентов, в журнал не пишутся.

Решения исполнителя (в ТЗ не было):
- Пока идёт автосохранение или Save из уведомления, уведомление «принят»
  стоит без кнопок (второе нажатие некуда), потом заменяется итогом.
- Тексты уведомления ядра (заголовок, тело, подзаголовок) едут в экстрах
  интентов кнопок — чтобы при неудаче Save/Delete поставить его заново без
  ядра.
- Save / Delete на вкладке Network снимают уведомление «принят» этого файла
  (`Taildrop.dismissReceived`), иначе оно висело бы с кнопками на ушедший
  файл.
- Удаление узла: запись снимается в `_relinkTailscaleState` по
  `goneTailscaleTags` (теги до/после операции; узлы неразобранных
  контейнеров — подписка без тела — ушедшими не считаются). Ключ — тег без
  уникализации сборки (`префикс тег`); у тёзки, которому сборка дописала
  суффикс, запись по живому тегу при удалении не снимается (остаётся
  сиротой; новый узел с тем же живым тегом её унаследует). Смена префикса
  источника = смена тега, переключатель теряется.
- Переключатель в блоке Settings только у узла с данными ядра (VPN включён):
  блок Settings целиком живёт в ветке «узел в работающем конфиге».
- Автобэкап Android (`allowBackup` по умолчанию) не трогали: он касается всех
  SharedPreferences одинаково; «не в бэкапе» = не в бэкапе L×Box.
- Тест разбора `identifier` не написан: разбор живёт в Kotlin (сервис без
  Flutter), тестового стенда у Kotlin нет.

Проверено:
- `flutter test test/widgets/tailscale_network_tab_test.dart
  test/services/tailscale_state_store_test.dart` — 84/84: переключатель без
  `onSaveFields` (запись по тегу), рядом с advertise, неактивен на API < 29
  (фейк), разбор настройки из канала, `goneTailscaleTags` (удаление, смена
  тега и префикса, неразобранная подписка);
- `flutter analyze` по изменённым dart-файлам — 0; `hardcoded_check`,
  `ui_check`, `kotlin_check` — 0/0; `compileDebugKotlin` — успешно.

Не проверено (эмулятор, DEVICE-PENDING): автосохранение и уведомление
«Saved to Downloads» с открытием файла, кнопки Save/Delete/Cancel в
уведомлениях, поведение кнопок при выключенном VPN, снятие записи при
удалении узла на устройстве.

**Эмулятор, итерация 2, 02.11.2026** (тот же стенд, `ts-a` → `lxbox-emu-b`):
- Переключатель на `ts-b`: запись `autosave.<tag>` в `lxbox_taildrop` появляется
  и снимается.
- Автосохранение: файл 8 МБ → `Download/big-test (1).bin` (имя занято —
  MediaStore добавил суффикс), sha256 совпал, во входящих пусто; старый файл,
  лежавший до включения, не тронут. Уведомление «Saved to Downloads: …»; тап
  по `.bin` (обработчика нет) → вкладка узла, по `.txt` → выбор приложения,
  содержимое верное.
- Переключатель выкл.: уведомление «принят» с Save и Delete; Save → файл в
  Downloads, из входящих ушёл; Delete → удалён, в Downloads нет.
- Cancel приёма: на «Receiving … from …» кнопка Cancel есть; передача 1,5 ГБ
  на одном эмуляторе идёт секунды, пальцем не успеть — вызван тот же
  broadcast от root: `.partial` удалён, у отправителя «Couldn't send».
  Текст отказа шёл с обёрткой gRPC — `Taildrop.failureText` её срезает,
  теперь «Sending <имя> canceled by receiver».
- Не проверено: API < 29 (переключатель неактивен), кнопки при выключенном
  VPN, снятие записи при удалении узла.

## Итерация 3 — автосохранение забирает и то, что уже лежит во входящих

Владелец 02.11.2026: «если при старте приложения в папке лежит и стоит галка
то автоматом перенести что есть. так может быть если без галки принять а
потом ее поставить». Отменяет правило итерации 2 «файлы, лежавшие во
входящих до включения, не трогаются».

### Solution

Одна нативная процедура «разобрать входящие узла»: у каждого узла Tailscale
с включённым переключателем все готовые файлы его каталога входящих (без
`.partial` и служебных хвостов ядра) переезжают в Downloads тем же путём,
что Save, и уходят из входящих.

Когда запускается:
1. Старт процесса приложения (холодный запуск, в том числе фоном при
   автозапуске VPN).
2. Переключатель включили.
3. Старт VPN — после разового переноса старой общей папки (итерация 1), чтобы
   перенесённое тоже ушло в Downloads, если у первого узла галка стоит.

Как:
- Каталог входящих узла — `taildrop_directory` из последнего собранного
  конфига (как `firstTaildropDirectory`, но по тегу). Конфига нет или узла в
  нём нет — ничего не делать.
- VPN работает и узел в нём есть → через ядро (`Taildrop.save`: download +
  delete), чтобы входящие ядра не разошлись с диском. VPN не работает → прямо
  с диска: файл в `MediaStore.Downloads`, затем удалить файл (каталог — наш,
  ядра нет).
- Повторный запуск, пока первый идёт, — не дублировать (одна очередь на
  процесс).
- Уведомление: одно на прогон, если перенесён хотя бы один файл — «Saved N
  files to Downloads» (1 файл — «Saved to Downloads: <имя>», как в
  итерации 2); тап открывает системные Загрузки
  (`DownloadManager.ACTION_VIEW_DOWNLOADS`, нет обработчика — вкладка узла).
  Уведомления «принят» перенесённых файлов снимаются.
- Ошибка по файлу — файл остаётся во входящих, остальные переносятся; в
  уведомлении «Couldn't save N files».
- API < 29 — ничего (переключатель там неактивен).

### Verification

- Тесты на затронутые файлы (если трогается Dart — переключатель вызывает
  разбор при включении).
- Эмулятор: файл во входящих при выкл. галке → включить → ушёл в Downloads;
  файл во входящих, галка вкл., VPN выкл. → холодный старт приложения → ушёл;
  старая общая папка `<filesDir>/Taildrop` с файлом, галка у первого узла →
  старт VPN → файл в Downloads, папки нет.

### Result (итерация 3)

Сделано:
- `Taildrop.sweepLocked` — разбор входящих: пары (тег, `taildrop_directory`)
  endpoint'ов `tailscale` из `ConfigManager.load()` (`taildropDirectories`),
  у узлов с включённым переключателем готовые файлы (без `.partial`,
  `.deleted` и файлов с меткой `.deleted` рядом, по времени изменения)
  уходят в Downloads. Работает ядро (`BoxService.commandClient`) — через
  `saveInternal` (выгрузка + `deleteTaildropFile`); ядра нет — `saveFromDisk`:
  `writeToDownloads`, затем удаление файла.
- Запуски: `BoxApplication.onCreate` и `taildropSetAutoSave` (только
  включение) — `sweepInboxesAsync` в scope Taildrop на IO; старт VPN —
  `sweepInboxesBeforeCoreStart` в `startSingbox` сразу после
  `migrateLegacyInbox`, до старта ядра.
- Уведомление одно на прогон (id 4999, следующий прогон заменяет): 1 файл —
  «Saved to Downloads: <имя>», тап открывает файл; больше — «Saved N files to
  Downloads», тап — `DownloadManager.ACTION_VIEW_DOWNLOADS`; нет обработчика —
  вкладка узла. Неудачи — строкой «Couldn't save N files». Уведомления
  «принят» перенесённых файлов снимаются (`dismissReceived`).
- Нативные `<plurals>` `taildrop_saved_files`, `taildrop_couldnt_save_files`
  (en/ru/zh), `L10n.plural`.

Решения исполнителя (в ТЗ не было):
- Очередь: один замок на процесс; фоновый запрос, пока другой фоновый ждёт
  замка, не ставится (тот его покроет). Прогон из старта VPN ждёт замка
  синхронно.
- Старт VPN разбирает с диска ДО старта ядра, а не через ядро после
  Started: ядра ещё нет, каталог никто не держит, и не нужно ждать готовности
  Tailscale-бэкенда. Цена — старт VPN ждёт копирования; при включённой галке
  во входящих к старту VPN обычно пусто (старт приложения и включение галки
  уже разобрали), большой объём бывает только при переносе старой папки.
- Фоновый прогон при VPN в состоянии Starting/Stopping (ядро есть или вот-вот
  будет, а `commandClient` нет) ничего не делает: диск под ядром не трогаем,
  старт VPN разберёт сам.
- Файл, который уже уносит автосохранение по уведомлению (итерация 2), разбор
  пропускает, и наоборот (общий набор «в работе» по тег+имя). Если
  уведомление «принят» пришло, пока этот файл уносит разбор, оно остаётся без
  кнопок до конца разбора и снимается им.
- С диска: файл не удалился после копии — копия в Downloads снимается и файл
  считается неудачей (иначе следующий прогон дал бы дубль).
- Одни неудачи (ничего не перенесено) — тоже уведомление, заголовок «Couldn't
  save N files», тап — вкладка узла. Значит неустранимая ошибка повторится
  при каждом старте приложения.
- Переключатель включается нативно (`taildropSetAutoSave`) — разбор тоже
  оттуда; Dart не тронут.

Проверено:
- `compileDebugKotlin` — успешно; `kotlin_check` — 0/0.

Не проверено (эмулятор, DEVICE-PENDING): все три сценария из Verification,
формы ru-plurals на устройстве, путь через ядро при включении галки с
поднятым VPN, API < 29 (разбор не запускается).

**Эмулятор, итерация 3, 02.11.2026:**
- Галка выкл., во входящих `ts-b` файл → включить галку с поднятым VPN →
  файл в Downloads, входящие пусты, «Saved to Downloads: <имя>» (через ядро).
- VPN выкл., галка вкл., во входящих два файла → холодный старт приложения →
  оба в Downloads, содержимое верное, «Saved 2 files to Downloads» (с диска;
  прогон через ~10 с после старта процесса).
- Старая общая папка `<filesDir>/Taildrop` с файлом, галка у первого узла
  (`ts-a`) → старт VPN → папки нет, файл в Downloads (перенос + разбор с
  диска до старта ядра).
- CI 41479836481: упал чужой тест на тайминг AppLog
  (`app_log_notify_during_dispose_test.dart:79`), итерация Dart не трогала;
  перезапущен, флейк вынесен в отдельную задачу.

## Итерация 4 — галка узла «Allow Taildrop» и служебные файлы

Решения владельца 02.11.2026: галка узла «Allow Taildrop» по умолчанию
выключена; служебные файлы `lx-<время>-<метка>.json` с командами `clipboard`
и `open_url` (функция [clipboard-sync](../features/032-TAILDROP/FUNCTIONS/clipboard-sync.ru.md)).
Контракт: 1.1.148 (формат, TASKS_LXBOX §144), 1.1.149 (норма сборки
`disable_taildrop`, ключ разрешения senderID, §145), 1.1.150 (поле
`disable_taildrop`, `min_core` 1.14.4-lx.30-rc.2, гейт с пре-релизами, §146).
Ядро: `disable_taildrop` и `TaildropFile.senderID` — тег lx.30-rc.2 (ждёт
«да» владельца в сессии ядра).

Сделано заранее: `coreAtLeast` (`body_sanitizer.dart`) учитывает пре-релиз
(`lx.30-rc.1 < lx.30-rc.2 < lx.30`; суффикс не `-rc<K>`/`-rc.<K>` — релиз
своего `lx.N`). Без этого поле с `min_core` rc.2 ушло бы в ядро rc.1 и ядро
отвергло бы весь конфиг. Все `min_core` реестра ниже текущего пина — на них
правка не влияет.

Ядро вышло: пин `v1.14.4-lx.30-rc.2` (`5a313f30`), контракт 1.1.150
синкнут (`ac921a16`). Нормы — `app/contract/docs/SERVICE_FILES.md`,
`app/contract/README.md` (строки про `disable_taildrop` и «Гейты сборки»),
`app/contract/registry/service_files.json`, `registry/protocols/tailscale.json`.

### Solution

**A. Галка «Allow Taildrop».**
- Подпись «Allow Taildrop (send and receive files)». Где: блок Settings
  вкладки Network узла (как «Advertise this device as exit node», через
  `onSaveFields`) и форма узла Tailscale (Add server / правка), если там есть
  поля узла. Вкл → в тело `disable_taildrop: false`; выкл → поле снимается.
- Сборка (config-форма, как `taildrop_directory`): нет явного
  `disable_taildrop: false` в теле → эмитится `disable_taildrop: true`.
  Ядро ниже `min_core` — поле снимает полевой гейт (`coreAtLeast` уже с
  пре-релизами, `101afbd1`). Хранимое тело не трогается. Эталоны сборки
  (golden) обновить.
- Применяется после перезапуска VPN (ядро на лету не переключает) — тем же
  путём, что другие поля узла (галка §338 «Auto-restart VPN on settings
  change»).
- Узел с выключенным Taildrop (по статусу ядра `canShareFiles == false` или
  по телу): на вкладке Network нет блока Inbox, «Send file…» и переключателя
  автосохранения; вместо Inbox — строка «Taildrop is off for this node.»;
  в «Поделиться» узел не предлагается; разбор входящих и автосохранение его не
  трогают.

**B. Приём служебных файлов** (нормы SERVICE_FILES.md §2–§6, константы из
`service_files.json`, не литералами).
- В нативе, там же, где автосохранение и разбор входящих (итерации 2–3):
  кандидат `lx-*.json` разбирается раньше автосохранения и уведомления
  «принят». Служебный (по §4) → команды по §6 → файл удаляется всегда;
  не служебный → обычный файл (автосохранение и уведомление как сейчас).
- Отправитель: `TaildropFile.senderID` (новое поле), пусто — `senderName`
  (§5). Для этого нативу нужна запись входящих (подписка / снимок
  `subscribeTaildropInbox`), не только уведомление ядра.
- `clipboard` → `ClipboardManager.setPrimaryClip` (из фона разрешено); из
  нескольких подряд — последний по §6. `open_url` (только схемы из
  `kinds.open_url.schemes`) → уведомление «Link from <device>» с адресом в
  тексте, тап открывает `ACTION_VIEW`; нет обработчика — ничего.
- Просроченный (TTL) или без разрешения — удаляется молча; битая команда —
  warning в AppLog без текста и ссылки.

**C. Разрешения.**
- Меню устройства на вкладке Network узла (где «Send file…»): переключатели
  «Clipboard from this device», «Links from this device». По умолчанию выкл.
- Хранятся на устройстве (`lxbox_taildrop`), не в бэкапе; ключ — тег узла +
  stable ID пира + вид. Для файла без `senderID` сравнивается `senderName` с
  именем пира, записанным при выдаче разрешения (§5: имя к ID само не
  привязывается — разрешение по ID действует и при пустом senderID только
  если совпало имя, сохранённое вместе с ID).
- Удаление узла / смена тега снимают его разрешения (как `goneTailscaleTags`).

**D. Тексты.** en/ru/zh (`docs/l10n.md`, нативные — `values*/strings.xml`).
Текст буфера, ссылки, имена файлов и устройств — не в AppLog, logcat, дамп,
Debug API.

### Out of scope (итерация 6)

Отправка с телефона: плитка «Send clipboard» и устройство-цель, «Поделиться»
ссылкой → «Open on <device>» / «Send as note».

### Verification

- Тесты на затронутые файлы: эмиссия `disable_taildrop` (нет поля → true,
  `false` в теле → не трогается, ядро ниже min_core → снято), галка в блоке
  Settings, скрытие Inbox/Send file у выключенного узла, корпус контракта
  `tailscale_disable_taildrop_false`. Полный прогон — CI.
- Эмулятор: галка выкл → отправка на узел даёт отказ «Taildrop is disabled on
  this node»; вкл + reload → работает; служебный файл с `clipboard` при
  выключенном разрешении — удалён, буфер не тронут; включено — буфер
  заполнен; `open_url` — уведомление, тап открывает; битый `lx-*.json` —
  обычный файл во входящих.

### Result (итерация 4)

Сделано:
- **A. Сборка.** `services/builder/taildrop_emit.dart`
  `applyTaildropDefault` — вызов в `buildConfig` сразу после подстановки
  `taildrop_directory`: endpoint `tailscale` без явного `false` получает
  `disable_taildrop: true`; `min_core` поля берётся из реестра
  (`schemaFor('tailscale').fields['disable_taildrop'].minCore`), сравнение —
  `coreAtLeast`. Хранимое тело не трогается.
- **A. UI.** Вкладка Network (`tailscale_network_tab.dart`): в блоке Settings
  своего узла — «Allow Taildrop (send and receive files)» (вкл →
  `{disable_taildrop: false}`, выкл → `{disable_taildrop: null}` через
  `onSaveFields`, тем же путём, что advertise). Узел выключен по телу —
  нет автосохранения, «Send file…», разрешений и Inbox; вместо Inbox строка
  «Taildrop is off for this node.» (ключ `taildrop-node-off`). Add server →
  вкладка Tailscale: тот же переключатель (по умолчанию выкл, вкл пишет
  `disable_taildrop: false`).
- **B. Натив.** `vpn/TaildropServiceFiles.kt`: константы из ассета
  `flutter_assets/assets/contract/registry/service_files.json` (зеркало
  контракта); кандидат по `name_prefix`/`name_suffix`; разбор §4 (предел,
  строгий UTF-8, `lx` из `versions`, `commands` — список); §6: возраст по
  mtime файла, команды по порядку, `clipboard` — последний по mtime (при
  равенстве — по времени в имени) через `ClipboardManager` на main looper,
  `open_url` — схема из `schemes`, уведомление «Link from <device>» с адресом,
  тап — `ACTION_VIEW` (нет обработчика — ничего); удаление всегда (через ядро,
  нет ядра или отказ — с диска). Отправитель — `BoxCommandClient.
  taildropInboxSnapshot` (разовая подписка `SubscribeTaildropInbox`,
  `TaildropFile.senderID`/`senderName`). Точки входа: уведомление ядра
  «принят» с именем-кандидатом (`Taildrop.onCoreNotification` → разбор в
  фоне; обычный файл — дальше автосохранение/уведомление как раньше) и прогон
  входящих `sweepLocked` (служебные — первыми, у всех узлов с включённым
  Taildrop; автосохранение их пропускает). `taildropDirectories` не отдаёт
  узлы с `disable_taildrop: true` — разбор и автосохранение их не трогают.
  «Поделиться» (`TaildropShareActivity`) не предлагает такие узлы; все
  запущенные выключены — строка `taildrop_off_all`.
- **C. Разрешения.** Меню устройства: «Clipboard from this device», «Links
  from this device» (виды — что вернул натив из реестра, подпись по виду в
  Dart). Хранятся в `lxbox_taildrop`: ключ `perm.<вид>.<тег>␁<stableID>`,
  значение — имя пира при выдаче. Файл без `senderID` сверяется с этим
  именем. `forgetAutoSave` (удаление узла / смена тега) снимает и разрешения
  (`TaildropServiceFiles.forgetTags`). Канал: `taildropPermissions`,
  `taildropSetPermission`.
- **D.** Строки en/ru/zh: `ui.json` (4), `values*/strings.xml`
  (`taildrop_link_from`, `taildrop_off_all`). Битая команда — WARN «N
  malformed command(s) skipped» в logcat и AppLog (`BoxService.appLogWarning`)
  без текста, ссылки и имён.

Решения исполнителя:
- Подстановка идёт ПОСЛЕ гейта реестра с явной проверкой `min_core`, а не
  до него полевым гейтом: гейт не применяет тихие правки (`min_core` без
  кода) к авторскому телу (§577, `applyRegistryEdits` правит у авторского
  только пути кодов и `hardPaths`), и явное `false` из авторского тела ушло
  бы в ядро старше rc.2 — оно отвергло бы весь конфиг. На ядре ниже
  `min_core` поле снимается у всех endpoint'ов `tailscale`, и явное тоже.
  Реестр не загружен или поля в нём нет — сборка поле не пишет.
- Golden-эталоны не менялись: версия ядра эталонов `1.14.0-lx.39` ниже
  `min_core`, поле не эмитится — это и есть проверка ветки «старое ядро».
  Эмиссия на пине — `node_sections_build_test`.
- Выключен ли Taildrop узла, вкладка решает по телу (нет явного `false`):
  статус `canShareFiles == false` при включённом теле уже даёт прежнюю строку
  про tailnet и прячет «Send file…». Подписка на входящие у выключенного
  узла остаётся (лежащие файлы не показываются).
- Узел подписки: переключателя нет (тело узла — у подписки), Taildrop у него
  выключен и из UI не включается. Включить — только через тело источника.
- Разрешения показываются у устройств со `stableId`, не расшаренных
  (`shareeNode`), при включённом Taildrop узла — не только у «целей
  отправки»: пир вне сети тоже настраивается.
- Имя пира для сверки по имени — `hostName` из статуса; что это то же, что
  `ComputedName` (`senderName` у `TaildropFile`), не сверено.
- Уведомление ядра «идёт приём» у кандидата не подавляется (имя ещё не
  разобрано); «принят» у служебного не показывается.
- До старта ядра (прогон из старта VPN) служебные файлы удаляются с диска
  без выполнения команд: отправителя нет, разрешение не находится (§5).
- Тело с ведущим BOM — обычный файл («JSON в UTF-8 без BOM», §3).
- Пустой `text` у `clipboard` и поля не того типа — «битая команда»
  (WARN-счётчик); неизвестный `kind` — пропуск молча.
- Заголовок уведомления ссылки — `senderName`, пустой — тег узла.

Проверено:
- `flutter test`: `test/widgets/tailscale_network_tab_test.dart`,
  `test/builder/node_sections_build_test.dart` — зелёные (новые: галка вкл/
  выкл, выключенный узел — строка, нет Inbox/Send file/разрешений,
  переключатели разрешений в меню, расшаренному — нет; эмиссия: нет поля →
  true, явное false, ядро rc.1 и lx.29 — поля нет, тело не тронуто);
  `test/storage_migration/golden_config_test.dart` — эталоны совпали;
  `body_contract_test` кейс `singbox/tailscale_disable_taildrop_false` —
  зелёный.
- `flutter analyze` по изменённым dart-файлам — 0; `hardcoded_check`,
  `kotlin_check` — 0/0; `./gradlew :app:compileDebugKotlin` — без ошибок.

Не проверено:
- Эмулятор и телефон — ни одного сценария раздела Verification (отказ
  «Taildrop is disabled on this node», reload, буфер, ссылка, битый
  `lx-*.json`).
- Юнит-тестов Kotlin нет (в модуле нет `src/test`): разбор тела §4,
  выбор последнего `clipboard`, ключи разрешений проверены только чтением.


**Эмулятор, итерация 4, 02.11.2026** (пин lx.30-rc.2):
- Галки выкл.: в собранном конфиге у всех четырёх узлов `disable_taildrop:
  true`; на вкладке Network «Taildrop is off for this node.», в меню
  устройства нет «Send file…» и разрешений; «Поделиться» — «Taildrop is off
  for every running Tailscale node…».
- Галка вкл. у `ts-a`/`ts-b` → тело `disable_taildrop: false`, после
  rebuild + reload — `false` в конфиге; заметка ts-a → ts-b дошла и
  автосохранилась. Галка сама VPN не перезапустила (на эмуляторе выключено
  «Auto-restart VPN on settings change»).
- Отправка на `lxbox-emu-c` (Taildrop выкл.): «Couldn't send to lxbox-emu-c —
  Taildrop is disabled on this node». Узел-получатель с выключенным Taildrop в
  списке «Send to» есть: это решает control, ядро так и предупреждало.
  `failureText` теперь берёт последнее звено цепочки Go (`…: <текст>`).
- Служебный файл `clipboard` без разрешения — удалён, ни во входящих, ни в
  Downloads. С разрешениями: `clipboard` + `open_url` https + `open_url`
  file:// в одном файле → буфер «clip-WITH-perm» (вставкой в Chrome),
  уведомление «Link from lxbox-emu-a», тап открыл ссылку; file:// пропущен.
- Битый `lx-*.json` — обычный файл, автосохранён в Downloads.
- Разрешения пишутся `perm.<kind>.<tag>\x01<stableID>` = имя пира.

## Итерация 5 — маршруты Debug API для Taildrop

Владелец 02.11.2026: «ты много экран тыкаешь. сделай API». Проверка Taildrop
на эмуляторе сейчас идёт через тапы по экрану и шторке; нужны маршруты,
которыми то же делается одной командой. Пункт «Маршруты Debug API для
Taildrop» из Out of scope итераций 1–2 снимается сюда.

### Solution

Раздел `/taildrop` Debug API (`app/lib/services/debug/`, по образцу соседних
handler'ов; `/help` и `docs/api/debug-api-reference.md` обновить). Имена
файлов и устройств, текст буфера и ссылки по умолчанию не отдаются (правило
030); `?reveal=true` открывает их, как у `GET /state/subs` (Debug API —
root-доступ by design, маска — удобство).

| Маршрут | Что делает |
|---------|------------|
| `GET /taildrop` | по каждому узлу Tailscale работающего конфига: `tag`, `allow` (галка, по телу), `disable_taildrop` (собранный конфиг), `can_share_files` (ядро), `autosave`, `inbox_files`, `receiving`, `self_id` (stable ID узла) |
| `GET /taildrop/peers?tag=` | пиры узла: `id` (stable), `os`, `online`, `can_receive_files`, `sharee`, разрешения `clipboard`/`open_url`; `name` — только с `reveal` |
| `GET /taildrop/inbox?tag=` | файлы входящих: `index`, `size`, `sha256`, `age_s`, `sender_id`; `name`, `sender_name` — с `reveal`; и принимаемые с прогрессом |
| `POST /taildrop/send` | `{tag, peer, name, content_base64}` или `{tag, peer, text}` (заметка) или `{tag, peer, commands:[…]}` (служебный файл по SERVICE_FILES.md, имя собирается само). Отправка тем же нативным путём, что «Send file…»; ответ — итог (`sent` / ошибка ядра), ждёт окончания до 60 с |
| `POST /taildrop/inbox/save` `{tag, index}` | как Save (Downloads); ответ — имя в Downloads с `reveal` |
| `POST /taildrop/inbox/delete` `{tag, index}` | как Delete |
| `POST /taildrop/inbox/cancel` `{tag, index}` | отмена принимаемого |
| `PUT /taildrop/settings` `{tag, autosave?, allow?}` | переключатель автосохранения (сразу, с разбором лежащего); `allow` пишет тело узла, применяется после `?rebuild=true` + `reload-vpn` |
| `PUT /taildrop/permissions` `{tag, peer, kind, enabled}` | разрешение на вид команды от пира |
| `GET /taildrop/service-files` | счётчики с начала процесса: `received`, `executed.{clipboard,open_url}`, `skipped_no_permission`, `expired`, `invalid`, `last` (`kind`, `at`, `sha256` текста/ссылки; сам текст — с `reveal`) |

- Отказы — общий формат Debug API (`{"error":{code,message}}`): нет узла —
  404, VPN выключен — 409, Taildrop выключен — 409 с текстом ядра.
- Маршруты работают и при свёрнутом приложении (натив через тот же канал,
  что вкладка Network).

### Verification

- Тесты handler'ов на фейке действий (по образцу соседних тестов Debug API).
- Эмулятор: весь сценарий итераций 2–4 одной цепочкой `curl` без тапов —
  отправка ts-a → ts-b, автосохранение, Save/Delete, отказ при
  `allow=false`, служебный файл без и с разрешением (счётчики
  `service-files`).

### Result (итерация 5)

Сделано:
- Раздел `/taildrop` Debug API (`app/lib/services/debug/handlers/taildrop.dart`,
  смонтирован в `buildDebugRouter`): все десять маршрутов таблицы Solution.
  Действия — через `TaildropDebugActions` (по умолчанию `CcChannel`, тот же,
  что у вкладки Network; тесты подменяют `instance`).
- Натив: `Taildrop.send` получил необязательный колбэк итога (`SendDone`:
  `sent` / `cancelled` / `error` с текстом ядра без обёртки gRPC) — тот же
  путь, что «Send file…», с уведомлением и Cancel; `Taildrop.saveToDownloads`
  — Save с именем записи `MediaStore`; `BoxCommandClient.taildropInboxOnce` —
  разовый снимок входящих формы потока вкладки (`taildropInboxSnapshot`
  итерации 4 теперь на нём), у принятых файлов добавлен `sender_id`;
  `TaildropServiceFiles.stats()` — счётчики разбора.
- Канал: `ccTaildropSendBytes` (байты с именем или заметка `Taildrop.noteItem`,
  ожидание итога), `ccTaildropInboxSnapshot` (снимок + sha256 файлов с диска),
  `taildropServiceStats`; `ccTaildropSave` — флаг `downloads_only` и `name` в
  ответе. Dart: `CcTaildropFile.senderId/sha256`, `CcTaildropResult.name`.
- `/help` (текст и JSON), `docs/api/debug-api-reference.md` (раздел Taildrop),
  CHANGELOG.

Решения исполнителя:
- `POST /taildrop/send` ждёт итог 60 с, а общий предел запроса Debug API —
  30 с: у `timeoutMiddleware` появился предел по пути (`perPath`), у
  `/taildrop/send` — 65 с. Не уложилась — `202 status:"in_progress"`
  (передача идёт дальше). Ошибка ядра — 409 с его текстом.
- `GET /taildrop` и `PUT /taildrop/settings` работают и при выключенном VPN
  (поля ядра `null`); остальные маршруты — 409. Узлы — endpoint'ы
  `tailscale` конфига работающего ядра, его нет — сохранённого.
- `allow` — по хранимому телу (`taildropAllowedByBody`), тело ищется как у
  Save choice (свой сервер / член папки), затем среди узлов подписок;
  запись `allow` — только своему серверу и члену папки (`storeTailscaleFields`),
  узел подписки — 409.
- `peer` — stable ID, имя устройства, MagicDNS-имя или IP; не найден — 404 без
  повтора значения (это может быть имя).
- Индекс входящих — по времени приёма, при равенстве по имени. Save / Delete
  принимают и `name` вместо `index` (имя известно с `reveal`). Save ниже
  Android 10 — 409 (системный диалог маршрут не открывает).
- Служебный файл собирается в Dart из ассета реестра (`name_prefix`,
  `name_time_format` — поддержан только `YYYYMMDDTHHMMSSZ`, иначе 500,
  `name_label_length`, `versions` — последняя, `max_bytes` — проверяется, как
  у отправителя §7). Команды не проверяются: Debug API шлёт и битые, чтобы
  проверять разбор получателя.
- `content_base64` упирается в предел тела Debug API 1 MiB (файл до ~750 KB):
  предел не поднимали, для больших файлов остаётся «Send file…».
- Счётчики (только в памяти натива, с начала процесса): кроме таблицы —
  `unknown_kind`, `skipped_scheme`, `no_handler` (у `open_url`), иначе
  пропуск не виден. `executed.clipboard` — одна запись в буфер на пачку
  (последний `clipboard`, §6); `expired` и `received` — по файлам, `invalid`
  и `skipped_*` — по командам. `last` — последняя ВЫПОЛНЕННАЯ команда;
  в ответе `sha256` значения, само значение (`value`) — с `reveal`.
- sha256 входящих считается при каждом `GET /taildrop/inbox` чтением файла
  целиком; на файлах в гигабайты запрос может упереться в предел 30 с.

Проверено:
- `flutter test test/services/debug/taildrop_handler_test.dart` (новый, 15:
  поля узлов, VPN off, маска имён и `reveal`, 404/409/400, сортировка и
  индексы входящих, три формы отправки, 202/409, имя и тело служебного
  файла по реестру, `max_bytes`, save/delete/cancel по индексу, settings,
  permissions, счётчики, предел по пути у таймаута),
  `help_json_test.dart`, `server_integration_test.dart`,
  `pipeline_test.dart` — зелёные.
- `flutter analyze` по изменённым dart-файлам — 0;
  `./gradlew :app:compileDebugKotlin` — без ошибок.

Не проверено: эмулятор — весь сценарий Verification (цепочка `curl`
ts-a → ts-b, автосохранение, Save/Delete, отказ при `allow=false`,
служебный файл без и с разрешением, счётчики); Kotlin-часть (колбэк итога
отправки, снимок с sha256, счётчики) — только компиляцией.

**Эмулятор, итерация 5, 02.11.2026** (только `curl`, без экрана):
- `GET /taildrop`: четыре узла, `allow`/`can_share_files`/`self_id` верны.
- `PUT /taildrop/settings` autosave=false → `POST /taildrop/send` 300 KB
  ts-a → lxbox-emu-b: `sent`, sha256 в ответе = sha256 во
  `GET /taildrop/inbox` = sha256 исходника; `inbox/save` → `Download/api.bin`,
  sha256 совпал; заметка + `inbox/delete` → входящие пусты.
- Отправка на `lxbox-emu-c` (Taildrop выкл.) → 409 «Taildrop is disabled on
  this node».
- `PUT /taildrop/permissions` clipboard=false → команда `clipboard` →
  `skipped_no_permission: 1`, `executed.clipboard: 0`; clipboard=true →
  `clipboard` + `open_url ftp://` + `kind: bogus` → `executed.clipboard: 1`,
  `skipped_scheme: 1`, `unknown_kind: 1`, `last.value` = отправленный текст;
  служебные файлы во входящих не остались.
- Правка после проверки: `tag` находит узел и без префикса источника
  (`ts-b` → `🕸️ ts-b`), если такой один.
- Замечание: `disable_taildrop` в `GET /taildrop` у включённых узлов `null`,
  хотя в собранном конфиге `false` — читает поле только как `true`.
