# §469 — контракт 1.1.4: срез uTLS/REALITY на QUIC по реестру, код `tls_not_applicable_quic`

| | |
|---|---|
| **Статус** | Реализовано, тесты зелёные (5052) |
| **Дата** | 2026-09-18 |
| **Источник** | лаунчер `371448da` (HEAD develop, содержит `eab498bc`), `TASKS_LXBOX.md` §24.13 |
| **Связанные** | фича 460 (санитайзер, W2a), §468, §270 (naive-TLS whitelist), `TlsSpec.toSingboxForQuic` |

## Проблема

У QUIC-протоколов (hysteria2, tuic, masque, hysteria v1) ядро строит TLS через
`qtls.Dial → STDConfig()` и на `utls`/`reality` отвечает ошибкой. Мы эти блоки
срезаем (`TlsSpec.toSingboxForQuic`), но **молча**: пользователь задал `fp=` —
и не узнаёт, что он не действует. Правило жило в коде, а не в реестре.

## Решение

1. Синк контракта на `eab498bc` или новее из той же серии (способ — только
   `git archive <sha>`); `contract.lock`, зеркала `assets/contract/` и
   `docs/contract/` — в коммит.
2. Реестр: у `tls.utls` и `tls.reality` `forbidden_for` дополнен QUIC-схемами.
   Санитайзер это правило уже исполняет; проверить, что hysteria v1 у нас
   входит в срез (в `toSingboxForQuic` или его вызовах) — если нет, добавить.
3. Новый атрибут схемы **`forbidden_codes`** — словарь «схема → код» поверх
   общего `code` у `forbidden_for`. Чтение в `registry.dart`, исполнение в
   `body_sanitizer.dart`, линтер схемы (`registry_invariant_test`).
4. Узел получает `tls_not_applicable_quic` (severity info) — **один на блок**
   (`utls`, `reality`); вложенные `key_share`/`short_id` своих кодов не дают.
   На обоих путях: URI-парсеры hy/hy2/tuic/masque должны прочитать `fp` (и
   параметры reality, если ссылка их несёт) ровно настолько, чтобы парные
   кейсы корпуса uri↔body дали равные `entry` и `warnings`. Тело узла от
   этого не меняется: блок по-прежнему срезается.
5. Атрибут `forbidden_when` снят из схемы — убрать упоминания, если есть.
6. Сверка двух дефектов, найденных лаунчером у себя (`371448da`):
   - Xray-конвертер переписывал `server_port` в 443 (DRIFT §7.4) — у нас
     §459 это уже снимал для `-udp443`; проверить остальные ветки;
   - дубль санитайзера hysteria2 obfs съедал `obfs_unknown` /
     `obfs_password_missing` — проверить, что у нас эти коды доходят до узла
     на обоих путях.
   Найдено — чинить с тестом; не найдено — записать в спеку, где смотрели.

## Критерии приёмки

- корпус зелёный без новых override; парные кейсы QUIC uri↔body равны;
- hy2/tuic/masque/hysteria с `fp` → тело без `utls`, один
  `tls_not_applicable_quic`; с reality-параметрами → один код на блок;
- vless+reality — без изменений (golden не перегенерируются);
- `flutter analyze` всего проекта, `flutter test -j 2` — «All tests passed»;
- `check_contract_lock.dart` зелёный (три проверки);
- CHANGELOG, GUARDS.md, PROTOCOLS.md (QUIC-протоколы), спека 460 (раздел 7 —
  `forbidden_codes`) обновлены.

## Как сделано

### Синк контракта 1.1.3 → 1.1.4

Снимком, как и §468: `git archive 371448da contract` из репозитория лаунчера
во временный каталог, оттуда `LX_CONTRACT_SRC=… app/tool/sync_contract.sh`.
Рабочее дерево лаунчера в копию не попало, в его репозитории ничего не
менялось. Хеш дерева в `app/contract.lock` —
`c1c3be55cc7d3c67deb310b588720eafa4aa6d2ea4cc8619973de31da8d270f4`.
`dart run tool/check_contract_lock.dart` зелёный по всем трём проверкам
(копия ↔ lock, зеркало реестра, зеркало документации).

Взят `371448da`, а не `eab498bc`: он новее, содержит его целиком
(`git merge-base --is-ancestor` — да) и является HEAD develop лаунчера.
Вторым коммитом приехал аудит `LEGACY_AUDIT.md` и два исправления у лаунчера,
разобранные ниже (пункт 6).

