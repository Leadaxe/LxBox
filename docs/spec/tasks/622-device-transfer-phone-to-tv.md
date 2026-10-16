# §622 — Передача настроек с телефона на TV: QR + одноразовый ключ по LAN

| Поле | Значение |
|------|----------|
| Тип | F (новая фича) |
| Статус | Implemented (2026-10-16); ручные проверки на эмуляторах TV/телефона не проведены |
| Дата | 2026-10-09 |
| Связанные | [Leadaxe/LxBox#163](https://github.com/Leadaxe/LxBox/issues/163); фича [031-DEVICE_TRANSFER](../features/031-DEVICE_TRANSFER/FEATURE.ru.md); §372 (Android TV); §375/§382 (QR-сканер); 017-BACKUP_AND_STORAGE |

## Проблема

#163: настраивать LxBox на Android/Google TV пультом слишком сложно, автор
просит веб-настройку или синхронизацию. Пути импорта, которые есть сейчас,
на TV неудобны: URL подписки и ссылки на узлы набираются пультом, выбора
файлов для бэкапа нет (§372 — системная заглушка вместо DocumentsUI).

## Решение (выбрано владельцем 09.10)

Вариант «п.2»: TV показывает QR с адресом в LAN и одноразовым ключом,
телефон сканирует его и отправляет зашифрованный полный бэкап, TV
показывает обычный предпросмотр восстановления. Поведение и контракт
формата описаны в фиче 031, здесь — только реализация.

Отвергнуто: полный веб-интерфейс (второй UI ко всему приложению, большая
поверхность атаки в LAN), облачная синхронизация (нет своего сервера,
секреты у третьей стороны), открытие Debug API в LAN (ломает его
обещания P1/P3). Веб-форма на том же приёмнике («п.3») — возможное
продолжение отдельной задачей.

## Ключевые узлы

### 1. Протокол и конверт — `lib/services/transfer/transfer_code.dart`, `transfer_envelope.dart`

- Код передачи `lxbox-transfer:1?a=…&k=…&n=…`: сборка и разбор,
  отказ на чужую схему или версию (сканер может принести любой QR).
- Ключ — 32 случайных байта (`Random.secure`), в QR в base64url без `=`.
- Конверт: `AesGcm.with256bits()` из `cryptography` (уже в pubspec,
  §025), nonce 12 байт, AAD `lxbox-transfer/1`; JSON `{v, nonce, ct}`,
  где `ct` — шифротекст вместе с тегом MAC.
- Чистые функции, без ввода-вывода — проще всего покрываются юнитами.

### 2. Сервер приёма — `lib/services/transfer/transfer_receiver.dart`

- `HttpServer.bind(InternetAddress.anyIPv4, 0)`: порт выбирает ОС.
  С `DebugServer` (`lib/services/debug/transport/server.dart`) код не
  делить: там loopback и проверка Host — противоположные гарантии.
- Один маршрут `POST /transfer`, остальное — 404. Тело читается с
  ограничением 32 МиБ (413 сразу, как только предел превышен).
- Порядок: размер → JSON-конверт (400) → расшифровка (403, счётчик
  отказов; на 5-м сессия закрывается) → `BackupService.parseImport`
  (422 с причиной) → 200 → закрытие сессии → событие «получено» с
  `BackupContents`.
- Повторный запрос после успеха — 409 (сессия уже закрыта, на деле
  отказ соединения; 409 — пока сокет ещё жив).
- Таймер 10 минут; `close()` идемпотентный, вызывается из `dispose`
  экрана.
- Адреса для QR: `NetworkInterface.list(type: IPv4)`, без loopback,
  `tun*` и link-local; Wi-Fi и Ethernet раньше прочих. Если адресов нет —
  экран сразу говорит «No local network».
- Журнал: `[transfer]` — открытие, порт, число адресов, исходы запросов;
  ключ и текст QR не пишутся (P9).

### 3. Экран приёма — `lib/screens/transfer_receive_screen.dart`

- **Только TV (решение владельца 16.10).** Признака TV в коде нет —
  новый метод канала `isTelevision` в `MainActivity`:
  `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` или
  `hasSystemFeature(FEATURE_LEANBACK)`; кешировать на процесс.
  `hasRealFilePicker` признаком TV не считать (бывают телефоны без
  DocumentsUI).
- Входы (только на TV): экран бэкапа (`backup_screen.dart`) и пустой
  главный экран (`screens/home/restore_backup.dart`, рядом с «Restore
  from backup»), в обоих — первым пунктом.
- QR через `flutter_zxing` (`zx.encodeBarcode`; кодирование есть в
  пакете, новых зависимостей нет), крупно, на белом поле.
- Под QR: имя устройства, адрес(а), обратный отсчёт, состояние
  (ожидание / получено / отказ). Кнопки «Cancel» и «New code» —
  фокусируемые, автофокус на «Cancel» (D-pad, §372).
- Экран не гаснет: флаг `FLAG_KEEP_SCREEN_ON` через существующий
  method channel `MainActivity` (новый метод, 5–10 строк Kotlin).
- После получения — тот же путь, что у импорта файла: выделить из
  `backup_screen.dart:211–250` общий `restoreFromContents(contents)`
  (`showImportPreview` → `applyImport` → `LocaleController` /
  `syncAutomationFromStorage` → итог с «Restart now») и звать его из
  обоих мест. Дублировать этот блок нельзя: в нём уже три
  пост-шага от разных задач (§279, §605, §607).

### 4. Отправка — `lib/screens/transfer_send_screen.dart` (или шаг в `backup_screen.dart`)

- Пункт «Send to TV» на экране бэкапа — на всех устройствах, кроме TV,
  и только при наличии камеры (`UrlLauncher.hasCamera()` — то же условие,
  что у кнопки QR-сканера в `subscriptions_screen.dart`).

- Выбор категорий: тот же набор, что у экспорта, Debug API выключен по
  умолчанию (`BackupService.buildExport(include:)`).
- Скан: `QrScanScreen` как есть; новый тип результата не нужен —
  разбор кода передачи делается после возврата текста. Чужой QR →
  «This is not a LxBox transfer code».
- Перед отправкой — диалог «Send to <n>?».
- `HttpClient` с таймаутом соединения 5 с, адреса по очереди; ответы
  200/403/409/413/422 и сетевые ошибки → тексты из P6 фичи.

### 5. Обход собственного туннеля на отправителе (P7) — главный риск

LxBox в allow-mode кладёт себя в туннель (`BoxService.kt:961`, «+self»).
Тогда запрос на `192.168.x.x` попадает в sing-box; если пресет
`private-ip` выключен или направлен в прокси, отправка уходит в
туннель и умирает по таймауту.

Варианты, по возрастанию цены — выбрать по результату проверки на
эмуляторе:

1. Проверить, что при поднятом туннеле и выключенном `private-ip`
   отправка действительно ломается (возможно, LAN-маршруты не идут в tun
   из-за маршрутов VpnService — тогда делать ничего не нужно).
2. Отправку делать из Kotlin через `Network.openConnection()` для
   не-VPN сети (`ConnectivityManager`, транспорт Wi-Fi/Ethernet) — новый
   метод канала, ~60 строк, Dart передаёт адрес и байты.
3. `VpnService.protect(socket)` — только пока сервис жив, неудобно из
   Dart; держать запасным.

На получателе поднятый туннель входящие на адрес wlan0 не трогает —
проверить тем же прогоном.

### 6. Локализация и доки

- Новые строки UI — английский ключ + переводы по 029-LOCALIZATION
  (около 25 строк).
- `docs/USER_GUIDE.md` / `.ru.md`: раздел «Set up a TV from your phone».
- Фича 031: файлы функций `FUNCTIONS/receive-session.md`,
  `send-to-device.md` (+ `.ru.md`), свидетели в обещаниях, состояние ✅.
- Ссылка на 031 из 017-BACKUP_AND_STORAGE («Связанные фичи»).

## Оценка объёма

| Узел | Код | Тесты | Сложность |
|------|-----|-------|-----------|
| 1. Код передачи и конверт | ~150 | ~200 | низкая |
| 2. Сервер приёма | ~250 | ~300 (реальный сокет на loopback) | средняя |
| 3. Экран приёма + KEEP_SCREEN_ON + вынос `restoreFromContents` | ~300 + 15 Kotlin | ~80 (виджет-тест состояний) | средняя |
| 4. Отправка | ~250 | ~120 (отображение ошибок) | средняя |
| 5. Обход туннеля | 0–80 Kotlin + 30 Dart | ручная проверка | неизвестна до замера |
| 6. l10n, руководство, функции фичи | ~25 строк l10n, ~150 строк доков | гейты l10n | низкая |

Итого ~1000–1100 строк кода и ~700 строк тестов. Новых зависимостей нет
(`cryptography`, `flutter_zxing` уже в pubspec), ядро и контракт не
затрагиваются.

По волнам: один Opus-исполнитель в worktree на узлы 1–4 и 6 (одна
сессия), узел 5 — отдельный короткий заход после проверки на стенде.
Основная неопределённость — узел 5 и ручная проверка: два эмулятора на
одном хосте друг друга не видят (у каждого свой 10.0.2.15), поэтому
нужен проброс `adb forward` на TV-эмуляторе плюс отладочная подмена
адреса в коде передачи — или реальный TV и телефон в одной сети
(телефон владельца — только с его разрешения).

## Решение (реализация 2026-10-16)

Узлы 1–4, 6 и Kotlin-часть узла 5 сделаны; ручная проверка на стенде не
проводилась.

- **Код и конверт:** `app/lib/services/transfer/transfer_code.dart`
  (`TransferCode.encode/tryParse`, `toString` маскирует ключ),
  `transfer_envelope.dart` (`sealTransferEnvelope` / `openTransferEnvelope`,
  ошибки формата → 400, аутентификации → 403).
- **Сервер приёма:** `app/lib/services/transfer/transfer_receiver.dart` —
  `HttpServer.bind(anyIPv4, 0)`, один маршрут, порядок и коды как в узле 2;
  в обработке один запрос за раз (чтение тела, расшифровка, разбор),
  остальные `POST /transfer` получают 503 «busy» до чтения тела (ревью:
  параллельные запросы по 32 МиБ роняли бы TV по памяти); 400 и 403 оба
  идут в счётчик отказов (иначе мусором можно держать единственный слот
  всю сессию); 422 сессию не закрывает. На отправителе 503 — отдельная
  строка «The TV is busy with another request. Try again in a moment.» `pickTransferAddresses` / `localTransferAddresses` — адреса
  для QR (отбрасываются также `ppp*`, `wg*`, `ipsec*`).
- **Решение «показывать пункт»:** `app/lib/services/transfer/transfer_entries.dart`;
  признаки — `UrlLauncher.isTelevision()` (новый метод канала `isTelevision`
  в `MainActivity.kt`: `UI_MODE_TYPE_TELEVISION` или `FEATURE_LEANBACK`,
  кеш на процесс в Dart) и `UrlLauncher.hasCamera()`.
- **Экран приёма:** `app/lib/screens/transfer_receive_screen.dart` — QR
  через `zx.encodeBarcode` (модуль = пиксель, рисуется `CustomPainter` на
  белом поле), автофокус на «Cancel», `setKeepScreenOn` (новый метод
  канала, снимается в `dispose`). Принятый бэкап возвращается через `pop`.
- **Общий путь восстановления:** `app/lib/screens/backup_screen/restore_flow.dart`
  (`restoreFromContents`), зовут импорт файла и приём в
  `backup_screen.dart` и приём на пустом главном экране
  (`home/restore_backup.dart` → `receiveFromPhone`, с перечитыванием
  подписок через `onApplied`).
- **Отправка:** шаг в `backup_screen.dart` (`_onSendToTv`, категории
  карточки Export), карточка `backup_screen/device_transfer_card.dart`,
  тексты итога `backup_screen/transfer_send_text.dart`, доставка
  `app/lib/services/transfer/transfer_sender.dart`.
- **Узел 5 (P7):** `app/android/.../LanTransferSender.kt`, метод канала
  `lanPost`. Сокет создаётся `Network.socketFactory` сети Wi-Fi/Ethernet без
  `TRANSPORT_VPN` (при нескольких — той, в чьей подсети адрес) и тем самым
  привязан к её netId; netd пускает такую привязку для UID, которому
  разрешено защищать сокеты, — владелец VPN среди них, `allowBypass` не
  нужен. HTTP пишется руками: `HttpURLConnection` подчиняется
  `network_security_config`, где cleartext разрешён только для loopback.
  Нет такой сети или канала — `HttpClient` в Dart. Отказ соединения
  трактуется как «код истёк/использован», таймаут — «недоступно».
- **Пункты входа:** TV — первая карточка экрана Backup и кнопка над
  «Restore from backup» в гайде пустого главного экрана
  (`add_server_cta.dart`, `node_list.dart`, `home_screen.dart`); телефон с
  камерой — карточка «Send to TV» под Export.
- **Тесты:** `app/test/services/transfer/transfer_code_test.dart`,
  `transfer_envelope_test.dart`, `transfer_receiver_test.dart` (реальный
  сокет на loopback), `transfer_sender_test.dart`,
  `transfer_entries_test.dart`, `app/test/screens/backup_screen_transfer_test.dart`.
- **Доки:** фича 031 (свидетели, функции `receive-session`, `send-to-tv`),
  017 «Связанные фичи», `docs/USER_GUIDE.md` / `.ru.md` → «Set up a TV
  from your phone». Файл функции отправки назван `send-to-tv` (в узле 6
  было `send-to-device`).

## Проверка (критерии приёмки)

- Юниты: разбор кода (чужая схема, версия 2, без ключа), конверт
  (правильный ключ, чужой ключ, порченый `ct`, порченый nonce), сервер
  (413, 403 ×5 → закрыт, 200 → закрыт, 409, таймаут, порт после
  `close()` отказывает), маскирование ключа в журнале.
- Эмулятор TV (API 31, §372) + эмулятор телефона: полный проход
  «QR → скан → предпросмотр → Replace → Restart now», подписки на TV
  обновляются.
- То же с поднятым туннелем на обеих сторонах и выключенным
  `private-ip` на отправителе.
- Весь экран приёма проходится с D-pad без касаний.
- На эмуляторе телефона пункта приёма нет, на эмуляторе TV нет пункта
  отправки (P10).

## Не входит

- Веб-форма на приёмнике (п.3 из обсуждения #163).
- IPv6, обнаружение устройств в сети, ручной ввод кода.
- Синхронизация после первой передачи.
