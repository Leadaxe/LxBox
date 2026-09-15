# §281 — Неизвестный uTLS fingerprint роняет весь конфиг: нормализация вместо fatal

**Тип:** bug-fix
**Статус:** Реализовано
**Связано:** §169 (тот же паттерн: битое значение деградирует на входе, не
роняет конфиг), §172 (страховочный post-step перед `validateConfig`), §217
(XHTTP-параметры: одна нода не должна валить весь конфиг)

## Симптом

Подписка `goida-vpn-configs/githubmirror/1.txt` (9698 нод): импорт проходит,
но VPN не стартует вообще — ядро падает на `initialize outbound[N]: unknown
uTLS fingerprint: hellochrome_120`. Одной такой ноды достаточно, чтобы
убить все ~9600 остальных.

Фактура по этой подписке:
- `fp=hellochrome_120` — 8 REALITY-нод (xray-псевдоним, сырое имя
  uTLS-библиотеки);
- `fp=QQ` — 55 нод: на URI-пути уже лечится существующим `.toLowerCase()`,
  но JSON-пути (`_tlsFromSingbox` — as-is, xray-tls — без trim) дырявые;
- пустой `fp=` — безопасен (vless дефолтит в `random`, ядро принимает и
  пустую строку как chrome).

## Корень

Публичные подписки генерятся под Xray, который принимает сырые имена
uTLS-библиотеки (`hellochrome_120`, `hellofirefox_auto`, …) и любой регистр.
sing-box матчит fingerprint СТРОГО по словарю — `uTLSClientHelloID`
(`sing-box-lx/common/tls/utls_client.go:371`, case-sensitive switch):
`chrome` (+ `chrome_psk`/`chrome_psk_shuffle`/`chrome_padding_psk_shuffle`/
`chrome_pq`/`chrome_pq_psk` и пустая строка — всё схлопывается в
Chrome_Auto), `firefox`, `edge`, `safari`, `360`, `qq`, `ios`, `android`,
`random`, `randomized`. Неизвестное значение → ошибка при конструировании
outbound в `box.New` → fatal ВСЕГО конфига на старте (`stopAndAlert`).
hysteria2/tuic идут через тот же `tls.NewClient` — их fp валится так же.

В приложении значение `fp` нигде не валидировалось: парсеры делали только
`.toLowerCase().trim()` и дословно передавали в `tls.utls.fingerprint`
(`TlsSpec.toSingbox`).

## Решение (два слоя, как §246/§253)

Решения пользователя 2026-07-18: (а) неизвестный мусор → `chrome` + warning
(fingerprint — чисто клиентская маскировка, сервер про неё не знает, нода
почти наверняка рабочая; выкидывать = терять живой сервер); (б) известные
xray-псевдонимы (`hellochrome_*` и семейство, по префиксу) → канонизировать
МОЛЧА (синоним, не деградация; варнинг на 55 нодах — только шум).

### Слой 1 — нормализация в парсере

Новый модуль [utls_fingerprint.dart](../../../app/lib/services/parser/utls_fingerprint.dart):

- `kUtlsFingerprints` — зеркало словаря ядра (единственный список в Dart);
- `normalizeUtlsFingerprintValue(raw)` — trim + lowercase → словарь как есть
  → префикс-таблица псевдонимов (`hellochrome*`→`chrome`,
  `hellofirefox*`→`firefox`, `helloedge*`→`edge`, `hellosafari*`→`safari`,
  `hello360*`→`360`, `helloqq*`→`qq`, `helloios*`→`ios`,
  `helloandroid*`→`android`, `hellorandomized*`→`randomized`) → всё
  остальное = мусор → `chrome` + флаг `junk`;
- `normalizeTlsFingerprint(tls, warnings)` — обёртка над `TlsSpec`: при
  junk плюсует `UnknownFingerprintWarning` в аккумулятор ноды.

