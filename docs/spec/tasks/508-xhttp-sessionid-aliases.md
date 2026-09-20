# 508 — XHTTP extra: алиасы `sessionIDPlacement` / `sessionIDKey`

| | |
|---|---|
| **Статус** | Done |
| **Дата** | 2026-09-20 |
| **Повод** | Живая vless+xhttp ссылка: extra несёт proto-имена Xray, session id не доезжал |
| **Связанные** | [§410](410-xhttp-extra-empty-not-clobber.md), [лаунчер #131](https://github.com/Leadaxe/singbox-launcher/issues/131) |

## Docs to update

- эта задача
- [§410](410-xhttp-extra-empty-not-clobber.md) — пункт «вне задачи» про sessionID*
- [docs/PROTOCOLS.md](../../PROTOCOLS.md) — алиасы proto-имён в extra
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Fixed

## Проблема

Ссылка разбирается, extra читается, `seqPlacement` доезжает. `sessionIDPlacement: cookie` и `sessionIDKey: stream_auth` — нет. Ядро кладёт session id в path (дефолт). Сервер ищет cookie с кастомным ключом.

Это не «не парсится»: узел есть. Молчаливая потеря двух ключей. Значения не дефолт дампа (`path` / `x_session`).

Реестр смотрит только `sessionPlacement` / `sessionKey`. Ядро (`option/v2ray_xhttp.go`) уже говорит: proto — `sessionIDPlacement`, JSON — `session_placement`.

## Решение

Оверлей `app/assets/contract_draft/uri/transports.json` на записи `sessionPlacement` и `sessionKey` (диалекты `uri` и `xray`): в `source` добавлены `sessionIDPlacement` / `sessionIDKey` в extra и в плоском query, после канона. Движок не трогали.

`sessionIDLength` / `sessionIDTable` не маппить: `"0"` без таблицы — «не задано».

Снять оверлей, когда алиасы приедут в реестр ([#131](https://github.com/Leadaxe/singbox-launcher/issues/131)).

## Тесты

`test/parser/xhttp_test.dart`: ссылка §410 (cumirum) теперь ждёт `session_placement=cookie` / `session_key=media_sid`; Xray extra-объект; канон extra сильнее proto-имени; плоский `query.sessionIDPlacement`.
