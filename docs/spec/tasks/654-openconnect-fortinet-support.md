# §654 — OpenConnect (FortiGate и др.): контракт 1.1.122, форма Add server, второй фактор и SSO

| Поле | Значение |
|------|----------|
| Тип | F (новая возможность: протокол `openconnect`) |
| Статус | Done (A, A2, B, B2, C влиты 15.10.2026, CI 38767295959 зелёный на 513b858d; туннель FortiGate на эмуляторе поднимается; живой второй фактор и SAML — у владельца) |
| Дата | 2026-10-15 |
| Связанные | §653 (синк 1.1.121; 1.1.120 = `openconnect` известен как endpoint), §579/§581/§645 (подписка статуса Tailscale через libbox — образец канала), §586 (`fields_unchecked`), §577 (авторское тело), §478 (автоснятие узла) |
| Контракт | 1.1.122, `TASKS_LXBOX.md` §119 лаунчера; синк на коммит лаунчера `0ca7b7c5` |
| Лаунчер | SPEC 167 (`SPECS/167-F-C-OPENCONNECT_FORM/` на `0ca7b7c5`): SPEC.md §2.3 (макет формы), §2.5 (диалоги), REGISTRY_DESIGN.md §2–§5 (норма примитивов и запись) |
| Ядро | `with_openconnect` с lx.10, у нас пин `v1.14.3-lx.18`; классы `OpenConnect*` в `libbox.aar` есть (`OpenConnectStatusSubscription`, `OpenConnectAuthChallenge`, `OpenConnectAuthResponse`, `OpenConnectBrowserRequest/Result`, `OpenConnectFormValues`…). Ничего нового от ядра не нужно |

## Проблема

Владелец хочет подключаться к корпоративным VPN-шлюзам FortiGate (и в
перспективе Cisco AnyConnect, GlobalProtect, F5, Pulse, Juniper) из LxBox.
Ядро умеет это endpoint-типом `openconnect`. Сейчас (контракт 1.1.121)
LxBox знает тип только как «поля не описаны» (`fields_unchecked`): узел из
sing-box JSON доезжает до ядра, но:

- ввести узел руками негде: URI-схемы у OpenConnect нет и не будет
  (решение владельца), формы в Add server нет;
- если шлюз просит второй фактор (код из письма/SMS/TOTP) или SSO (SAML),
  endpoint навсегда висит в `auth-pending`: ядро ждёт ответа через
  libbox, а LxBox его не слушает — трафик в узел не идёт, человек не видит
  почему;
- подпись узла — просто `openconnect`, без вендора.

Лаунчер всё это сделал (SPEC 167) и поднял контракт до 1.1.122 с тремя
новыми примитивами реестра. Без их поддержки синк 1.1.122 ломает
`openvpn-client` и `openconnect`: `fields_unchecked` удалён из схемы, его
заменил wildcard `*`.

## Факты (лаунчер + ядро, 15.10.2026)

**Тип ядра.** `openconnect`, kind endpoint (в `endpoints[]`). Вендор —
поле `flavor`: `fortinet` | `anyconnect` (дефолт ядра без ключа) | `gp` |
`f5` | `pulse` | `nc`. Поля `protocol` нет. Обязательно только `server`
(`host:port` или URL; `https://` и порт 443 ядро дописывает само;
**`server_port` у типа нет** — не материализовать его из `host:port`).
Авторизация: `username`, `password` (secret), `auth_group` (FortiGate не
использует), `cookie`, `token{mode,secret,secret_path,counter,pin,password,device_id}`,
клиентский сертификат `tls.client_certificate(_path)` + `tls.client_key(_path)`
только парой, `external_auth_disabled`. TLS: `insecure`, `server_name`,
`peer_fingerprint` (список; без префикса — SHA-1 hex 4..40, `sha1:` hex SPKI
≤40, `sha256:` hex SPKI ≤64, `pin-sha256:` base64 ≤44),
`certificate_authority(_path)`, `system_trust_disabled`, `mca_*`. Прочее:
`no_udp`, `user_agent`, `fortinet_host_check.{hostcheck,check_virtual_desktop}`,
`mtu`, `dpd_interval`, `reconnect_timeout`, `ipv6_disabled`,
`allow_insecure_crypto`, `system`, компрессия, `csd`/`hip`/`tncc`,
`form_entries`, `mobile`, обычный detour.