Вызывается во всех парсерах, создающих `TlsSpec.fingerprint`: vless,
trojan, vmess, anytls, proxy-https, hysteria2 (URI), `_xrayVlessToSpec`
(xray JSON, с warning'ом) и `_tlsFromSingbox` (raw sing-box JSON — молча:
у `parseSingboxEntry` нет warnings-аккумулятора, это power-user путь
JSON-редактора/Smart-Paste).

Ноды хранятся как `raw_body` и перепарсиваются при загрузке — существующие
подписки вылечиваются сами, миграция не нужна. Round-trip export отдаёт
уже нормализованное значение.

`fp=` пустой не трогаем: vless-дефолт `random` (до нормализации),
trojan/vmess/hy2 → null (без utls-блока) — существующее поведение.

### Слой 2 — страховочный post-step

`healUnknownUtlsFingerprints(config)` —
[heal_unknown_utls_fingerprints.dart](../../../app/lib/services/builder/post_steps/heal_unknown_utls_fingerprints.dart).
Зовётся в `buildConfig` после остальных лечилок, ПЕРЕД `validateConfig`.
Проходит `outbounds[].tls.utls.fingerprint`: псевдонимы канонизирует молча,
мусор → `chrome` + запись `(owner, original)` → строка в `emitWarnings`
(AppLog). Ловит пути мимо парсера (vars-подстановки, будущие источники).

### Warning (§280-совместимо)

`UnknownFingerprintWarning(value)` — sealed-подкласс `NodeWarning`,
severity warning, ARB-ключ `warnUnknownFingerprint` (en+ru), рендер в
момент показа. В `emitWarnings`/AppLog уходит через существующий
`renderEn()`-конвейер build_config.

## Находки adversarial-ревью (закрыты в этом же изменении)

1. **REALITY + пустой/пробельный fingerprint** (JSON-пути): ядро требует
   uTLS-блок при reality («uTLS is required by reality client» — тот же
   fatal-класс), а `TlsSpec.toSingbox` не эмитит `utls` при пустом
   fingerprint. Фикс в обоих слоях: `normalizeTlsFingerprint` при пустом
   значении и `reality != null` подставляет `chrome`; post-step
   восстанавливает минимальный `utls`-блок у reality-outbound'ов без него
   (и чинит `utls.enabled=false`).
2. **naive из raw sing-box JSON** проносил полный TLS-блок
   (alpn/utls/insecure/reality) — ядро отклоняет всё это при создании
   naive-outbound (fatal всего конфига). Фикс: `_naiveTlsFromSingbox`
   срезает до enabled/server_name (зеркало naive_parser).
3. Отдельно (не config-fatal): uTLS поверх QUIC (hysteria2/tuic) в ядре
   не работает вообще (`STDConfig()` → «unsupported usage for uTLS») —
   нода с fingerprint мертва per-connection. Аудит ядра
   `SPECS/027-UTLS_OVER_QUIC`: настоящий фикс недостижим/отложен, предписано
   лечить app-side (прекратить эмиссию `fp` для hy2/tuic). Реализовано в
   §282 (срез utls-блока в emitHysteria2/emitTuic).

## Что НЕ делает

- Не выбрасывает ноду — она остаётся рабочей с `chrome`.
- Не трогает валидные значения словаря (включая `chrome_psk`-варианты).
- Не добавляет UI-выбор fingerprint (его в приложении нет).
- Не трогает masque `ib` (chrome/firefox в WARP wizard — другой параметр).

## Тесты

`test/parser/utls_fingerprint_test.dart` — чистая функция (словарь, регистр,
префикс-псевдонимы, мусор, пустая строка) + сквозные через `parseUri`
(vless REALITY `hellochrome_120` → chrome без warning, `QQ` → qq, мусор →
chrome + `UnknownFingerprintWarning`, trojan/vmess/anytls/hy2/proxy-https,
xray JSON, raw sing-box JSON) + round-trip emit.

