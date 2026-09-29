[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 016 — DPI_HARDENING — обход DPI и защитные настройки TLS-транспорта

| Поле | Значение |
|------|----------|
| Тип | Продуктовая фича |
| Поглотила | `§020F` (security & DPI bypass — жива только часть про фрагментацию; Clash API из неё снят вместе с `clash_api`), `§028F` (mixed-case SNI), `§045F` (ECH — Draft не реализован как задуман: вместо переключателя на узле — сквозной `tls.ech` из JSON и отказ от `ech=` ссылки), `§127F` (полный набор XHTTP-параметров ссылки) |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Назначение

Отвечает за то, как ClientHello и транспорт узла выглядят на проводе и
как проверяется сервер. Пользователь включает глобальные приёмы одной
галкой; всё, что пришло из подписки (отпечаток, REALITY, XHTTP, `flow`,
фрагментация провайдера), доезжает до ядра в форме, которую ядро примет.

Принципы, которые фича защищает:

- **Одна битая маскировка не роняет весь VPN.** Ядро отвергает
  неизвестный отпечаток, нечётный `short_id`, не-X25519 ключ, недопустимый
  режим XHTTP фаталом на весь конфиг; здесь такое значение отбрасывается
  или заменяется на узле с предупреждением, остальное работает.
- **Приём против DPI — только там, где DPI его видит.** Глобальные
  приёмы применяются к первому хопу; под `detour` фрагментацию решает
  ядро, и узловой `tls.fragment` снимается, чтобы ему не мешать.
- **Не подменять выбор провайдера молча.** Отпечаток, `flow`, `ech`,
  `encryption` из подписки проходят как есть, снимаются с кодом или
  отбраковывают узел — тихого понижения защиты нет.

Из коробки: глобальные приёмы выключены, пауза `500ms`, хранилище CA `system`.

## Обещания

- **P1. Глобальная фрагментация — только первый хоп.** «TLS Fragment» →
  `tls.fragment: true`, «TLS Record Fragment» → `tls.record_fragment: true`
  и `fragment_fallback_delay` у outbound'ов с включённым TLS и без `detour`;
  узлы с `detour` не трогаются. Свидетель: юнит «tls_fragment=true
  fragments first-hop TLS only». Мутация: снять проверку `detour`.
- **P2. Фрагментация не роняет старт.** naive и MASQUE на `h3` флагов
  не получают; MASQUE на `h2`/auto получает (с новым `tls{}`). Свидетель: юниты
  «§270 — tls_fragment пропускает naive», «h3 пропускается молча — блок
  tls не создаётся», «h2 получает fragment во вложенном tls{}». Мутация:
  писать флаги в любой `tls`.
- **P3. `tls.fragment` уступает `detour` сборки.** Узловой флаг
  (из подписки или JSON) под `detour`, назначенным сборкой, снимается с
  кодом `detour_with_tls_fragment` вместе с осиротевшей паузой;
  `record_fragment` остаётся; у авторского JSON-тела флаг не снимается,
  код с пометкой «не применено». Свидетель: юниты «явный record_fragment
  под detour остаётся, fragment снят», «только record_fragment под detour
  — тело не трогается», «при record_fragment пауза остаётся». Мутация:
  не снимать флаг — пауза 500 мс на сегмент и выключенный дефолт ядра.
- **P4. Фрагментация провайдера Xray переносится.** `dialerProxy` на
  `freedom` с `fragment` и `finalmask.tcp[type=fragment]` → `tls.fragment:
  true`, если TLS включён и хопа нет; параметры Xray отбрасываются без
  кода. Свидетель: юниты «TLS + fragment freedom → прямой узел,
  tls.fragment, без кода», «finalmask_tcp_fragment: xhttp + REALITY →
  tls.fragment», «…_no_tls: флага нет», «…_with_hop: флага нет».
  Мутация: ставить флаг и без TLS.
- **P5. Mixed-case SNI — случайный регистр, та же строка.** При
  включённой галке `server_name` каждого first-hop outbound'а получает
  свою случайную смесь регистров, равную исходной без учёта регистра;
  IP-литералы и метки `xn--` не меняются; `detour`-узлы не трогаются.
  Свидетель: юниты «case-insensitively equal to original», «punycode
  label preserved», «detour outbound NOT touched», «two outbounds get
  independent randomization». Мутация: один ГСЧ-результат на все узлы.
- **P6. Mixed-case SNI не касается REALITY.** Узел с
  `tls.reality.enabled: true` сохраняет SNI байт в байт; сосед без
  REALITY рандомизируется. Свидетель: юниты «reality outbound NOT
  touched», «gate is per-outbound». Мутация: убрать гейт — узел REALITY
  молча уходит на камуфляжный сайт.
- **P7. Отпечаток uTLS всегда из словаря ядра.** Xray-псевдонимы
  (`hellochrome_120`, …) и регистр канонизируются молча; мусор → `chrome`
  с `utls_fp_unknown`; на QUIC `utls`/`reality` снимаются. Свидетель: юниты «REALITY + fp=hellochrome_120 → chrome,
  МОЛЧА», «мусор → chrome + utls_fp_unknown (TLS и REALITY)», «hysteria2
  URI с fp → emit-конфиг БЕЗ utls». Мутация: пропустить сырое значение.
- **P8. Отпечаток под REALITY не подменяется, но предупреждается.**
  `edge`/`ios`/`android`/`360`/`qq`/`randomized` уходят как есть с кодом
  `reality_fp_not_chrome`; `chrome*`, `firefox`, `safari` — без кода;
  неявный `random` у vless-REALITY → `chrome` с кодом
  `reality_fp_random_pinned`. Свидетель: юниты «REALITY + fp=edge/…/qq →
  предупреждение на узле», «REALITY + fp=firefox/safari → как есть, без
  предупреждения», «vless REALITY без fp и с fp= → chrome с кодом».
  Мутация: переписать `edge` в `chrome`.
- **P9. Битый REALITY деградирует, а не валит конфиг.** Невалидный
  `public_key` (не 32 байта) → узел идёт обычным TLS; `short_id`
  нечётный, длиннее 16 или не строка → пустой; `key_share` вне
  `hybrid`/`classical` → снят. Свидетель: юниты «БОЕВОЙ КЕЙС: security=tls
  + pbk=enabled → plain TLS», «нечётный short_id → очищен, нода и конфиг
  живы», «key_share вне enum — поле отброшено молча, узел жив». Мутация:
  обрезать `short_id` до 16.
- **P10. ECH из ссылки не включается никогда.** `ech=` → код
  `ech_ignored`, `tls.ech` нет; `echfq` не читается; `tls.ech{}` из
  sing-box JSON проходит как есть. Свидетель:
  юниты «name+resolver → ech-блока нет, warning есть», «sing-box JSON:
  tls.ech{} доезжает до эмита, URI-ветка — нет», «toUri не изобретает
  ech». Мутация: мапить `ech=` в `tls.ech.enabled`.
- **P11. XHTTP: три входа — один набор полей.** Ссылка, Xray-JSON и
  sing-box-JSON читают один и тот же набор ключей (camelCase и
  snake_case), `extra` вливается, `xmux` вложенным объектом эквивалентен
  плоским ключам. Свидетель: юниты «три ветки читают один и тот же набор
  ключей», «extra={"xmux":{…}} эквивалентен плоским ключам», «golden: все
  15 полей camelCase → snake_case transport». Мутация: новое поле только
  в URI-ветке.
- **P12. XHTTP: `extra` не ломает рабочие плоские параметры.** Битый
  `extra` игнорируется; пустое значение в `extra` не перекрывает
  плоское; `host`/`path`/`mode` из `extra` не читаются. Свидетель: юниты
  «битый extra игнорируется», «пустое значение в extra не перекрывает
  плоское поле (§410)», «extra.host/path/mode не перекрывают плоские».
  Мутация: extra-first для `path`.
- **P13. XHTTP: недопустимая пара режима не доходит до ядра.** Значения
  вне enum (`mode`, placement'ы, `x_padding_method`) снимаются с
  `xhttp_param_reset`; header/cookie-placement без `mode` → `mode:
  packet-up` с `xhttp_mode_forced_packet_up`; при явном другом `mode` —
  placement снят. Свидетель: юниты «mode: мусор снят + xhttp_param_reset»,
  «JSON: header/cookie без mode → mode: packet-up + код», «header/cookie +
  mode=stream-one → placement снят, mode цел». Мутация: эмитить пару как
  есть.
- **P14. VLESS `flow` — только по ссылке и только без транспорта.**
  `flow` не навязывается; `xtls-rprx-vision` при транспорте снимается с
  `vision_with_transport`, кроме узла с `encryption`; `none`/устаревшие
  значения не эмитятся. Свидетель: юниты «bare TCP + REALITY, без flow →
  flow не эмитится», «XHTTP + REALITY, flow=vision → flow гасится»,
  «vision + xhttp + encryption → flow остаётся (§544)». Мутация: дефолт
  `vision` для REALITY.
- **P15. VLESS `encryption`: негодная форма отбраковывает узел.**
  Годное значение едет дословно (края обрезаны); пусто и точное `none` —
  слоя нет; иной регистр `None` и битая грамматика → узел не попадает в
  список с кодом. Свидетель: юниты «негодная форма отбраковывает УЗЕЛ, а
  не снимает поле», «None другого регистра — НЕ выключатель». Мутация:
  снять поле и оставить узел — тихое понижение защиты.
- **P16. Проверка сервера не ослабляется молча.** `insecure` из ссылки
  сохраняется, но помечается кодом `tls_insecure`; `pinSHA256`
  hysteria(2) → `tls.certificate_public_key_sha256`; свой CA
  (`tls.certificate`) переживает правку узла. Свидетель: юниты «insecure даёт код реестра с
  путём и значением» (anytls), «pinSHA256 доезжает до тела (на QUIC он
  валиден)», «certificate строкой переживает round-trip строкой».
  Мутация: терять `pinSHA256` на разборе.
- **P17. Хранилище корневых CA выбирает пользователь.** «Certificate
  store» → `certificate.store`. Ручная проверка: `mozilla` → в итоговом
  конфиге `"certificate": {"store": "mozilla"}`. `без свидетеля` (юнита нет).

## Контролируемые параметры

Пользовательские (раздел настроек «TLS Fragmentation» и «Certificate store»):

| Настройка | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| TLS Fragment | вкл/выкл | выкл | `tls.fragment` first-hop'ов |
| TLS Record Fragment | вкл/выкл | выкл | `tls.record_fragment` first-hop'ов |
| Fallback delay | duration-строка | `500ms` | `tls.fragment_fallback_delay` |
| Mixed-case SNI | вкл/выкл | выкл | `tls.server_name` first-hop'ов без REALITY |
| Certificate store | `system` · `mozilla` · `chrome` | `system` | `certificate.store` |

Ключи узла (контракт с ядром): `tls.utls.fingerprint`,
`tls.reality.{public_key,short_id,key_share}`, `tls.ech{}`, `tls.insecure`,
`tls.certificate*`, `transport` `xhttp` (с `xmux{}`), VLESS `flow`,
`packet_encoding`, `encryption`. Параметры ссылок: `fp`, `pbk`, `sid`,
`key_share`, `ech`, `pinSHA256`, `insecure`, `flow`, `encryption`,
`type=xhttp|splithttp` с `extra`.

## Входы / Выходы

**Входы:** глобальные галки; ссылки и JSON узлов; версия ядра
(фрагментация REALITY и `key_share` — с `v1.14.1-lx.4`).
**Выходы:** поля `tls`/`transport`/`flow`/`encryption` в outbound'ах;
коды на узлах (`utls_fp_unknown`, `reality_fp_not_chrome`,
`reality_fp_random_pinned`, `reality_short_id_invalid`, `ech_ignored`,
`xhttp_param_reset`, `xhttp_mode_forced_packet_up`,
`vision_with_transport`, `detour_with_tls_fragment`, `tls_insecure`,
`tls_fragment_system_engine`); строки предупреждений сборки
(«Fingerprint replaced…», «REALITY short_id cleared…», «REALITY
removed…»).

## Data flow

```
ссылка / Xray / sing-box JSON
   ▼  разбор: отпечаток, REALITY-гейт, ech= → код, XHTTP + extra, flow/encryption
модель узла ─► тело узла (санитайзер реестра: enum'ы, связи, запреты)
   ▼
сборка: detour проставлен → уступки detour (tls.fragment снят)
   ▼
глобальные приёмы: фрагментация first-hop → mixed-case SNI (кроме REALITY)
   ▼
страховки: неизвестный отпечаток → chrome; битый REALITY → sid пуст / блок снят
   ▼
ядро (под detour само включает record_fragment, если флагов нет)
```

## Правила и гарантии

- «First-hop» = outbound без ключа `detour` на момент глобального шага.
  Позиции цепочки `type: chain` — отдельные outbound'ы без `detour`;
  снятие приёмов со звеньев цепочки делает ядро (`strip_evasion`,
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.ru.md)).
- Смесь регистров SNI фиксируется на сборку конфига: новая — при каждой
  пересборке, не на каждое рукопожатие.
- `tls.fragment` и `tls.record_fragment` вместе с системным TLS-движком
  (`tls.engine` = `apple`/`windows`) снимаются с кодом
  `tls_fragment_system_engine` — на Android такой движок не ставится.
- `tls.ech.enabled` и `tls.reality.enabled` взаимоисключающи
  (`field_conflict`); ECH у MASQUE снимается.
- Пустой `short_id` законен; пустой `fingerprint` под REALITY из JSON
  остаётся пустым (ядро = `chrome`).
- Допустимость значений судит реестр контракта: на каждом входе разбора
  и ещё раз перед ядром.

## Границы

- Разбор ссылок и форматов в целом, коды разбора —
  [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.ru.md); здесь только поля
  TLS и транспорта, которые защищают или маскируют соединение.
- Порядок шагов сборки, шаблон, переменные вообще —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.ru.md).
- Цепочки, `strip_evasion`, detour — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.ru.md).
- Обфускация AmneziaWG/WARP (junk, I1–I5, защита заголовка) —
  [015-WARP](../015-WARP/FEATURE.ru.md); это другой слой, не TLS.