Секреты: `password`, `token.secret`, `token.password`, `tls.client_key`,
`tls.client_key_password` (флаг `secret` в реестре).

**Проверено вживую владельцем** (лаунчер, FortiGate без второго фактора):

```json
{"type":"openconnect","tag":"🇮🇱 forti","server":"https://fw.example.com:42319",
 "flavor":"fortinet","username":"user","password":"***","tls":{"insecure":true}}
```

Форма, диалог второго фактора и SAML на реальном шлюзе с MFA не проверены
ни у кого.

**Поведение ядра при входе** (сессия ядра):
- Челлендж без таймаута: endpoint в `auth-pending`, бокс стартует, трафик в
  endpoint не идёт, повторного логина нет, пока челлендж висит.
- `Cancel` = retryable-ошибка → бэкофф 1→60 с → новый логин с паролем →
  новый челлендж (у FortiGate — новое письмо с кодом). Неверный код — то же.
- Неверный пароль — ядро стирает пароль из кэша и присылает форму с полями
  username/password, цикла нет.
- Терминальные ошибки (без ретраев): `ErrAuthenticationFailed`, ошибки
  сертификата, `ErrProtocolNotSupported` (неподдерживаемый тип челленджа
  FortiGate), `external_auth_disabled` при SSO-запросе шлюза, ошибки
  конфига. Остальное retryable с капом 60 с.
- SSO FortiGate (SAML) — callback-режим: `browser.callbackURLPrefixes =
  ["http://127.0.0.1:"]` → открыть `url` в браузере, слушать loopback,
  поймать редирект, отдать `finalURL`. AnyConnect — cookie-режим (нужен
  встроенный браузер, читающий cookie).
- DTLS поддержан (`no_udp` отключает). Маршруты от шлюза ядро в систему не
  ставит — маршрутизацию ведёт sing-box.

## Решение

Три волны. A — обязательная база (без неё нельзя синкнуть 1.1.122). B и C
от A не зависят по файлам, но B использует функции формы из A.

### A. Контракт 1.1.122 в движке LxBox

Норма — `TASKS_LXBOX.md` §119 лаунчера и `REGISTRY_DESIGN.md` §2–§5. Кратко:

1. **Синк** `app/tool/sync_contract.sh --to 0ca7b7c5` (только на этот sha,
   `contract.lock` сверить).
2. **Wildcard `*`** в `fields` объекта: не поле (без `type` и правил).
   Ключи этого объекта, которых нет в `fields`, копируются как есть, без
   `unknown_key` и без проверки; описанные проверяются своими правилами.
   **Не наследуется** во вложенные объекты без своего `*`. Позиция `*` в
   `order` — слот эмиссии сквозных ключей по алфавиту. Связи видят сквозные
   пути (`unless_set: ["tls.client_key"]`), но `*` в путях связей и
   условий запрещён. Объект, снятый целиком, уходит со сквозными ключами.
   `fields["*"]` пропускают ВСЕ обходы полей: санитайзер, эмиттер,
   валидатор, роли, гейт сборки, поиск по пути, проверки структуры реестра.
3. **`fields_unchecked` больше не читать** — ветки снять (эквивалент
   `order: ["*"]`). `openvpn-client` теперь на `*`; кейс корпуса
   `body/singbox/openvpn_client_endpoint` не изменился.
4. **Материализация адреса:** `server`/`server_port` дописываются в тело
   только если у схемы протокола описано соответствующее поле, каждое
   отдельно (у openconnect `server_port` нет; под `*` он ушёл бы в ядро —
   кейс `no_server_port_materialized`).
5. **Роль `variant`** (`role: "variant"`, у `flavor`): значение после trim,
   пусто → `default` поля. В `_deriveTransport` (`config_node.dart`) порядок
   `transport` → `vhttp` → `variant` → пусто. Подпись «openconnect·fortinet»,
   без `flavor` — «openconnect·anyconnect». Не переводится.
6. **Атрибут `form`** — модель формы, без UI: чистые функции по образцу
   лаунчерских `Form`/`FormState` — раскладка `blocks` + поля с `block` в
   порядке `order`, `visible_when` (существующая грамматика condition без
   `source_kind`, по текущему состоянию формы, `default` поля в условие НЕ
   подставляется, скрытый объект скрывает поддерево), `required`,
   `required_unless{set,absent}`, `min`/`max`, `choices` (активен первый
   вариант с заданным путём из `paths`, иначе вариант с пустыми `paths`;
   смена варианта чистит `paths` остальных и пишет `set` выбранного),
   `advisory` поля. Санитайзер, эмиттер, гейт и маппер `form` не читают.
