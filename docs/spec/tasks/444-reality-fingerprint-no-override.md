# 444 — REALITY: отпечаток узла из подписки не подменяется на сборке

| Поле | Значение |
|------|----------|
| Статус | Done (к v2.24.0). Device-verify не проводился (решение владельца): меняется одно значение в конфиге, путь покрыт тестом полной сборки |
| Дата | 2026-09-15 |
| Коммиты | `chore(contract)` 21671497, 652ff445 — синк на контракт 1.0.3 (лаунчер 87224fcb); `fix(444)` 39e780a4 — post-step, текст предупреждения; `test(444)` 6a175492; `docs(444)` — эта таска, GUARDS, KERNEL, CHANGELOG, заметки |
| Норма | D-119 лаунчера (заменяет D-104), контракт 1.0.3: `registry/tls.json` note, `registry/warnings.json` `reality_fp_not_chrome`, кейс `uri/vless/reality_fp_firefox_kept` |
| Связанные | [§281](281-utls-fingerprint-normalize.md) (нормализация uTLS, дополнение SPEC 083), [§433](433-reality-fp-not-chrome-naive-extra-headers-codes.md) (код `reality_fp_not_chrome`, D-104), ядро SPEC 083 |

## Отчёт

У провайдера в ссылках `fp=firefox`. 2.23.2 на сборке конфига подменяла у
REALITY-узлов отпечаток не из chrome-семейства на `chrome` (коммит `f68fd307`,
§281, D-104), и соединение с частью серверов не устанавливалось (мобильная
сеть). На 2.23.1, где подмены не было, те же узлы работали.

## Причина

Подмена переписывала выбор источника узла. Отпечаток задаёт подписка, и
приложение выполняет то, что она велит. Основание D-104 (REALITY-сервер Xray
≥ v26.9.8 требует key_share `X25519MLKEM768`, который несут только
chrome-спеки) остаётся верным как подсказка пользователю, но не как повод
менять значение без его ведома.

## Новая норма

| Вход под REALITY | 2.23.2 | 2.24.0 |
|---|---|---|
| явный отпечаток из словаря не из chrome-семейства (`firefox`, `safari`, `randomized`, `qq`…) | в конфиг `chrome`, предупреждение «используется chrome» | в конфиг как есть, предупреждение советует `chrome` |
| chrome-семейство | как есть | как есть |
| отпечаток отсутствует или пустой | `chrome` явно | `chrome` явно |
| `random` (дефолт парсера или явный) | `chrome` | `chrome`, без предупреждения |
| мусор вне словаря ядра | `chrome` + `UnknownFingerprintWarning` | без изменений (§281) |
| uTLS-блок отсутствует или выключен | включается | включается |

Текст предупреждения:

- EN: `REALITY with uTLS fingerprint "%s": Xray servers since v26.9.8 reject this ClientHello. If the connection fails, try "chrome".`
- RU: `REALITY с uTLS fingerprint «%s»: серверы Xray начиная с v26.9.8 отвергают такой ClientHello. Если соединение не устанавливается, попробуйте «chrome».`

Старая строка удалена из `assets/l10n/ru/ui.json`.

### Явный и неявный `random`

Модель их не различает. `parseVlessTls` (`transport.dart`, vless и anytls) и
`_xrayTlsFromStream` (`json_parsers.dart`) подставляют `random` вместо пустого
`fp` до создания `TlsSpec`, а `TlsSpec.fingerprint` — просто строка. `entry`
по D-009 обязан хранить `random` (кейс корпуса `reality_valid_pbk_sid`), так
что поднять дефолт до `chrome` в парсере нельзя, а флаг происхождения до
post-step, работающего над JSON конфига, не доходит.

Решено как у лаунчера (`EnforceRealityFingerprint`): на сборке любой `random`
под REALITY становится `chrome`, предупреждения на `random` нет. Явный
`fp=random` тоже уходит `chrome` — это единственный случай, где значение
источника меняется, и он совпадает у обеих сторон.

## Что сделано

| Место | Было | Стало |
|---|---|---|
| `post_steps/heal_unknown_utls_fingerprints.dart` | под `reality.enabled` всё вне chrome-семейства → `chrome` | `chrome` только вместо отсутствующего, пустого и `random` |
| `models/node_warning.dart` `RealityFingerprintWarning` | «…so "chrome" is used when connecting» | мягкий текст выше |
| `parser/utls_fingerprint.dart` | комментарий о подмене на выходе | комментарий о норме §444; логика предупреждения прежняя (не chrome-семейство, кроме `random`) |
| вкладка «Replacements» узла | — | не менялась: показывает только следы import-rules (`NodeSpec.ruleTrail`, §302), post-step в неё никогда не писал; строка `tls.utls.fingerprint: firefox → chrome` там возможна только от пользовательского правила |
| диагностика узла | — | отпечаток не показывает; конфиг для неё собирается тем же post-step |

## Проверка

- `test/builder/reality_fingerprint_build_test.dart` — полная сборка из ссылки:
  REALITY + `firefox` → `firefox` и предупреждение; пустой fp (sing-box JSON)
  → `chrome`; vless без `fp` и с `fp=` → `chrome` при `entry` `random`; явный
  `random` → `chrome`; `randomized` → как есть с предупреждением; TLS без
  REALITY + `firefox` → `firefox`; мусор → `chrome` + `UnknownFingerprintWarning`.
- `heal_unknown_utls_fingerprints_test.dart`, `node_warning_test.dart`,
  `utls_fingerprint_test.dart` — под новую норму.
- Корпус контракта 1.0.3: `reality_fp_firefox_kept`, `grpc_reality_no_flow`,
  `reality_tcp_no_flow` (entry `firefox`, код `reality_fp_not_chrome`).
- Golden `test/fixtures/storage/golden/*.config.json` не меняются: единственный
  REALITY-узел фикстур (`rich_v0`, «VLESS Reality») задан с `fp=chrome`.
- Полный `flutter test` и эмулятор не гонялись (решение владельца). Прогнаны
  `flutter analyze` (0), все тест-файлы с `fingerprint`/`reality`/`utls` плюс
  `golden_config_test` — 1019 passed, 8 skipped (корпус hysteria v1, схема
  лаунчера), 0 failed; пять чекеров `--strict` зелёные.