Изменилось шесть файлов реестра:

- `tls.json` — у `body.fields.utls` и `body.fields.reality` в `forbidden_for`
  рядом с `naive` встали четыре QUIC-схемы, и появился новый атрибут
  `forbidden_codes`;
- `warnings.json` — новый код `tls_not_applicable_quic`, severity `info`,
  с `cause_*` и `fix_*`;
- `protocols/hysteria.json` — `fp` был `type: ignored` «не читается», стал
  `alias_enum` → `tls.utls.fingerprint`, как у всех схем;
- `protocols/hysteria2.json`, `protocols/tuic.json` — переписаны `impl` у
  `fp` (описывали разрыв, который закрыт);
- `VERSION` — `1.1.4`.

Зеркало `docs/contract/**` изменилось шире реестра — на 24 файла и ~5 тысяч
строк. Это не наша правка: между `3dacd68e` и `371448da` лёг ещё и
`3030b8f7` («Docs v2»), переписавший генератор страниц — якоря в обе стороны,
вводный блок протокола, полный словарь ссылки. Страницы приезжают из
`contract/docs/generated/**` байт в байт, своего генератора у нас нет
(спека 460 §8.1), и сверку зеркала делает `check_contract_lock`.

### `forbidden_codes` у нас

Словарь «схема → код» поверх общего `code`. Чтение —
`FieldSchema.forbiddenCodes` и `forbiddenCodeFor(scheme)` в `registry.dart`
(схема без записи берёт общий `code`, кода нет вовсе — `type_invalid`, как и
прежде). Исполнение — одна строка в `_gated` (`body_sanitizer.dart`):
`f.forbiddenCodeFor(scheme)` вместо `f.code`. Больше нигде: `allowed_for` в
теле реестра не встречается ни разу, гейт у них общий.

Линтер атрибута — группа `§469 — forbidden_codes` в
`registry_invariant_test.dart`: рекурсивный обход всех файлов `registry/**`
проверяет, что ключ словаря есть в `forbidden_for` того же поля (иначе
правило не сработает никогда, а выглядит написанным) и что код есть в
`warnings.json` (иначе узел получил бы запись без текста). Плюс проверка, что
атрибут вообще встречается: молча зелёный линтер скрыл бы откат контракта.

### `value` у гейта запрета — попутная находка

Гейт `forbidden_for` ставил код **без значения**, хотя ожидания корпуса его
называют: `singbox/outbound_array_tls_fields.expected.json` требует
`tls.insecure` = `true`, `tls.utls` = `map[enabled:true fingerprint:chrome]`.
Заметить было нечем — body-раннер корпуса сверяет состав узлов и отбраковку,
но не `warnings[]`.

Заодно разошлась форма печати. Канон корпуса: карта —
`map[ключ:значение ключ:значение]` с ключами по возрастанию, список —
`[a b c]`, обрезка — 64 **руны** плюс `…`. У нас стоял Dart-`toString()`
(`{enabled: true, …}`) и обрезка 61 символ плюс `...`. Форма своего смысла не
несёт, это канон записи — приведена к корпусу
(`RegistrySanitizer.renderWarningValue`, публичная: у `value` появился второй
производитель, см. ниже).

Один тест это заметил: `builder/registry_gate_test.dart` утверждал
`[tls.insecure]` без значения, с обоснованием «код уровня поля к значению не
относится». Обоснование было наше, а не контрактное — ожидание переписано на
`[tls.insecure=true]`. Шаблон строки отчёта (`[путь=значение]`) не менялся,
он умел значение и раньше.

### Где ставится код при разборе и почему там

**Не санитайзером.** Санитайзер разбора (W2a, `parse_warnings.dart`) смотрит
на `emit()` уже разобранного узла — а `emitHysteria2`/`emitTuic` зовут
`TlsSpec.toSingboxForQuic`, где блоки уже срезаны. Правило `forbidden_for` до
них не доезжает, и узел остался бы без кода. Снять срез нельзя: тело узла
нормировано корпусом и обязано остаться без блоков.

**Ставит парсер, правило берёт из реестра.** `forbiddenTlsBlockWarnings`
(`parse_warnings.dart`) спрашивает у реестра схему `tls`, идёт по её `order`
и на каждом поле, чей `forbidden_for` содержит схему узла, ставит
`forbiddenCodeFor(scheme)`. Списка схем в Dart нет — иначе он разошёлся бы с
контрактом на первом же бампе. Порядок кодов = `order` схемы TLS, то есть тот
же, по которому идёт санитайзер и в котором коды стоят в ожиданиях корпуса.

