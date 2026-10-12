# 634 — Speed Test: Upload только у серверов с проверяемым endpoint, честный Via

| Field | Value |
|-------|-------|
| Status | Done, released in v2.25.13 |
| Start date | 2026-10-12 |
| End date | 2026-10-12 |
| Commits | `fix(634): Speed Test — Upload только у серверов с проверяемым endpoint, честный Via` |
| Related specs | §015 (speed test), §279 (typed `speed_test_options`), §259 (refcount profilerClient), §174 (`chains` в connections) |

## Problem

**Upload.** У сервера без `upload_url` приложение отправляло тело на адрес
скачивания (`app/lib/screens/speed_test_screen.dart:317`:
`_serverUploadUrl(...) ?? _serverDownloadUrl(...)`), методом PUT по умолчанию
(`:320-325`), и статус ответа не проверяло: `_uploadStream` возвращал
`data.length` при любом ответе (`:326`). Отказ сервера (405, 413) засчитывался
как отправленные 5 МБ, поэтому Upload у восьми серверов из десяти был
произвольной цифрой — время ответа на отказ, а не скорость отправки. Так же
писалась и Session History.

**Via.** Строка над результатами бралась из состояния главного экрана
(`speed_test_screen.dart:102-106`: `activeInGroup ?? selectedGroup`), а не из
маршрута запросов. Запросы приложения идут через туннель: свой пакет в
deny-режиме не исключается, в allow-режиме добавляется в `include_package`
(`app/lib/services/config_staleness.dart:115-128`), значит, их маршрутизирует
ядро по правилам. Пресет Ru internet segment (`ru-direct`, `default: true`,
`outbound` = `direct-out`, `app/assets/wizard_template.json`, inline
rule_set `ru-domains` с `domain_suffix: ru`) уводит серверы Hostkey (Moscow)
и Selectel (RU) в direct-out, а экран писал `Via: <узел>`. Находка
подтверждена по коду.

## Diagnosis

Публичные описания серверов и проверка запросом (12.10.2026, curl с машины
разработчика):

| Сервер | host | download | upload endpoint | Источник |
|---|---|---|---|---|
| Cloudflare | speed.cloudflare.com | `/__down?bytes=25000000` | `POST /__up` | был в шаблоне; 5 МБ → 200 |
| Hostkey (Moscow) | spd-rudp.hostkey.ru | `/files/10mb.bin` | `POST /empty`, ≤ 1 МБ за запрос | страница сервера — LibreSpeed, конфиг `ulURL:"empty"`; 1 МБ → 200, 1,5 МБ и больше → 413 |
| Selectel (RU) | speedtest.selectel.ru | `/10MB` | n/a | страница — SPA Selectel без адреса отправки; PUT на `/10MB` → 405 |
| Hostkey (Frankfurt) | spd-desrv.hostkey.com | `/files/10mb.bin` | `POST /empty`, ≤ 1 МБ | как Moscow: LibreSpeed `ulURL:"empty"`; 1 МБ → 200, 1,5 МБ → 413 |
| Hostkey (Amsterdam) | spd-nlsrv.hostkey.com | `/files/10mb.bin` | n/a | корень сервера отвечает 404, конфиг LibreSpeed не опубликован; `POST /empty` отвечает 200, но это не описание — не добавлено |
| Hostkey (Helsinki) | spd-fisrv.hostkey.com | `/files/10mb.bin` | `POST /empty`, ≤ 1 МБ | LibreSpeed `ulURL:"empty"` на странице сервера |
| Hostkey (New York) | spd-uswb.hostkey.com | `/files/10mb.bin` | `POST /empty`, ≤ 1 МБ | LibreSpeed `ulURL:"empty"` на странице сервера |
| Tele2 (EU) | speedtest.tele2.net | `/10MB.zip` (http) | `PUT /upload.php` (http) | раздел «HTTP upload» на speedtest.tele2.net: `curl -T … /upload.php`; 5 МБ → 200 |
| OVH (France) | proof.ovh.net | `/files/10Mb.dat` | n/a | сервер раздачи файлов, адреса отправки в описании нет |
| ThinkBroadband (UK) | ipv4.download.thinkbroadband.com | `/10MB.zip` (http) | n/a | thinkbroadband.com/download — только файлы для скачивания |