- Правка отдельных TLS-полей узла руками — [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.ru.md).
- Не делается: ротация SNI на каждое рукопожатие, padding ClientHello,
  domain-fronting, ECH из ссылки (`ech=`/`echfq`), переключатель ECH на
  узле, авто-откат ECH, параметры фрагментации Xray (`length`, `delay`,
  `maxSplit`), XHTTP `downloadSettings`, «detour совсем без фрагментации»
  (ядро включает `record_fragment` само).
- Снято с плана (§020F): шифрованное хранение секретов, pinning
  приложения, маскировка ссылок в UI и логах.
- Проверка сертификата выполняется ядром; хранилище `system` зависит от
  возможностей ОС (устаревшее на старых версиях Android).

## Функции

| Функция | Что делает | Обещания | Файл |
|---|---|---|---|
| Фрагментация TLS | Глобальные галки, first-hop, несовместимые узлы, уступка `detour`, перенос фрагментации Xray | P1 P2 P3 P4 | [tls-fragmentation.md](FUNCTIONS/tls-fragmentation.ru.md) |
| Mixed-case SNI | Случайный регистр `server_name`, пропуск REALITY | P5 P6 | [mixed-case-sni.md](FUNCTIONS/mixed-case-sni.ru.md) |
| Отпечаток uTLS | Дефолты, канонизация, мусор → `chrome`, QUIC, гибридный key share | P7 P8 | [utls-fingerprint.md](FUNCTIONS/utls-fingerprint.ru.md) |
| Параметры REALITY | `public_key`, `short_id`, `key_share`, деградация битого блока | P9 | [reality-params.md](FUNCTIONS/reality-params.ru.md) |
| ECH | Сквозной `tls.ech` из JSON, отказ от `ech=` ссылки | P10 | [ech.md](FUNCTIONS/ech.ru.md) |
| Параметры XHTTP | Полный набор полей, `extra`, `xmux`, enum-гейт, пара режим/placement | P11 P12 P13 | [xhttp-params.md](FUNCTIONS/xhttp-params.ru.md) |
| VLESS flow и encryption | Vision по ссылке, конфликт с транспортом, грамматика `encryption` | P14 P15 | [vless-flow-encryption.md](FUNCTIONS/vless-flow-encryption.ru.md) |
| Проверка сертификата сервера | Хранилище CA, `insecure`, пин ключа, свой CA | P16 P17 | [server-certificate.md](FUNCTIONS/server-certificate.ru.md) |

