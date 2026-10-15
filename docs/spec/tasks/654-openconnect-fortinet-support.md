# §654 — OpenConnect (FortiGate и др.): контракт 1.1.122, форма Add server, второй фактор и SSO

| Поле | Значение |
|------|----------|
| Тип | F (новая возможность: протокол `openconnect`) |
| Статус | In progress |
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

### C. Второй фактор и SSO через libbox

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

- Живой прогон второго фактора и SAML на FortiGate с MFA — у владельца.
- SSO cookie-режим (AnyConnect) через WebView.