Через туннель маршрут запроса знает только ядро. В приложении он есть в
CommandClient connections (`CcChannel.instance.connections`, поле
`outbound` у `CcConnection`) — тот же поток, что у экрана Conns.

Побочная находка: у Hostkey (Amsterdam) `ping_url` (`https://spd-nlsrv.hostkey.com/`)
отвечает 404, поэтому Ping у него всегда `Failed`. Не чинилось — вне задачи.

## Solution

Шаблон (`app/assets/wizard_template.json`): четырём серверам Hostkey с
опубликованным LibreSpeed-конфигом добавлены `upload_url` = `/empty`,
`upload_method: POST`, `upload_chunk_bytes: 1000000`. Новое поле модели
`SpeedTestServer.uploadChunkBytes` (`app/lib/models/parser_config.dart`) —
предел одного запроса; `hasUpload` = непустой `upload_url`. JSON шаблона не
держит комментариев, источники — в таблице выше и в `docs/TEMPLATE.md`.

Экран (`app/lib/screens/speed_test_screen.dart`):

- Upload меряется только при `hasUpload`. Без него запрос не отправляется,
  этап Testing upload... пропускается, шкала и история показывают `n/a`.
- Каждый поток шлёт 5 МБ запросами по `upload_chunk_bytes` (или одним) до
  дедлайна 30 с; засчитываются байты запросов с ответом < 400. Ответ ≥ 400
  останавливает поток. Если сервер не принял ничего — `Failed` на шкале,
  `↑—` в истории.
- `_SpeedTestResult.upload` стал `double?` (null = n/a, < 0 = отклонено);
  остальная форма записи та же, история живёт в памяти сессии, миграции нет.
- Via: на время теста экран берёт profilerClient (`acquireProfiler`/
  `releaseProfiler`, refcount §259) и слушает connections; outbound
  соединения с хостом download-адреса (свой пакет или без атрибуции)
  запоминается для выбранного сервера. Строка: `Direct (no VPN)` без VPN;
  до теста — `Route depends on your rules, shown after the test`; после
  теста — `Via: <outbound>` (узел или `direct-out`) или
  `Route depends on your rules`, если ядро соединение не сообщило. В истории
  — тот же outbound, `Direct` без VPN, `—` без ответа ядра.

Новые строки UI с переводом в `ru`/`zh`: `Route depends on your rules, shown
after the test`, `Route depends on your rules`, `n/a`.

Документация: раздел Speed Test в `docs/USER_GUIDE.md` и
`docs/USER_GUIDE.ru.md`, `speed_test_options` в `docs/TEMPLATE.md`.

## Risks

- Если download ушёл на запасной сервер (выбранный не отдал файл), Via
  остаётся по хосту выбранного сервера и будет `Route depends on your rules`.
- Без process-атрибуции в ядре соединение с тем же хостом от другого
  приложения в эти секунды тоже даст outbound; вероятность низкая.

## Verification

- `flutter test test/models/template_options_models_test.dart` —
  `upload_chunk_bytes`, `hasUpload` для сервера с адресом и без.
- `flutter analyze` по изменённым файлам — 0 замечаний.
- На устройстве (ручная проверка): VPN включён, Ru internet segment включён,
  сервер Selectel (RU) — после теста `Via: direct-out`, Upload `n/a`, в
  истории `↑n/a`; Cloudflare — `Via: <узел>`, Upload в Мбит/с; Hostkey
  (Frankfurt) — Upload в Мбит/с, без `Failed`.