`test/builder/heal_unknown_utls_fingerprints_test.dart` — мусор → chrome +
запись; псевдоним → молча; валидные/без-tls → no-op; пробельный fp → снят.

## Дополнение 2026-09-13 — REALITY принимает только chrome-семейство (ядро SPEC 083)

> **Пересмотрено в [§444](444-reality-fingerprint-no-override.md) (2.24.0, D-119 лаунчера):** подмена явного отпечатка на `chrome` на сборке снята — отпечаток узла из подписки уходит в конфиг как есть. `chrome` пишется только вместо пустого и `random`; предупреждение осталось, текст советует `chrome`.

**Симптом.** Все REALITY-узлы за Xray-core ≥ v26.9.8 умирают без ошибки:
сервер (`XTLS/REALITY@8cdf7bf`) требует в ClientHello key_share
`X25519MLKEM768` **перед** X25519, иначе молча проксирует соединение на
камуфляжный сайт; на клиенте — `reality verification failed`. Ядро lx.36 сняло
свой фильтр этого шара, но дальше всё решает отпечаток: из словаря ядра гибрид
несёт только `HelloChrome_133` (все шесть `chrome*`-имён). `firefox`/`edge`/
`safari`/`ios`/`android`/`360`/`qq` шлют голый X25519, `random` — один из пяти
(живой только Chrome), `randomized` — гибрид монетой ½. Это паритет с клиентом
самого Xray. Разбор и стенд — `sing-box-lx/SPECS/TASKS/083`.

**Решение (два слоя, как выше).**

- *Парсер* — `normalizeTlsFingerprint`: при `reality != null` и
  канонизированном значении не из `kChromeFamilyFingerprints` плюсует
  `RealityFingerprintWarning(value)` (severity warning). Значение ноды **не
  меняется**: `entry` — нормативная часть контракта с лаунчером
  (`contract/corpus/uri/vless/grpc_reality_no_flow` ожидает `firefox`), а
  подменять его в одном приложении = расхождение контракта. `random` без
  предупреждения: это дефолт URI-парсера при пустом `fp` (transport.dart), от
  явного `fp=random` он неотличим, шум на каждом REALITY-узле без `fp` не нужен.
- *Post-step* — `healUnknownUtlsFingerprints`: у outbound'а с
  `reality.enabled == true` отпечаток не из chrome-семейства (включая дефолтный
  `random`) → `chrome`, **молча** (без записи в `emitWarnings`: пользователю
  уже сказано на ноде при импорте, а дефолтный `random` — не его выбор). Конфиг
  ядра не входит в контракт — это единственное место, где подмена легальна и
  при этом накрывает все пути (парсер, raw JSON, vars).

**Контракт.** `RealityFingerprintWarning` в `_warningCodes` контрактного
раннера не занесён — кода в `registry/warnings.json` пока нет, класс без кода
раннер в конверт не пишет (contract_test.dart, `code == null` → пропуск).
Регистрация кода и зеркальное предупреждение у лаунчера — отдельное решение
владельца (IDENTITY §4a, класс A); до него поведение приложений по `entry`
совпадает, расходится только наш конфиг ядра.

**Тесты.** `utls_fingerprint_test.dart` (группа «SPEC 083»): firefox →
warning + значение цело, псевдоним `hellofirefox_auto` → то же, chrome-семейство
и дефолт → тихо, plain TLS + firefox → тихо, raw JSON без аккумулятора.
`heal_unknown_utls_fingerprints_test.dart`: firefox/random/randomized/мусор под
REALITY → `chrome` (запись только про мусор); chrome-семейство и TLS-без-REALITY
→ no-op; `reality.enabled=false` → no-op. `node_warning_test.dart`: равенство и
`renderEn`.

**Что НЕ делает.** Не меняет дефолт `random` в парсере (контракт); не вводит
UI-выбор отпечатка; не трогает hysteria2/tuic (там utls/reality срезаны §282).
