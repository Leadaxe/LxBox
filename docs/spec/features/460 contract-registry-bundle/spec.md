# 460 — Реестр контракта в приложении: бандлинг, санитайзер по схеме тела, предупреждения из реестра

**Тип:** фича
**Статус:** **W1 реализована, тесты зелёные (4912 passed / 15 skipped)**; W2–W3 — после волн лаунчера
**Коммит W1:** `feat(460): реестр контракта в приложении — бандлинг 1.1.0, санитайзер по схеме тела, RegistryWarning, гард на сборке (W1)`
**Решение владельца (18.09.2026):** бандлим реестр и генерируем правила из него; `warnings` в бэкап не пишем; 14 пунктов §24.2 приняты; дата синхронной правки naive userinfo — 24.09.2026.
**Контракт:** 1.1.0, `TASKS_LXBOX.md` §24 (SPEC 131 лаунчера, D-122); `schema/registry_body.schema.json`; `registry/protocols/*.json` → `body`, `tls.json`, `transports.json`, `multiplex.json`, `dialer.json`; `registry/warnings.json` (`title_*`/`text_*`).
**Связано:** §454 (TLS-allowlist руками — первый шаг к тому же), §455 (JSON-источник дословно — получает гард реестра на сборке), §459 (guard-фиксы B-вердиктов до конвейера), §302 (правила импорта над emit-JSON), §283/§400 (identity — тег, схема на него не влияет), §311 (running config).

## 1. Зачем