7. **Четыре кода** в таблице предупреждений (+ RU/ZH тексты по правилам
   l10n): `openconnect_flavor_invalid`, `openconnect_fingerprint_invalid`,
   `openconnect_mtu_invalid` (warning), `openconnect_insecure_crypto` (info).
8. **Корпус:** кейсы `body/singbox/openconnect_*` (9 новых + изменённое
   ожидание `openconnect_endpoint`: info `tls_insecure`), `authored/hard_openconnect_token_without_secret`
   проходят существующими раннерами; новый раннер `corpus/form` по
   `corpus/form/README.md` (тело → `visible`, `required`, `missing`,
   `choices`, `out_of_range`) под `corpusTestSkip`.

Расхождение с корпусом, которое не объясняется нормой, — сообщить
лаунчеру (сессия «OpenConnect Fortinet configuration»), не править корпус
у себя.

**Волна A — выполнено (15.10.2026).** Контракт синкнут на `0ca7b7c5`
(1.1.122). Что сделано и где:

- Wildcard: `ContractRegistry` не кладёт `*` в разобранные карты полей
  (`FieldSchema.fields`, `BodySchema.fields`), в `order` он остаётся слотом;
  признак — `hasWildcard`. Все обходы по `fields` его не видят по
  построению. Санитайзер (`sanitizeObject`): при `*` в `order` объекта
  неописанные ключи копируются (глубокая копия, во входящем порядке) и
  кладутся в снимок для связей. Эмиттера тела по `order` реестра в LxBox
  нет (санитайзер сохраняет входящий порядок, корпус сравнивает тела по
  отсортированным ключам), так что слот `*` в эмиссии не используется.
- `fields_unchecked` снят; `isUncheckedType` заменён на
  `ContractRegistry.knowsType` (есть схема у типа). Узел типа без своей
  модели (`openvpn-client`, `openconnect`) — `UnknownTypeSpec` с ОЧИЩЕННЫМ
  телом; коды и снятие записи — проход по дословной карте
  (`annotateFromRawBody`, раньше `UnknownTypeSpec` он пропускал).
- Адрес: `UnknownTypeSpec` адрес в тело не дописывает вовсе;
  `ContractRegistry.describesRootField(type, name)` — для мест, которые
  будут дописывать.
- Роль `variant`: `variantLabelByRegistry` (`protocol_level.dart`),
  `_deriveTransport` — `vhttp` → `transport` → `variant` → `tcp`.
- Модель формы: `lib/services/contract/registry_form.dart` —
  `formLayoutFor(scheme)` → `FormLayout` (`blocks`, `fieldsIn(block)`,
  `choicesIn(block)`, `field(path)`, `choice(id)`, `stateOf(body)`),
  `FormState` (`visible`, `required`, `missing`, `choices`, `outOfRange`,
  `isVisible/isRequired/isMissing/outOfRangeAt`, `canSave`),
  `activeFormOption`, `applyFormOption`, `withFormValue` (пустое снимает
  ключ и опустевший объект), `formValueAt`, `formPathSet`,
  `formAdvisoryCodes`, `formRequired`.
- Четыре кода: тексты EN/RU — данные `warnings.json` (синк); своих строк
  приложение для кодов реестра не держит, ZH падает в EN
  (`registry_warning.dart`) — l10n-файлы не менялись.
- Попутно по норме лаунчера: объект, который санитайзер опустошил (связь
  сняла единственное поле), в тело не идёт (кейс
  `openconnect_client_cert_without_key`); код снятия записи в `dropped[]`
  берётся из `dropFrom` санитайзера, когда он не `error`
  (`openconnect_flavor_invalid` — warning).
- Тесты: `test/contract/form_corpus_test.dart` (раннер `corpus/form`),
  `registry_form_test.dart`, `registry_wildcard_test.dart`, кейс variant в
  `test/models/config_node_test.dart`.

### A2. Контракт 1.1.123–1.1.124

Норма — `TASKS_LXBOX.md` §120 (1.1.123) и §121 (1.1.124) лаунчера,
`PARSING_PRINCIPLES.md` §6.4. Синк на `0e88c814` (1.1.124).

