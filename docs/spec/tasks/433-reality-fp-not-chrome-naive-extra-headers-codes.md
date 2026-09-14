# 433 — Контракт 0.12.10: коды `reality_fp_not_chrome` и `naive_extra_headers_invalid`, явный `chrome` под REALITY

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-13 |
| Дата завершения | 2026-09-13 |
| Коммиты | `feat(433)` код + тесты + спека + CHANGELOG |
| Триггер | `app/contract/TASKS_LXBOX.md` §14 (контракт 0.12.10, решения D-104 и D-105 лаунчера; коммит singbox-launcher/develop 15306458) |
| Связанные | [§281](281-utls-fingerprint-normalize.md) (нормализация uTLS, chrome-семейство), [§343](343-reality-short-id.md) (REALITY short_id), ядро SPEC 083 (REALITY против Xray ≥ v26.9.8), [docs/PROTOCOLS.md](../../PROTOCOLS.md) |

## Что и почему

Контракт с лаунчером завёл два кода в `registry/warnings.json`, у обоих поле
`dart` уже указывало на наши классы. Правило REALITY у нас существовало с §281:
парсер ставит `RealityFingerprintWarning` на отпечаток не из chrome-семейства,
post-step сборки подменяет отпечаток на `chrome`, значение узла (`entry`) не
трогается. Лаунчер догнал это на том же слое сборки и описал как D-104. Наша
сторона должна была только привязать класс к коду в раннере корпуса.

Второй код встречный: отброшенная пара naive `extra-headers` у нас была
только в логе. Заголовок из `extra-headers` часто и есть то, чем открывают
доступ на сервере, и его молчаливая пропажа выглядела для пользователя как
отказ узла без причины. D-105: код `naive_extra_headers_invalid`, severity
`info`, вешается на узел один раз при первой отброшенной паре.

## Что сделано

| Пункт §14 | Было | Стало |
|---|---|---|
| Привязка `RealityFingerprintWarning` ↔ `reality_fp_not_chrome` | класса в карте раннера не было, код в корпусе не сверялся | `test/contract/contract_test.dart` `_warningCodes` |
| `NaiveExtraHeadersInvalidWarning` ↔ `naive_extra_headers_invalid` | класса не было, drop только в `AppLog` | класс в `node_warning.dart` (info, параметр `entry` = пара как пришла), `parseNaiveExtraHeaders` принимает аккумулятор и пишет warning один раз на узел; http/https-парсер зовёт helper без аккумулятора, его `headers` под код не попадает (так в реестре) |
| Пустой fp под REALITY | post-step писал `chrome` только поверх непустого не-chrome значения; отсутствующий или пустой fingerprint оставался на дефолте ядра | `healUnknownUtlsFingerprints` пишет `chrome` ЯВНО и для отсутствующего/пустого fingerprint под `reality.enabled` |
| Корпус | — | `contract/` синхронизирован на 15306458 (0.12.10); кейсы `reality_fp_firefox_forced_chrome` (новый), `grpc_reality_no_flow`, `reality_tcp_no_flow`, `allowinsecure_lowercase_zero`, `ech_ignored_reality_kept`, `naive/extra_headers_bad_name_dropped` проходят |

## Ответ на вопрос §14 п. 1 (пустой fp при reality)

Пустой fp у vless практически недостижим: `parseVlessTls` подставляет `random`
до `normalizeTlsFingerprint`, и в `entry` остаётся `random` (D-009 лаунчера,
под код не попадает). У anytls и остальных путей через `normalizeTlsFingerprint`
пустое значение при reality становится `chrome` уже в парсере. На сборке
post-step теперь пишет `chrome` явно для любого не-chrome, пустого или
отсутствующего fingerprint под REALITY, так что дефолт ядра нигде не
используется. Это и есть подтверждение, которое просил лаунчер.

## Проверка

- `flutter test`: раннер корпуса, `uri_naive_test`, `heal_unknown_utls_fingerprints_test`, `node_warning_test` (исчерпывающий switch), `registry_sync_test`.
- `dart run tool/l10n/ui_check.dart --strict`: новая строка переведена в `assets/l10n/ru/ui.json`.
- Device-verify не требуется: меняется только видимость деградации на узле и один явный ключ в конфиге, значение которого ядро и так подразумевало.