## Связанные фичи

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.ru.md) — фильтр узлов по `tls.utls.fingerprint`.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.ru.md) — разбор ссылок и форматов в целом, включая `packet_encoding`; здесь только поля TLS и транспорта.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.ru.md) — порядок шагов сборки, в который встроены глобальные приёмы; настройки ядра и их переносимость в бэкап.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.ru.md) — цепочки, detour и `strip_evasion`, от которых зависит, что считается первым хопом.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.ru.md) — ручная правка TLS-полей и отпечатка узла через его JSON.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.ru.md) — локальный прокси режима Proxy и его авторизация.
- [015-WARP](../015-WARP/FEATURE.ru.md) — обфускация AmneziaWG/WARP и фрагментация QUIC Initial, отдельный не-TLS слой.

## Особенности сопровождения

- REALITY матчит SNI точной строкой: любая «безобидная» правка
  `server_name` у REALITY-узла даёт тихий уход на камуфляжный сайт.
- Словарь отпечатков ядра и набор «с гибридным key share» зеркалятся в
  приложении; набор с гибридом (`firefox`, `safari`) верен только для
  ядра `v1.14.1-lx.3` и новее — при откате пина его надо сузить.
- `tls.fragment` под `detour` не ломает соединение, а замедляет его
  (500 мс на сегмент) и выключает защитный дефолт ядра — симптом
  «медленно через цепочку», а не «не работает».
