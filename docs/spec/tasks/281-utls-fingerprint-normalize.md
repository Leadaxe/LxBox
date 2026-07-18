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
3. Отдельной задачей (не config-fatal): uTLS поверх QUIC (hysteria2/tuic)
   в ядре не работает вообще (`STDConfig()` → «unsupported usage for
   uTLS») — нода с fingerprint мертва per-connection; правильное лечение —
   не эмитить utls для QUIC-протоколов.

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