- **§121 — пустой описанный объект снимается.** `_sanitizeObjectField`:
  объект с `fields`, пустой после обхода, в тело не идёт без кода — и
  опустошённый правилами, и `{}` во входе (`tls.ech: {}`).
  `_sanitizeVariantObject`: без дискриминатора (`transport: {}`) —
  `field_missing@transport.type`, объект снят, узел живёт. Сквозной ключ под
  `*` копируется как есть, `{}` в том числе (`openvpn-client` `tls: {}`).
  Авторское тело (§577) `{}` сохраняет: правило мягкое, точка правки
  (`settleSanitized`) переносит только жёсткие пути; `field_missing` идёт с
  `applied: false`. Корпус: `empty_described_object_dropped`,
  `openvpn_client_empty_tls_kept`.
- **§120 — модель формы** (`registry_form.dart`, обход по образцу `formWalk`
  лаунчера): общая секция входит только через `form` ref-поля
  (`_mergeRefAttrs` переносит `form`, `{}` тоже), поле с `forbidden_for`/
  `allowed_for` схемы отпадает с поддеревом, `exclude_fields`; блок поля
  секции без своего — блок ref-поля; вариантная секция — синтетический
  дискриминатор (`FormFieldSpec.discriminator`, `enum` из `""` и вариантов
  без `exclude_variants`, порядок — `values` секции,
  `FieldSchema.variantValues`) и поля всех вариантов (`variant`,
  `variantOf`), `stateOf` берёт вариант по текущему дискриминатору;
  `FormLayout.fixed` накладывается перед вычислением, путь не рисуется;
  `formBodyForSave` его пишет; массив объектов с `form` — элемент `[0]`,
  числовой сегмент в `formValueAt`/`withFormValue` (дополнение массива,
  снятие единственного пустого элемента); `activeFormOption` — самое длинное
  совпадение; `FormLayout.write` — значение + `form.implies`. Поля групп
  выбора помечены `choiceId`, `block` у них `null` (как раньше). «Задан» —
  не `null` и не строка из пробелов.
- **п. 7 — `headers` ws/httpupgrade:** `Host` описан, прочие заголовки идут
  через `*` без `unknown_key` — работало с волны A (`hasWildcard` читает
  сырые `fields` варианта), закреплено тестом.
- **п. 11 — тело формы не авторское.** Узел из формы Add server — свой
  сервер с телом `singbox_outbound`, то есть авторский: мягкие правила на нём
  не работали бы. `formBodyForSave(scheme, entry)` — `fixed` + санитайзер со
  входом `other`; экран OpenConnect сохраняет его результат. Вставка JSON
  руками — без изменений.
- Тесты: `form_corpus_test.dart` (все 9 файлов `corpus/form`, кейсы
  `write` → `expect.body`), `registry_form_test.dart` (группа «контракт
  1.1.123»), `registry_wildcard_test.dart` (headers, `{}`, авторское тело),
  `openconnect_form_entry_test.dart` (сохранение через `formBodyForSave`).
  Новых форм UI для других протоколов нет.

### B. Форма «Add server → OpenConnect» и правка узла

Макет и правила — SPEC 167 §2.3 лаунчера, три блока:

- **Блок 1** (всегда виден): Name, Gateway (выбор `flavor`: FortiGate
  (fortinet) · Cisco AnyConnect (anyconnect) · GlobalProtect (gp) · F5 (f5) ·
  Pulse (pulse) · Juniper (nc), по умолчанию fortinet), Server (подсказка
  «host:port or full URL; port 443 if omitted»), Username, Password (скрыт,
  глазок; подсказка «If the gateway asks for a code, you will be prompted
  on connect»).
- **Security** (раскрыт): Server certificate — три радио из `form.choices`:
  System CA (ничего не пишет) / Pinned fingerprint (`tls.peer_fingerprint`,
  через запятую → массив) / Do not verify (`tls.insecure: true`, с
  предупреждением `tls_insecure`); SNI; Group / Realm (скрыт при fortinet
  через `visible_when`); чекбокс Disable SSO (external auth).
- **Advanced** (свёрнут): TCP only (no DTLS), User-Agent, Hostcheck (только
  fortinet), MTU (576…1500), DPD interval, Reconnect timeout, Disable IPv6,
  Allow legacy crypto (с предупреждением `openconnect_insecure_crypto`).