Правило снимется само, когда эмиссия переедет на реестр и блоки доедут до
санитайзера.

> **СНЯТО у hysteria2 и tuic — §472 шаг 5.** Предсказание сбылось ровно так,
> как записано абзацем выше. На конвейере разбора маппер кладёт `tls.utls` и
> `tls.reality` в СЫРУЮ карту обычным порядком, и `forbidden_for` исполняет
> САНИТАЙЗЕР — по одному коду на блок, с тем же `value` (рендер общий,
> побуквенно сверено с эталоном старого пути). Рукописный производитель снят:
> - **на пути ссылки** — вместе с самими парсерами: `hysteria2_parser.dart` и
>   `tuic_parser.dart` стали строкой вызова конвейера;
> - **на пути тела hysteria2 и tuic** (`json_parsers.dart`) — как лишний, а не
>   как дубль: с §472 шага 1 у JSON-узла есть проход по ДОСЛОВНОЙ карте
>   (`annotateFromRawBody`), и он исполняет то же правило по тому же телу.
>   Дедуп по `(code, path)` совпадение снимал, поэтому расхождения видно не
>   было.
>
> `TlsSpec.toSingboxForQuic` **остался**: модель может получить отпечаток из
> формы вкладки Settings, минуя разбор, и эмиттер обязан остаться последней
> преградой. Он просто больше не единственная.
>
> Функция `forbiddenTlsBlockWarnings` жива ради одного вызывающего — ветки
> **masque** (переезжает шагом 7). Подробности — спека 472, раздел 11.

**Блоки передаются картой, а не `TlsSpec`.** Класть запрещённый REALITY в
модель QUIC-узла значило бы тащить его через равенство, identity-хеш и
`normalizeTlsFingerprint` — а там REALITY заводит свои коды
(`reality_fp_not_chrome` на узле, где REALITY не работает вовсе).

| Вход | Что читается | Что в модели |
|---|---|---|
| `hysteria2://…?fp=` | было и раньше (`TlsSpec.fingerprint`) | как было |
| `hysteria2://…?pbk=&sid=` | **новое**: только ради `value` кода, требование к ключу то же, что у vless (§169) | ничего |
| `tuic://…?fp=` | **новое**: прежде не читался вовсе | ничего |
| тело sing-box hysteria2/tuic | сырая карта `tls.utls`/`tls.reality` как прислал провайдер | как было |
| тело sing-box masque | **новое**: сырая карта `tls.utls`/`tls.reality`. `MasqueSpec` таких полей не знает вовсе, и в рукописном теле блок пропадал молча | ничего (и раньше ничего) |
| `masque://…` | ссылка `fp`/`pbk` не несёт по формату — правила не касается | — |
| `hysteria` v1 | схема помечена `extension: desktop`, парсера у нас нет | — |

Неопознанный отпечаток печатается в `value` **как пришёл**, а не подменой на
`chrome`, которую делает нормализация: `value` это «исходное значение до
деградации» (CANON §6). Кода `utls_fp_unknown` на QUIC-схемах не заводится —
отпечаток, который в принципе не применяется, ядру неизвестным быть не может,
и корпус его там не ждёт.

### Корпус

Пять красных кейсов от синка, все зелёные без единого override:

| Кейс | Почему падал |
|---|---|
| `uri/hysteria2/fp_present_no_utls_quic` | код не ставился |
| `uri/hysteria2/utls_fingerprint_pinsha256` | то же |
| `uri/hysteria2/reality_fp_stripped_quic_pair` | `pbk`/`sid` не читались вовсе |
| `uri/tuic/fp_stripped_quic_pair` | `fp` не читался вовсе |
| `uri/masque/vhttp_invalid_forced_h3` | контракт 1.1.4 назвал `path`/`value` у `masque_vhttp_invalid`; у нас класс не был в таблицах раннера |

Парные половины `body/singbox/{hysteria2,tuic}_quic_tls_pair` зелёные, но это
ничего не доказывает: body-раннер `warnings[]` не сверяет. Равенство пары
проверено отдельным юнитом (`parse_warnings_test.dart`, «hysteria2 из тела:
те же коды, что у ссылки»).