Правила «какое поле у какого протокола допустимо, какие значения, что делать с
мусором» сегодня написаны руками в Dart, по протоколу, и расходятся с
лаунчером и с ядром (DRIFT.md лаунчера: 14 расхождений, два общих бага
против ядра — vmess `aes-128-ctr`, xhttp enum'ы). Каждый пин ядра правится
руками (§453, §454, §457). Лаунчер вынес схему тела 384 полей из структур
ядра `1.14.1-lx.4` в реестр контракта и работает по ней. LxBox делает то же:
реестр едет в приложение, санитайзер и тексты предупреждений читаются из
него.

Нецели: генерация типизированных `*Spec`-классов из реестра (модель узла
остаётся рукописной — она про форму и UI, а не про допустимость полей);
замена парсеров URI (диалект `uri.*` реестра — отдельная волна);
`warnings` в бэкапе (решение владельца — нет).

## 2. Архитектура

```
contract/ (копия контракта, tool/sync_contract.sh)
 └─ registry/{protocols/*.json, tls.json, transports.json, multiplex.json,
              dialer.json, warnings.json}      ── pubspec assets ──┐
                                                                    ▼
lib/services/contract/
 ├─ registry.dart        ContractRegistry.I — загрузка (rootBundle / файл в
 │                       тестах), BodySchema по singbox_type с раскрытием ref
 │                       (tls, transports по discriminator, multiplex, dialer
 │                       inline), тексты кодов warnings.json
 ├─ body_sanitizer.dart  RegistrySanitizer.sanitize(map, scheme, coreVersion,
 │                       platform) → (map, [RegistryWarning])
 └─ registry_warning.dart RegistryWarning(code, path, value, params) —
                         NodeWarning, текст из реестра (title/text по языку)
                                                                    │
builder/build_config.dart ── после `list.build(ctx)`, до пост-шагов: ────┘
   каждый outbound/endpoint → sanitize(coreVersion=ctx.coreVersion,
   platform=android); предупреждения → ctx.warn (emitWarnings) c текстом
   реестра; drop_node → запись снимается из конфига с предупреждением.
```

Слой: `services/contract/` — сервис без Flutter-зависимостей (rootBundle
через инъекцию загрузчика), как `services/parser/`.

### 2.1 Загрузка

- `app/contract/` синхронизируется `tool/sync_contract.sh` до контракта
  1.1.0 (лок `app/contract.lock`, `check_contract_lock.dart` в CI).
- `pubspec.yaml` `assets:` — `contract/registry/`,
  `contract/registry/protocols/`, `contract/VERSION` (каталоги Flutter не
  рекурсивны — оба).
- `ContractRegistry.I.load()` в `main()` до `runApp` (после `VersionInfo`),
  ошибка загрузки — лог + работа без реестра (санитайзер пропускает, как
  сейчас); в тестах `ContractRegistry.I.loadFromDirectory('contract')`.
- Ссылки схемы: `ref: tls` → `tls.json.body`; `ref: transports` → вариант по
  `transport.type` (`discriminator`); `ref: multiplex`; `ref: dialer` /
  `dialer.common` — `inline: true`, поля вливаются плоско (`__dialer` в
  `order`).

### 2.2 Санитайзер (атрибуты `registry_body.schema.json`)

| Атрибут | Правило W1 |
|---|---|
| неизвестный ключ | снять, `unknown_key` (24.1.3) |
| `type` (`string,int,uint16,bool,duration,listable_string,string_array,object,enum,ref,array`) | несоответствие → `on_invalid`, а без него — `drop` + `type_invalid`; `listable_string` принимает строку или массив строк; `duration` — Go-duration после `normalizeSingboxDuration` |
| `values` + `normalize` | нормализация до проверки; вне enum → `on_invalid` |
| `format` (`uuid,hex,base64,host,port,ipv4,cidr`), `min/max/len/len_parity` | нарушение → `on_invalid` |
| `on_invalid.action` | `drop` — снять поле; `coerce` — `value`; `drop_node` — запись целиком |
| `required` | нет поля → `field_missing`, `drop_node` |
| `secret` | в `value` предупреждения `***` |
| `conflicts` | оба заданы → снять младшее по `order` с кодом |
| `requires` | нет требуемого → снять с кодом |
| `forbidden_for` / `allowed_for` | по `singbox_type` записи, код из атрибута (naive-TLS: `tls_field_unsupported_naive`) |
| `min_core` | версия ядра ниже → снять (гейт сборки, 24.1.6); сравнение `X.Y.Z-lx.N` |
| `platform` | не `android` → снять |
| `advisory` | значение в списке → info-код, поле не меняется (`ss_method_legacy`) |
| `all_or_nothing` | частичный объект → дополнить дефолтами соседей, `partial_object_defaulted` |
| `tristate`, `managed`, `deprecated`, `decision_pending`, `default`, `drop_always`, `build_tag` | W1: не трогает (документировано); `default` не материализуется (CANON §2.4) |

Порядок ключей результата — `order` схемы (эмиттер по `body.order`,
24.1.1); ключи вне `order` — в конец, как пришли.

Инвариант 24.1.7: значение с вердиктом B после санитайзера остаться не может
— тест над корпусом `contract/corpus/body/**` (где есть `expected.json`).

### 2.3 Предупреждения

`RegistryWarning` — `NodeWarning` c `code`, `path`, `value`, `params`;
`messageWith(t)` берёт `title_<lang>` (строка узла, ⚠) и `detailWith(t)` —
`text_<lang>` с подстановкой `{path}`, `{value}`, `{param}`; язык — `ru` при
русском UI, иначе `en` (zh падает в en, пока лаунчер не добавит). Код без
текста в реестре → `code` как есть. `code` для контракта (`renderEn`,
конформанс) — сам код.

Все рукописные сообщения `NodeWarning` остаются; новые коды (`unknown_key`,
`type_invalid`, `field_conflict`, `field_requires`,
`tls_field_unsupported_naive`, `partial_object_defaulted`,
`ss_method_legacy`, `reality_key_share_invalid`, `alias_shadowed`) —
только через `RegistryWarning`. Точки §459, где стоял `AppLog.warning`,
переходят на `RegistryWarning` там, где у парсера есть список warnings.

`registry_sync_test`: каждый код, который Dart порождает, есть в
`warnings.json`; каждому коду с `dart: null` в реестре, который LxBox теперь
порождает, лаунчер проставляет класс (24.3.4) — список отдать сессии
лаунчера.

### 2.4 Где применяется

- **Сборка (W1):** все записи `outbounds[]`/`endpoints[]` после
  `list.build(ctx)` — узлы подписок, серверы, члены папок, JSON-источники
  дословно (§455), Направления/цепочки не трогаются (не тело узла). Emit
  узлов без мусора не меняется байт в байт (goldens `rich_v0`/`avd_v0`
  прежние) — сверить.
- **Разбор (W2):** санитайзер над `emit()` узла при разборе подписки для ⚠ на
  строке узла с `path`/`value` (без `min_core`/`platform` — `entry` от ядра
  не зависит); карточка узла — `text_<lang>`; ссылка на
  `contract/docs/generated/warnings.md#<code>` после W4 лаунчера.
- **Конформанс (W2):** раннер корпуса отдаёт `warnings[]` объектами
  `{code, path, value}` (CANON §6); обновлённые `expected.json` — с W2c
  лаунчера; до них per-app override со ссылкой на §24.2.

### 2.5 Рукописные правила

По мере покрытия схемой уходят: TLS-allowlist §454 (`kTlsPassthroughKeys` →
`tls.json.body`), xhttp `putEnum` §217/§416/§459, `normalizeVmessSecurity`
§459, `shadowsocksMethods`, `packet_encoding` allow-list, naive-фильтр
§281/§454. W1 их **не** удаляет: санитайзер сборки идёт вторым эшелоном;
удаление — W2 после того, как корпус подтвердит паритет.

## 3. Волны

| Волна | Содержание | Кто |
|---|---|---|
| **W1** (18.09, ночь) | sync 1.1.0; assets; `ContractRegistry`; `RegistrySanitizer` по таблице 2.2; `RegistryWarning`; гард на сборке; §459-точки на `RegistryWarning`; тесты; доки | Opus по этой спеке |
| W2 | разбор-время ⚠ с path, карточка, конформанс с объектными warnings, удаление рукописных правил | после W2c/W3 лаунчера |
| W3 | генерация Dart-констант из реестра (enum'ы, allow-list'ы) вместо `registry_sync_test`-диффов | после W1 |

### Что из W2 закрыл §463 (корпус W2c лаунчера)

[§463](../../tasks/463-contract-w2c-corpus-conformance.md) снял с W2 один пункт
целиком и уточнил границы остальных.

**Закрыто — конформанс с объектными warnings.** Раннер корпуса
(`test/contract/contract_test.dart`) строит `warnings[]` объектами
`{code, path?, value?, params?}` и сравнивает по правилу CANON §6/§7 (зеркало
Go `normalizeWarningsForCompare`): `code` обязателен всегда, `path` и `value` —
только там, где их назвало ожидание. Ожидания строками (by-design override'ы
корпуса) продолжают читаться. Корпус зелёный целиком — 285 URI-кейсов и 38 тел,
ни одного per-app override заводить не пришлось.

**Уточнено — откуда берётся `path`.** `RegistryWarning` отдаёт путь и значение
как есть; рукописные классы — только там, где поле класса и ЕСТЬ путь
(`DeprecatedFlowWarning` → `flow`). Приписать путь остальным нельзя:
`AwgHeaderInvalidWarning` ставится пофакторно на каждый битый заголовок, и путь
разбил бы одну запись конверта на четыре (кейс `awg_ranged_h_broken_dropped`).

**Осталось на W2.**

1. Разбор-время ⚠ с путём для ВСЕХ кодов — сейчас правила значений живут в
   URI-парсерах, и путь несут только те коды, что §463 завёл через
   `RegistryWarning` (`type_invalid` на `transport.path`,
   `awg_header_invalid` на `jmin`, `ss_method_legacy`,
   `tuic_udp_relay_mode_invalid`). Парность URI↔JSON здесь упирается в W2d
   лаунчера: кейс `junk_pair_with_body` сам это фиксирует — тела двух половин
   совпадают, наборы путей пока нет.
2. Карточка узла с `text_<lang>` и ссылкой на якорь кода.
3. Удаление рукописных per-protocol правил в пользу `body`-секций реестра —
   §463 добавил рукописных правил (7.1, 7.5, 7.8, 7.10, 7.13), потому что
   санитайзер разбора ещё не подключён; все они описаны атрибутами реестра
   (`advisory`, `on_invalid`, `requires`, `format: url_path`) и уходят вместе с
   этим пунктом.
4. Порядок кодов по `body.order` — сейчас порядок задаёт обход парсера.

## 4. Проверка W1

- `test/contract/registry_load_test.dart`: реестр 1.1.0 грузится, схема
  vless раскрывает `tls`/`transports`/`dialer`; `warnings.json` даёт
  `title_ru`/`text_en` для `unknown_key`.
- `test/contract/body_sanitizer_test.dart`: по строке таблицы 2.2 —
  unknown_key; type_invalid (`server_port: "x"`); enum+normalize
  (`key_share: " Hybrid "`); format (uuid мусор → drop); required
  (`vless` без `uuid` → drop_node); secret (`***`); conflicts
  (`tls.ech.enabled` + `tls.reality.enabled`); requires
  (`key_share` без `public_key`); forbidden_for (naive + `tls.alpn`);
  min_core (`key_share` на `1.14.1-lx.3` снят, на lx.4 — нет); platform;
  advisory (`ss` `aes-128-cfb` → `ss_method_legacy`, поле цело);
  all_or_nothing (`transport.xmux` частичный → дополнен, код); порядок по
  `order`.
- `test/builder/registry_gate_test.dart`: сервер с JSON-источником `{type:
  naive, …, "foo": 1, tls:{insecure:true, certificate:…}}` → в конфиге нет
  `foo` и `tls.insecure`, `certificate` цел, два предупреждения в
  `emitWarnings` с текстом реестра; goldens `rich_v0`/`avd_v0` без
  изменений.
- Инвариант 24.1.7 над корпусом `contract/corpus/body/**`.
- `flutter analyze`, `flutter test`, четыре l10n-чекера (строк UI нет —
  тексты из реестра, l10n-exempt по правилу «строки из данных»),
  `check_contract_lock`.

## 5. Docs to update (W1)

- `docs/ARCHITECTURE.md` — подсистема `services/contract/`, поток «реестр →
  санитайзер сборки», assets.
- `docs/GUARDS.md` — слой 4.4: строка «санитайзер реестра: unknown_key /
  type_invalid / min_core / platform / forbidden_for — на всех записях
  outbounds/endpoints, тексты из реестра».
- `docs/KERNEL.md` — при пине ядра: sync контракта с новым `body` (реестр
  пополняется при пине, 24.1.3).
- `CHANGELOG.md` → Unreleased / Added.
- Контракт `TASKS_LXBOX.md` §24.5 — статус W1 и список кодов для привязки
  `dart`.

## 6. Что вышло в W1 (18.09.2026)

### 6.1 Отклонения от плана спеки

1. **Бандлится зеркало `app/assets/contract/`, а не сам `app/contract/`.**
   Вендоренная копия контракта лежит в `.gitignore` (SPEC 103: источник
   правды — репо лаунчера), а отсутствующий каталог в `flutter: assets:`
   роняет `flutter build` целиком («unable to find directory entry in
   pubspec.yaml») — проверено. В CI и на buildserver'е F-Droid копии нет, и
   каждая сборка падала бы. Поэтому `tool/sync_contract.sh` кладёт рядом
   зеркало ровно тех файлов, которые читает приложение (`VERSION`,
   `registry/*.json`, `registry/protocols/*.json`, 29 файлов, 572 КБ), и оно
   идёт в git. Руками его не правят: `check_contract_lock.dart` сверяет
   зеркало с копией файл-в-файл и падает на расхождении.

2. **Порядок ключей результата — входящий, а не `order` схемы.** Спека
   (§2.2) требовала схемного порядка. С ним эталоны `rich_v0`/`avd_v0`
   перестают совпадать байт в байт: сборка эмитит `type`/`tag` первыми, а
   схема их в `body.order` не держит вовсе (это дискриминатор и поле сборки).
   Требование «валидный конфиг не меняется» (§2.4) сильнее: `order` нормирует
   ЭМИТТЕР (24.1.1), а гард W1 — второй эшелон над уже собранным телом.
   Схемный порядок приедет вместе с переездом эмиссии на реестр, волной W2.

3. **Число под `type: string` не превращается в строку.** AWGRange-поля
   (`h1`..`h4`, `peers[].persistent_keepalive_interval`) реестр зовёт
   строкой, потому что они принимают и форму «min-max»; форма числом законна,
   и подмена на `"1"` меняла бы конфиг (ловится эталоном `avd_v0`). То же у
   `string_array`: `peers[].reserved` реестр зовёт массивом строк, а ядро
   читает `[]uint8` — три числа. Правило: значение, которое ядро принимает,
   санитайзер не переписывает.

4. **`RegistryWarning` объявлен в `models/node_warning.dart`.** `NodeWarning`
   — `sealed`, Dart 3 разрешает наследование только внутри её библиотеки.
   В `services/contract/registry_warning.dart` живёт логика рендера
   (`registryTitle`/`registryText`/`registrySeverity`), как и планировалось.

5. **Точки §459 на `RegistryWarning` не переводились.** Файлы §459
   (`json_parsers.dart`, `transport.dart`, `uri_utils.dart`, `tls_spec.dart`,
   `transport_spec.dart`) правит параллельная сессия; трогать их значило бы
   гарантированный конфликт. Перевод — отдельным шагом после влития §459.

### 6.2 Коды, которые порождает Dart (для привязки `dart` у лаунчера, 24.3.4)

24 кода достижимы санитайзером; у 11 в `warnings.json` стоит `dart: null` —
их закрывает один класс `RegistryWarning` (различает поле `code`):

`unknown_key`, `type_invalid`, `field_conflict`, `field_requires`,
`tls_field_unsupported_naive`, `partial_object_defaulted`, `ss_method_legacy`,
`port_invalid`, `reality_key_share_invalid`, `reality_pbk_invalid`,
`ss_method_invalid`, `tuic_udp_relay_mode_invalid`.

Остальные 12 уже имеют рукописный класс и приходят из реестра тем же путём:
`field_missing`, `flow_deprecated`, `packet_encoding_unknown`,
`reality_short_id_invalid`, `utls_fp_unknown`, `xhttp_param_reset`,
`obfs_unknown`, `masque_vhttp_invalid`, `anytls_min_idle_invalid`,
`tuic_congestion_invalid`, `awg_header_invalid`, `awg3_field_invalid`.
`alias_shadowed` W1 не порождает — алиасы разбирают парсеры (W2).

### 6.3 Корпус

Per-app override'ов W1 **не завёл ни одного**. Семь красных кейсов корпуса
(`vless/reality_key_share_*`, `vless/xhttp_mode_invalid`,
`vless/xhttp_placement_bogus_reset`, `vmess/vmess_security_{cfb,ctr}`,
`singbox/outbound_array_tls_fields.body`) появились от синка 1.1.0 и целиком
принадлежат §459 (vmess `security`, xhttp-enum'ы, `key_share`, `alpn`
строкой): их чинит параллельная сессия в своих файлах. Override здесь был бы
вреден — после §459 его пришлось бы снимать, а бесхозный override линтер
контракта не пропустит.

Инвариант 24.1.7 над `contract/corpus/body/**` зелёный без единой правки:
повторный прогон санитайзера по очищенному телу не находит нарушений на всех
21 кейсах с `expected.json`.

## 7. W2d (§464, 18.09.2026) — выражения реестра, которые понимает санитайзер

Волна W2d лаунчера (синк на `be8079bf`) добавила в реестр выражения, которых
в схеме W1 не было: правила значений уехали из URI-парсеров лаунчера в
санитайзер, и выразить их стало нечем. `RegistrySanitizer` понимает их все —
задача §464, `docs/spec/tasks/464-contract-w2d-sync.md`.

| Выражение | Что значит | Где в коде |
|---|---|---|
| `format: base64_32` | ключ ровно 32 байта ПОСЛЕ декода (REALITY `pbk`, ключи WireGuard). Длины строки мало: `enabled` — валидный base64 на 5 байт | `body_sanitizer.dart:855` |
| `normalize: hex_only` | чистка не-hex рун + нижний регистр (`0x1a2` → `01a2`); правило §343 стало общим на все входы | `body_sanitizer.dart:678` |
| `normalize_code` | код, если нормализация ИЗМЕНИЛА значение; ставится на исходном значении | `registry.dart:66`, `body_sanitizer.dart:380` |
| `normalize: grpc_service_name` | Xray-форма `/<сервис>/Tun` → `<сервис>`; хвост `\|multi` на сегменте потока игнорируется | `body_sanitizer.dart:711` (публичная — её же зовут парсеры) |
| `advisory` с `except` | код на всём, КРОМЕ перечисленного (отпечатков у ядра три десятка, гибридных девять); пустое значение под правило не попадает | `body_sanitizer.dart:414` |
| `advisory` с `when` | условие по другому полю тела (`tls.reality.enabled` задан) | `body_sanitizer.dart:421`, `_advisoryWhen` `:570` |
| `requires` с `equals` | требуется КОНКРЕТНОЕ значение соседа (`obfs.type = gecko`), а не просто его наличие | `body_sanitizer.dart:538`, `_valueAt` `:556` |
| `default_when` | дефолт, без которого ядро не поднимает outbound вовсе (полоса hysteria v1). В отличие от `default` (CANON §2.4) материализуется явно и кода не даёт | `registry.dart:73`, `body_sanitizer.dart:160` |
| тип `awg_range` | число ИЛИ диапазон «N-M» строкой; форма прибытия законна обе и не подменяется | `body_sanitizer.dart:804` |
| тип `int_array` | массив целых (`peers[].reserved`) | `body_sanitizer.dart:815` |

**Незнакомое выражение не роняет загрузку.** `normalize`, `format` или `type`,
которого в этом коде нет, пишется в лог ОДИН раз на процесс, а значение
остаётся нетронутым (`_logUnknownExpression`, `body_sanitizer.dart:732`).
Реестр вправе ехать впереди клиента: у F-Droid и Play свои циклы выпуска, и
бамп контракта не должен требовать синхронного бампа приложения.

Гейт `min_core` в реестре тоже остаётся: `default_when` отвечает на «ядро без
поля не работает», `min_core` — на «ядро этого поля ещё не знает», и путать их
нельзя.