Правила:
- Раскладка, видимость, обязательность, диапазоны и варианты — из модели
  формы волны A (реестр), не захардкожены. Подписи и подсказки — английские
  строки LxBox с переводами RU/ZH по правилам l10n, не `desc_*` реестра.
- Пустое поле ключ не пишет. Форма пишет только поля с `form`; прочие
  ключи тела (`token`, клиентский сертификат, `cookie`, `detour`, `system`,
  `csd`/`hip`/`tncc`, …) не трогает и не теряет при правке. Скрытое поле из
  тела не снимается.
- Server не разбирается на host/port, `https://` не дописывается.
- Сохранение — тем же путём, что у соседних ручных форм (socks/http/
  Tailscale): санитайзер по реестру с показом предупреждений, ядро — на
  сборке.
- **Правка узла:** если у соседних ручных протоколов есть правка формой —
  OpenConnect правится той же формой, предзаполненной из тела; если правка
  у них только через JSON — так же и здесь. Новый UI-блок — по образцу
  соседних форм на том же экране, без собственных кнопок Save.
- JSON-вставка (`_buildJsonPaste`) после волны A принимает узел
  `openconnect` без правок — проверить кейсом из «Фактов».

**Волна B — выполнено (15.10.2026).**

- Вкладка **OpenConnect** в Add server (`add_server_wizard_screen.dart`,
  последняя, индексы прежних вкладок не сдвинуты): Tag как у соседних форм
  (необязателен, по умолчанию `openconnect`, эмодзи-пикер), дальше блоки
  `form.blocks` реестра — первый без заголовка, Security раскрыт, Advanced
  свёрнут. Поля и порядок — `fieldsIn(block)`, видимость/обязательность/
  диапазон — `stateOf(body)`, группа сертификата — `choicesIn(block)`.
  Экран держит только подписи: поле формы реестра без подписи экрана не
  рисуется (`token.*`, `tls.*_path`, `client_key_password` — вне формы).
  Gateway по умолчанию `fortinet`. Булево пишется только `true`.
  Предупреждения — `formAdvisoryCodes` + `registryTitle` (тексты реестра).
- Сохранение: `{type, tag, …тело формы}` JSON-текстом в
  `addFromInput(origin: manual)` — ровно путь вставки sing-box JSON
  (разбор своего тела, санитайзер, `endpoints[]` по `kind`). Сохранение
  не идёт, пока у показанных полей есть `missing`/`outOfRange`.
- Правка узла: у socks/http/Tailscale правка полей только через Source
  (JSON), форм правки нет — OpenConnect так же, формой не дублируется.
- В `registry_form.dart` добавлены `formInputValue` (текст → значение:
  пусто → `null`, `int` → число, секрет не обрезается) и `formListInput`
  (через запятую → список).
- Тест `test/contract/openconnect_form_entry_test.dart`: форма собирает
  эталон из «Фактов», пустое ключ не пишет, видимость по flavor, варианты
  сертификата, правка не теряет `token`/`cookie`/`detour`/`tls.client_*`,
  сохранение формой = вставка эталона (оба — `Endpoint`, тела равны, без
  `server_port`).
- Эмулятор (добавить узел формой, сверить тело в Debug API) не гонялся.

### B2. Форма OpenConnect на вкладке Source правки узла

Решение владельца 15.10.2026 (после первой проверки на эмуляторе: «где же
все настройки?», «сверху должна быть форма настройки на этой вкладке»).
Отменяет пункт B «правка узла — как у соседей, только через Source».

- В экране узла (`node_settings_screen.dart`) на вкладке **Source** у узла
  `openconnect` **над** редактором JSON — та же форма, что во вкладке
  OpenConnect в Add server: те же три блока, поля, подписи, подсказки,
  видимость, варианты сертификата, предупреждения. Код формы один на оба
  экрана (вынести общий виджет), не копия.
- Форма и JSON — одно тело: правка поля формы переписывает текст источника
  (через `withFormValue`/`applyFormOption`, прочие ключи — `token`,
  `cookie`, `detour`, `tls.client_*`, сквозные — не трогаются); правка JSON
  руками обновляет форму. Источник истины — текст `_sourceCtrl`, как у
  секции маскировки AWG.
- Пока текст источника не разбирается как JSON-объект — форма неактивна с
  одной строкой пояснения, JSON-редактор работает как раньше.