**Раннер URI теперь грузит реестр.** Правила, которые парсер берёт из
реестра, без него молчат, и раннер проверял бы поведение, которого в
приложении не бывает: `main()` грузит реестр до `runApp`, то есть любой
разбор в проде идёт с загруженным реестром. Других потребителей
`ContractRegistry.I` в `lib/services/parser/**` и `lib/models/**` нет —
проверено grep'ом, так что загрузка ничего больше не сдвинула.

`vless` + REALITY не изменился, golden не перегенерировались: эталоны
`rich_v0`/`avd_v0` (`storage_migration/golden_config_test.dart` и «эталоны при
загруженном реестре» в `registry_gate_test.dart`) прошли без правок.

Полный прогон — `flutter analyze` по всему проекту чисто, `flutter test -j 2`:
**5052 пройдено, 15 skipped, ни одного падения**.

### Пункт 6 — сверка двух дефектов лаунчера

**`server_port` → 443 в Xray-конвертере: у нас нет.** §459 снял перезапись в
обеих ветках, и обе несут об этом комментарий:
`json_parsers.dart` `_xrayVlessToSpec` (обработка `flow` =
`xtls-rprx-vision-udp443`) и ветка `case 'vless'/'vmess'` в построении ключа
identity («прежний код ставил здесь 443»). Остальные упоминания `443` в файле
— дефолт порта при его ОТСУТСТВИИ (`?? 443` у vless/vmess/trojan/http/ss/
hysteria), а не перезапись заданного. Смотрел: все восемь вхождений `443` в
`lib/services/parser/json_parsers.dart`, плюс `grep` по `lib/services/` на
`port = 443` — единственное совпадение `masque_account.dart defaultPort`,
константа WARP.

**Дубль санитайзера obfs: у нас БЫЛ, исправлен.** Не дубль правила (правило
одно, `normalizeHysteria2Obfs`), а съеденные коды: ветка `case 'hysteria2'` в
`parseSingboxEntry` передавала `null` вместо аккумулятора с комментарием «у
`parseSingboxEntry` нет warnings-аккумулятора». Аккумулятор есть —
`NodeSpec.warnings`, куда его кладёт сам spec. Узел, пришедший ссылкой,
получал `obfs_unknown` / `obfs_password_missing`, тот же узел телом — ничего,
хотя тело выходило одинаковым. Исправлено, тест —
`parse_warnings_test.dart`, «§469 п. 6 — obfs-коды hysteria2 доходят до узла
и из тела».

Тот же комментарий про «нет аккумулятора» стоит у `_tlsFromSingbox` (§281,
`fp`): его НЕ трогал — это правило значения, корпус кода там не ждёт, и
задача такого решения не содержит.

## Файлы

| Файл | Что |
|---|---|
| `app/contract/**`, `app/assets/contract/**`, `docs/contract/**`, `app/contract.lock` | синк 1.1.4 (копия gitignored, оба зеркала в git) |
| `app/lib/services/contract/registry.dart` | `forbiddenCodes`, `forbiddenCodeFor` |
| `app/lib/services/contract/body_sanitizer.dart` | код из `forbidden_codes`, `value` у гейтов, `renderWarningValue` по канону корпуса |
| `app/lib/services/contract/parse_warnings.dart` | `forbiddenTlsBlockWarnings`, `utlsBlockOf`, `tlsBlocksOfBody` |
| `app/lib/services/parser/uri_parsers/hysteria2_parser.dart` | код на обоих блоках; `pbk`/`sid` читаются ради `value` |
| `app/lib/services/parser/uri_parsers/tuic_parser.dart` | `fp` читается ради кода |
| `app/lib/services/parser/json_parsers.dart` | код на телах hysteria2/tuic/masque; obfs-коды перестали пропадать |
| `app/test/contract/contract_test.dart` | загрузка реестра; `path`/`value` у `masque_vhttp_invalid` |
| `app/test/contract/registry_invariant_test.dart` | линтер `forbidden_codes` + три юнита санитайзера |
| `app/test/contract/parse_warnings_test.dart` | семь кейсов §469 |
| `app/test/contract/registry_load_test.dart` | версия 1.1.3 → 1.1.4 |
| `app/test/builder/registry_gate_test.dart` | ожидание `[tls.insecure=true]` |
| `CHANGELOG.md`, `docs/GUARDS.md`, `docs/PROTOCOLS.md`, спека 460 §7/§7a | доки |

## Коммиты

| Коммит | Что |
|---|---|
| `a0397559` | синк 1.1.4 + зеркала, `forbidden_codes`, код на обоих путях разбора, `value`/рендер по канону корпуса, obfs из тела, тесты, доки |
