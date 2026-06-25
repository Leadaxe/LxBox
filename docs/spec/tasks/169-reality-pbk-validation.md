# §169 — REALITY включать по валидному X25519, а не по «pbk непустой»

**Тип:** bug-fix (critical — одна нода роняет весь VPN)
**Статус:** In progress
**Связано:** парсер VLESS/Xray/sing-box JSON; референс ядра
`node_parser_transport.go:220-298` (sing-box-lx, launcher v1.1.7 had same bug)

## Симптом

Одна битая нода из публичной подписки роняет ВЕСЬ конфиг: sing-box при старте
падает с `invalid public_key`, VPN не поднимается вообще. Источник — кривые
публичные подписки (кейс «BLACK LISTS») вешают на обычную `security=tls` ноду
мусорный `pbk=enabled` / `pbk=true`.

## Корень

REALITY-блок строился по условию «pbk непустой», а не «pbk — валидный ключ».
Мусор уходил в `reality.public_key` как есть → sing-box проверяет ключ, видит
не-X25519, и отвергает весь `config.json` (не одну ноду).

Три места создания `RealitySpec`, все брали ключ `?? ''` без проверки:

| Место | Было | Канал |
|---|---|---|
| `transport.dart:95` | `if (pbk.isNotEmpty)` | VLESS share-URI (`pbk=`) — **основной** |
| `json_parsers.dart:164` | `security=='reality'`, `publicKey ?? ''` | Xray JSON |
| `json_parsers.dart:435` | `reality.enabled==true`, `public_key ?? ''` | sing-box JSON |

Валидатора ключа в проекте НЕ было (грепом не найден).

## Решение

**Валидатор** `isValidRealityPublicKey(pbk)` в `uri_utils.dart` (рядом с
`normalizeRealityShortId`): X25519 = ровно 32 байта. После `trim` строка должна
декодироваться `decodeBase64Safe` (уже есть, пробует base64url/std × pad/unpad)
ровно в **32 байта**. `enabled`(7)/`true`(4)/`PK`(2)/`""`(0) отсекаются длиной.
Проверка по декоду надёжнее счёта символов — ловит и не-base64, и неверную длину.

**Поведение при невалидном pbk — деградация в plain TLS, не выброс ноды**
(решение пользователя 2026-06-26, единообразно для всех трёх мест):
- `transport.dart`: `if (isValidRealityPublicKey(pbk))` — невалидный pbk
  проваливается ниже в существующие ветки (`sec=='reality'` → plain TLS;
  иначе → общий plain TLS). Нода остаётся рабочей TLS-нодой.
- `json_parsers.dart` (обе ветки): `reality:` гейтится тернарником
  `isValidRealityPublicKey(pbk) ? RealitySpec(...) : null` — `enabled`,
  `server_name`, `fingerprint`/`utls` сохраняются → plain TLS.

**Заодно (наводка п.5):** JSON-ветки не нормализовали `short_id` (брали
`.toLowerCase()` / `?? ''`). Теперь обе зовут `normalizeRealityShortId` — как
URI-путь. (sing-box декодит short_id как hex; мусор/пробелы ломали бы.)

## Тесты

`vless_test.dart`:
- `isValidRealityPublicKey`: валидный 32-байтный → true; `''`/`enabled`/`true`/
  `PK`/пробелы/`not_a_key` → false.
- **БОЕВОЙ:** `security=tls&pbk=enabled` → plain TLS, `reality==null`, нода жива.
- `security=reality&pbk=true` → деградация в plain TLS.
- контроль: валидный pbk → REALITY создаётся.
- существующие §115-тесты: `pbk=PK` заменён на валидный `_validPbk`
  (43-симв base64url), иначе с §169 они перестали бы давать REALITY.

`json_parsers_test.dart`:
- Xray reality + `publicKey=enabled` → plain TLS, `reality==null`.
- sing-box reality + `public_key=true` → plain TLS, `reality==null`.
- inline `'publicKey':'PK'` заменён на валидный; фикстуры (`AAAA…`×43 = 32
  нулевых байта) уже валидны — не трогали.

## Проверка на устройстве

Прогнать на той самой битой подписке («BLACK LISTS»): импорт без падения ядра,
VPN поднимается, битые ноды видны как обычные TLS (или исключены роутингом),
остальные ноды работают.

## Результат (device CE8XX48PCI79U4XG, 2026-06-26, vc 2817)

⚠️ ЧАСТИЧНО (regression-сторона зелёная; прямой битый-кейс — на боевой подписке).
- Юнит: 38 зелёных, парсер-сьют целиком 200 зелёных (боевой кейс
  `security=tls&pbk=enabled` → plain TLS покрыт в тесте).
- Device regression: текущий конфиг содержит **56 reality-блоков / 60
  public_key**; VPN поднялся (`tunnel_up:true`, 26 conns), ядро НЕ ругалось
  `invalid public_key` (logcat чист) → §169 не сломал валидные reality-ноды.
- TODO: прогнать на самой битой подписке («BLACK LISTS»), когда будет под рукой
  — подтвердить деградацию битой ноды в plain TLS на живом конфиге.