- Сохранение — существующая кнопка Save в шапке экрана, своих кнопок у
  формы нет. Tag правится там же, где сейчас (Settings), в форму не
  дублируется.
- Остальные протоколы — без изменений.

**Волна B2 — выполнено (15.10.2026).**

- Форма вынесена в общий виджет `OpenConnectForm`
  (`app/lib/widgets/openconnect_form.dart`): блоки, поля, подписи,
  подсказки, варианты сертификата, предупреждения; тело — у владельца,
  правка поля отдаёт новое тело. Визард держит Tag и `_ocBody`, поведение
  прежнее (`openConnectFieldShown` — для проверки перед сохранением).
- Экран узла: у узла `openconnect` форма над редактором Source в
  `ListenableBuilder(_sourceCtrl)`. Текст ↔ тело —
  `app/lib/services/contract/form_source_sync.dart`: `formBodyFromSource`
  (объект JSON, не документ с `outbounds`/`endpoints`; иначе `null` —
  форма неактивна, строка «The form is off: Source is not a valid JSON
  object.», показано последнее разобранное тело), `sourceWithFormBody`
  (однострочный текст — компактно, многострочный — с его отступом; порядок
  ключей прежний, новые в конец; `type`/`tag` из прежнего текста).
  Контроллеры полей формы не пересоздаются: текст поля меняется, только
  если тело пришло извне (не эхо последней правки формы) и значение поля
  с ним разошлось. `Required` у пустых обязательных показывается сразу.
- Тест `test/contract/openconnect_source_form_test.dart` (чистая логика):
  компактность и отступ, порядок ключей, `token`/`cookie`/`detour`/
  `tls.client_*`/сквозные сохраняются (в том числе при смене варианта
  сертификата), не-объект → `null`.
- Эмулятор (правка узла формой, сверка Source и тела после Save) не
  гонялся.

### C. Второй фактор и SSO через libbox

**Волна C выполнена (15.10.2026).** Реализация:
- подписку держит натив (`BoxCommandClient.syncOpenConnectStatus`): после
  старта VPN и после reload — по наличию endpoint'а `openconnect` в
  конфиге; снимается в `shutdownAll`. В отличие от Tailscale Dart её не
  поднимает: челлендж приходит сразу после старта, а старт бывает с
  QS-плитки без Flutter-движка. Канал `lxbox/cc/openconnect` несёт снапшот
  `{endpoints, callback}`, `ccGetOpenConnectStatus` отдаёт текущий;
- уведомление «Sign-in required: <tag>» ставит натив (канал уведомления
  VPN, своё id на тег), снимает, когда челлендж исчез; тап → экстра
  `openconnect_tag` → Dart забирает (`ccTakeOpenConnectOpenRequest`) на
  старте и при возврате;
- слушатель SSO — в нативе (`OpenConnectCallbackServer.kt`, только
  127.0.0.1), пойманный URL отдаёт ядру сам, без Dart; гаснет при ответе,
  «Not now», смене/исчезновении челленджа и остановке VPN;
- диалоги и метка узла — `lib/screens/home/openconnect_auth_ui.dart`,
  метка — на месте подписи состояния endpoint'а в строке узла (`node_row`);
  чистая логика (порт из префиксов, режим, счётчик неверных кодов, ответ
  формой, метка) — `lib/services/openconnect_auth.dart`, юниты
  `test/services/openconnect_auth_test.dart`.

Не проверено: реальный челлендж и SAML (нужен шлюз владельца); на
эмуляторе подписка не прогонялась.

Канал есть всегда (libbox CommandClient), в отличие от лаунчера в
классическом режиме.

1. **Подписка статуса OpenConnect** по образцу Tailscale (§579/§645,
   `BoxCommandClient.kt`): подписка живёт, пока VPN запущен и в конфиге есть
   хотя бы один узел `openconnect`; снимается при остановке. Состояние
   endpoint (`auth-pending`, `connected`, `error` с текстом) доступно Dart.
2. **Где человек видит:** при `auth-pending` — системное уведомление
   «Sign-in required: <tag>» (тап открывает приложение с диалогом) и
   диалог в приложении, если оно на экране. Диалог появляется сам только
   при новом `challenge.id`; закрытый «Not now» снова открывается тапом по
   уведомлению или по метке у узла. Висящий челлендж показывается при
   открытии приложения (стрим отдаёт текущее состояние). У узла в списке —
   метка состояния («Waiting for sign-in» / текст ошибки) там, где узел уже
   показывает своё состояние; новый блок — по образцу соседних.
