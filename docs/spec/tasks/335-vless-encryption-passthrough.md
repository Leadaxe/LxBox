# 335 — VLESS `encryption`: перенос из подписки в конфиг

## Проблема

Узлы VLESS с постквантовым слоем шифрования (`mlkem768x25519plus`) не
подключаются: приложение теряет поле `encryption` на входе, и в конфиг ядра
уезжает голый VLESS. Сервер ждёт слой шифрования внутри VLESS, клиент его не
шлёт — соединение молча не встаёт, в логах ни ошибки, ни статуса.

Наблюдается на подписках, где провайдер включил этот слой: поле несут все
VLESS-узлы без TLS, независимо от транспорта (ws, grpc, raw/tcp), и ни один
из них не проходит тест пинга.

## Что уже готово

Ядро (`sing-box-lx` SPEC 032) поле поддерживает целиком:

- `option/vless.go:26` — `Encryption string \`json:"encryption,omitempty"\``
  в `VLESSOutboundOptions`, плоским полем верхнего уровня рядом с `uuid`
- `protocol/vless/encryption/client.go` — реализация на `crypto/mlkem`
- схема принимает, `check` валидирует, битую строку ядро отвергает само
  с указанием сегмента

Со стороны приложения поддержки нет вовсе: слово `encryption` не встречается
в `app/lib/` ни разу.

## Формат значения

Спек-строка ядра:

```
mlkem768x25519plus.<native|xorpub|random>.<0rtt|1rtt>[.<padding>].<key>…
```

Ключ — base64url, в наблюдаемых подписках до ~1600 символов. Значение
переносится **как есть**: не обрезать, не перекодировать, регистр не менять,
не валидировать.

## Откуда брать

### 1. URI `vless://` — основной путь

Такие подписки обычно приходят base64-списком URI (`text/plain`, строка на
узел), а не Xray-JSON. `encryption` лежит query-параметром:

```
vless://<uuid>@host:port?encryption=mlkem768x25519plus.native.0rtt.<key>&type=ws&path=/ws&security=none
```

Файл: `app/lib/services/parser/uri_parsers/vless_parser.dart` — рядом с
чтением `flow` (строка 28).

Замечание: у таких узлов `security=none`, то есть TLS нет. Слой шифрования
VLESS работает **вместо** TLS, а не поверх — узлы попадают в группу «noTLS»,
и отсутствие TLS для них нормально.

### 2. Xray-JSON — второй путь

```
outbounds[].settings.vnext[0].users[0].encryption
```

рядом с `id` (читается как `uuid`) и `flow`.

Файл: `app/lib/services/parser/json_parsers.dart:418-419` — сейчас из
`users.first` берутся только `id` и `flow`.

## Куда класть

В VLESS-аутбаунд, плоским полем верхнего уровня. Обратить внимание на смену
уровня вложенности: в подписке поле внутри `users[0]`, в конфиге ядра — рядом
с `uuid`.

```json
{
  "type": "vless",
  "server": "144.31.187.123",
  "server_port": 1080,
  "uuid": "…",
  "encryption": "mlkem768x25519plus.native.0rtt.<key>",
  "transport": { "type": "ws", "path": "/ws" }
}
```

## Правила

- Эмитить **только** если значение непустое и не равно `none`. Иначе поле не
  добавлять вовсе — обычные узлы не должны измениться ни на байт.
- Значение переносить без нормализации.
- Валидацию не делать — ядро отвергнет битую строку на `check`/старте.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/node_spec.dart` | `VlessSpec`: поле `final String encryption`, в конструкторе `this.encryption = ''` (рядом с `flow`, строки 181/194) |
| `app/lib/services/parser/uri_parsers/vless_parser.dart` | прочитать `q['encryption']`, передать в `VlessSpec(...)` (строка 55+) |
| `app/lib/services/parser/json_parsers.dart` | прочитать `user['encryption']`, передать в `VlessSpec(...)` |
| `app/lib/models/node_spec_emit.dart` | `emitVless`: `if (s.encryption.isNotEmpty && s.encryption != 'none') out['encryption'] = s.encryption;` |
| `app/lib/models/node_spec_emit.dart` | `toUriVless`: вернуть параметр в share-URI, теми же условиями — иначе поле теряется на round-trip |

### Про `toUriVless`

Обязательная часть, а не опциональная: §302-правила и ручное редактирование
ходят через эмит-URI, и без обратной записи `encryption` пропадёт при первом
же round-trip — узел снова станет мёртвым, но уже без внешней причины.

## Тесты

- `test/parser/` — URI с `encryption` → поле в `VlessSpec`; URI без него →
  пустая строка
- `test/parser/` — Xray-JSON с `users[0].encryption` → поле в `VlessSpec`
- `test/builder/` — эмит с непустым `encryption` → поле в аутбаунде;
  пустое/`none` → ключа в JSON нет вовсе
- round-trip: `parse(uri) → toUri()` сохраняет значение посимвольно
  (длинный ключ ~1600 символов, проверить, что не режется)

## Проверка на устройстве

Нужна подписка с включённым слоем шифрования. До правки такие узлы не
проходят тест пинга — все, сколько бы их ни было. Ожидание после: отвечают,
причём вся VLESS-группа без TLS оживает целиком, транспорт роли не играет
(слой шифрования у них общий).

Учесть при интерпретации: в тех же подписках узлы других протоколов
(Hysteria2, shadowsocks) VLESS-слоя не имеют и остаются мёртвыми по своим
причинам — их эта таска не касается.