3. **Форма челленджа** (`challenge.form`): поля как прислало ядро (kind
   text/password/select с `options`, `label`, `value`), сверху `banner`,
   `message`, `error` ядра. Кнопки: **Submit** (`SubmitOpenConnectAuthResponse`
   с form values), **Not now** (только закрывает, в ядро НИЧЕГО не шлёт),
   **Request a new code** (явный `Cancel…` с подтверждением «The gateway
   will send a new code»). После двух неверных кодов подряд на одном узле —
   предупреждение о повторных логинах. Если форма принесла поле пароля —
   подсказка, что пароль в узле, вероятно, неверен (сохранение нового
   пароля в узел — не в этой задаче).
4. **SSO, callback-режим** (`browser.callbackURLPrefixes` непустой и
   loopback — FortiGate SAML): диалог «Sign in in your browser» с кнопкой
   **Open** (внешний браузер / Custom Tabs), ссылкой для копирования и
   ожиданием. На время челленджа приложение слушает `127.0.0.1:<port>`;
   порт из префикса, если указан, иначе 8020 (как FortiClient). Ключ порта
   в тело узла НЕ заводить — через `*` уйдёт в ядро, ядро незнакомые поля
   отвергает. Пойманный URL редиректа → `BrowserResult{finalURL}` → Submit;
   браузеру — короткая страница «You can return to the app». Слушатель
   закрывается при ответе, отмене или исчезновении челленджа; занятый порт
   — ошибка в диалоге, не падение.
5. **SSO, cookie/header-режим** (AnyConnect и др.): диалог «SSO for this
   gateway type is not supported yet», без Cancel.
6. Терминальная ошибка endpoint — текст ошибки у узла; §478 (автоснятие)
   на это не распространяется: это не отказ ядра принять конфиг.

## Вне задачи

SSO cookie-режим (встроенный WebView с чтением cookie — на Android
реализуем, отдельной задачей при запросе); кнопка «Fetch fingerprint»;
импорт профилей FortiClient; URI-схема; `token.*` и клиентский сертификат
в форме; сохранение нового пароля из челленджа в узел; `system: true`.

## Риски и края

- Wildcard ослабляет гард: опечатка в неописанном ключе openconnect уйдёт в
  ядро и уронит конфиг на декодировании — это ловит §653 (индекс → тег →
  автоснятие).
- Подписка статуса на узле, который ни разу не стартовал (выключен), не
  нужна — только по фактическому составу запущенного конфига.
- Браузер на Android может открыть ссылку 127.0.0.1 в другом профиле/
  приложении — проверить, что редирект доходит до нашего слушателя при
  включённом VPN (loopback мимо tun).
- Параллельные исполнители B/C пишут в общие l10n-файлы — конфликт при
  rebase решает тот, кто вливается вторым.

## Проверка

- A: раннеры корпуса тела, авторского тела, нового корпуса формы,
  структурные тесты реестра — в CI; локально только свои новые/изменённые
  тест-файлы. Подпись `openconnect·fortinet` — юнит на `_deriveTransport`.
- B: юниты модели формы (видимость `auth_group`/hostcheck по flavor,
  варианты сертификата, пустое поле не пишет ключ, правка не теряет
  `token`); на эмуляторе — добавить узел из «Фактов» формой, сверить тело
  в Debug API с эталоном.
- C: юнит разбора `callbackURLPrefixes` → порт; на эмуляторе без реального
  шлюза — подписка поднимается/снимается вместе с VPN, без ошибок в логе.
  Реальный челлендж — только у владельца на его FortiGate.

## Не решено / дальше

- 15.10.2026, эмулятор: туннель FortiGate встаёт за ~10 с (DTLS по UDP не
  проходит, ядро ждёт ~8 с и уходит на TLS); стартовый пинг успевает
  отметить узел `-1`, повторный — 1194 мс. Повторный пинг после
  `connected` владелец решил НЕ делать; обход — «TCP only (no DTLS)» в
  Advanced.

- Живой прогон второго фактора и SAML на FortiGate с MFA — у владельца.
- SSO cookie-режим (AnyConnect) через WebView.
