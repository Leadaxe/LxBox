# 533 — контракт 1.1.53: синк, снятие оверлеев, полная сверка тел

| Поле | Значение |
|------|----------|
| Статус | **Done** (шаги 1–7), три отступления оставлены с обоснованием |
| Дата | 2026-09-24 |
| Основание | `contract/TASKS_LXBOX.md` §49 (контракт 1.1.53), ревизия зеркала `SPECS/133-F-N-REGISTRY_DRIVEN_LINK_MAPPER/REVIEW_LXBOX_MIRROR_2026-09-24.md` |
| Нормативка | `MAPPER_ENGINE.md` §7.1 (коллизии), `PRIMITIVES.md` §0.12a (булев словом), `PARSING_PRINCIPLES.md` §2.1-2.3, `DELTAS.md` |
| Связанные | §480 (переезд на движок), §514 (исполнение 1.1.50–1.1.52), §532 (примитивы движка) |
| Источник синка | лаунчер `f3cd4c93`, `contract/VERSION` = 1.1.53 |

---

## Рамка

Ревизия зеркала 24.09.2026 одной строкой: **зеркало реестра совпадает байт в
байт, а настоящие расхождения живут рядом** — в 27 файлах
`app/assets/contract_draft/**` и в семантике примитивов Dart-движка. Ни синк,
ни lock-проверка их не видели; раннер тел сравнивал только СОСТАВ узлов.

Правило, из которого выросла волна: **оверлей — это заявка на дельту, а не
способ жить иначе.** Каждая запись `contract_draft` обязана нести ID дельты.

Эталон — Go-исполнение в лаунчере. Где решение было неочевидным, оно
принималось **прогоном `linkmap.Emit` / `ParseURI` на `origin/develop`
лаунчера**, а не сверкой со своим снимком: снимок фиксирует наше прошлое, а
вопрос стоял «как правильно».

---

## Шаг 1. Синк до 1.1.53

`app/contract.lock` → `source_sha=f3cd4c93`, `sha256=aa12eb92…`. Обновлены
`app/assets/contract/**` (30 файлов реестра) и `docs/contract/**`.

Гарды: `check_contract_lock` (три сверки — вендор, зеркало реестра, зеркало
документации), `registry_sync_test`, `registry_invariant_test`,
`docs_mirror_test` — зелёные. В `registry_load_test` поднята версия-пин.

**Базовая линия отказов** снята на ЧИСТОМ дереве до синка (17: 5 URI + 12
тел) и сразу после (20). Три новых — кейсы, приехавшие с 1.1.53:
`anytls/sni_label_falls_back_to_server`, `xray/hysteria_version_3_unrecognized`,
`xray/reality_key_share_not_carried`.

## Шаг 2–3. Движок: §7.1 и предикат `absent`

**§7.1 — запись под условием (`when`) не переопределяет запись блока.**
Правило было отложено задачей 532 (дефект 3): оно возвращало `tls.server_name`,
снятый записью `disable_sni`, и меняло identity `b480:disable_sni_with_sni`.
Дыру закрыл РЕЕСТР, а не движок — контракт 1.1.53 повесил тот же гейт
`query.disable_sni.not_in` на саму блочную запись `tls#uri.sni` (§49 п.25,
находка задачи 532). Правило взято; `before_480_identity_snapshot` зелёный.

**`absent` в условиях `when`** (эталон `exec.go:2159-2161`). Контракт 1.1.53
объявил им гейт «отрицательный ИНТЕРВАЛ выключает keep-alive только при
незаданном idle» (`dialer.json`, `disable_tcp_keep_alive_by_interval`).
Предиката у нас не было вовсе, и запись не исполнялась НИ РАЗУ: неизвестный
ключ условия уходил в `return false`.

**Две починки эмита, которые вскрыл синк:**

1. **Ключ контейнера достаётся БЕЗУСЛОВНОЙ записи вперёд условной.** 1.1.53
   завёл у схемы-контейнера фолбэк адреса на `transport.host` над тем же
   ключом и ВЫШЕ записи адреса сервера. Условие фолбэка тело узла без
   транспорта не опровергает, и ключ уходил ему — **ссылка уезжала без адреса
   сервера**, то есть узел, которым нельзя поделиться.
2. **`omit_default` у параметра, чью истину несёт САМО НАПИСАНИЕ СХЕМЫ**
   (`emit.form_from`), снимает его при любом значении. Иначе каждая
   `proxy-http`-ссылка получала хвост `?security=none`, которого эталон не
   пишет (сверено прогоном). Ветка-ОТРИЦАНИЕ у прочих схем пишется как прежде
   — страж `engine_emit_primitives` «sets⁻¹» это держит.

## Шаг 4. Раннер тел сравнивает ТЕЛО ЦЕЛИКОМ

`body_contract_test` сверял `схема|сервер|порт`. Теперь `entry` узла
сравнивается глубоко (`canonEncode`, PARSING_PRINCIPLES §2.1-2.3), как у URI-раннера, с
приоритетом `.expected.lxbox.json` над общим ожиданием. Узлы соотносятся по
подписи; у тел с несколькими одинаковыми подписями сверяются СПИСКИ тел.

**Предупреждения — множеством кодов, как было.** Порядок строго по реестру не
вводился: PARSING_PRINCIPLES §6 (и дельта D133-39) объявляет порядок слоёв — коды маппера с
`maps_to: null` впереди кодов тела, — и движок уже склеивает слои так
(`mergeWarnings`). Известный отказ «порядок warnings[]» этим и закрыт: он был
не про порядок, а про то, что раннер не видел тела.

Включение глубокой сверки подняло отказы с 14 до 30 — это и есть те самые
пункты 10–13 ревизии, которые раннер молчал.

## Шаг 5. ID дельт

Ключ `_delta_id` (с подчёркиванием: набор ключей записи заморожен
`mapper_sections_draft_test`, и всё, что не грамматика, объявляется именем с
подчёркиванием — правило `_why`). Гард —
`app/test/contract/draft_overlays_have_delta_id_test.dart`: краснеет на записи
без ID и на ID не той формы. **Существование строки под этим ID в `DELTAS.md`
судит раннер лаунчера**: файл в зеркало LxBox не едет (в git только
`registry/**` и `docs/generated/**`), и читать его из соседнего репозитория на
CI нельзя — там его нет.

Три ID заявлены ЭТОЙ волной и строк в DELTAS ещё не имеют —
**лаунчеру нужно их завести**: `D533-anytls-security-always-tls`,
`D533-xray-reality-utls-required`, `D533-wg-awg-scheme-spelling`.

---

## Таблица снятых оверлеев

| Оверлей | §49 | Почему снят | Кейс корпуса |
|---|---|---|---|
| `singbox/*` — 13 файлов | п.9 | секции приехали в реестр (`mappers.singbox` у каждой схемы) | состав отказов ПОБАЙТНО тот же (20/20) |
| `registry_mapper.schema.json` | п.10 | старая правленая копия схемы, кодом не используется | — |
| `uri/http` `$security_none_https` | п.1 | лаунчер разделил блок (`tls#uri_security`), у нас заработало §7.1 | `uri/http/proxy_https_security_none_drops_tls` |
| `uri/transports` `blocks.uri.xhttp` (3× `emit_as: raw`) | п.3 | булев без `emit_as` пишется СЛОВОМ (PRIMITIVES §0.12a) | `uri/vless/xhttp_bool_default_spelled` |
| `uri/transports` `blocks.xray.ws.ed/eh` | п.5 | Xray таких полей у `wsSettings` не объявляет | `body/xray/ws_ed_flat_only`, `ws_eh_without_ed` |
| `uri/transports` `blocks.xray.ws.host` | п.7 | оверлей читал только `headers.Host`, терял плоский `wsSettings.host` | `body/xray/*` (тела сошлись) |
| `uri/transports` `blocks.xray.xhttp` (sessionPlacement/Key) | п.8 | реестр читает плоскую форму с 1.1.50 — оверлей СТАРШЕ реестра | тела сошлись |
| `uri/dialer` целиком (sockopt) | п.6 | наш `disable_tcp_keep_alive` на паре `idle:30 + interval:-5` был ошибкой | `body/xray/sockopt_keepalive_negative_interval{,_only}` |
| `uri/tls` `$sni_from_server` | п.4 | 5 узлов корпуса ждут ОТСУТСТВИЯ `tls.server_name` | `body/xray/vless_reality_key_share` |
| `uri/tls` `blocks.xray` fp/insecure/pbk/`$key_share_not_carried` | §3 п.15 ревизии | реестровый блок ШИРЕ (19 записей против 5) | тела сошлись |
| `uri/anytls` `sni` | п.11 | реестр несёт запись сам; наш `when` делал её условной, и по §7.1 блочная (без эвристики) выигрывала путь | `sni_heuristic_falls_back_to_server` снова исполняется |
| `uri/anytls` `emit.names: insecure→allowInsecure` | п.11 / D133-E2 | имя флага — свойство СХЕМЫ, anytls — протокол sing-box | чтение обеих форм сохранено (8 написаний в `source`) |
| `uri/naive` целиком (`omit_port: 443`) | п.12 | реестр порт ПИШЕТ, у лаунчера `hostPort` писал всегда | 15 кейсов вида ссылки в `allowed` |
| `uri/wireguard` `omit_default: server_port` | п.13 | дефолта порта в секции нет — запись ничего не выражала | — |
| `uri/shadowsocks` целиком (`padding: false`) | п.17 / D133-E11 | реестр объявил паддинг ЛОЖЬЮ — прав оказался LxBox, оверлей стал равен реестру | `shadowsocks/sip002_*` |
| `xray/shadowsocks` (`empty: significant`) | п.14 | у реестра `required: true` — рубеж против плейсхолдеров просроченной подписки | состав отказов не изменился |
| `uri/trojan`, `uri/vless` (`omit_default`) | п.16 / D133-E10 | `security` пишется НОРМОЙ РЕЕСТРА (`emit_when: always` / снятое исключение) | 53 кейса вида ссылки в `allowed` |
| `xray/trojan`, `xray/vless` (пустые) | — | `forms` сняла задача 532, исполняемых ключей не осталось | — |
| `uri/vmess` keep-alive ×3 + `http_host_from_server` | п.19 | контракт забрал их в реестр ПОБАЙТНО | тела и круг сошлись |

**30 файлов → 5.**

## Что ОСТАВЛЕНО и почему

| Оверлей | ID | Обоснование |
|---|---|---|
| `transports` `blocks.uri.ws.ed/eh` | `D-008` | объявленная дельта с парными `.expected.lxbox/.launcher` в корпусе; §49 её к снятию НЕ относит («ждёт владельца»). Снятие меняло identity `ws_ed_query_param` |
| `tls` `blocks.xray.security` | `D533-xray-reality-utls-required` | REALITY требует uTLS-блок — ядро отвечает fatal «uTLS is required by reality client». У реестровой ветки `reality` только `tls.enabled`, и реестр сам судит такое тело кодом `field_requires`. **Кейса «reality без fingerprint» в корпусе НЕТ** (ревизия §3 п.15 просит завести) — снятие опиралось бы на догадку |
| `anytls` `security` | `D533-anytls-security-always-tls` | anytls живёт только поверх TLS (`body.fields.tls` required, ядро отвечает `C.ErrTLSRequired`); ветка блока `{"tls": null}` унесла бы весь блок, и санитайзер отверг бы узел целиком |
| `vmess` `emit` (`json_map: null`, `param_order`, `json_always`) | `D133-E12` | дельта прямо объявляет: до поддержки ссылок `=…`/`$label`/`$param.<имя>` вид ссылок vmess обязан остаться прежним |
| `vmess` `unknown_key`, `type`, `headerType` | `D133-16` | истинность `tls` разведена по формам; у контейнера `type` — обфускация заголовка, а транспорт лежит в `net` |
| `tls` `blocks.uri.ech`, `blocks.uri_with_host.sni` | `D133-21`, `D133-19` | объявленные дельты прошлых волн |
| `wireguard` `emit.form_from` | `D533-wg-awg-scheme-spelling` | решение владельца о написании схемы AWG-узла, к синку не относится |

### `_isUntranslatedCanon` (§49 п.15) — ОСТАЁТСЯ

§49 просит снять по §46 п.7. Снятие проверено и откачено — **сверкой с
эталоном, а не со своим снимком**. Без признака вид ссылок расходится на 9
кейсах: `flow=xtls-rprx-vision` → `xtls-rprx-vision-udp443`, `type=xhttp` →
`splithttp`. Прогон `linkmap.Emit` на `origin/develop` лаунчера на тех же
телах даёт РОВНО ТО, что пишем мы С признаком.

То есть признак — не отступление LxBox, а недостающая у нас часть ОБЩЕГО
поведения: снять его значило бы РАЗОЙТИСЬ с эталоном. Снятие возможно только
вместе с тем, чем Go выражает неинъективность таблицы без тождественной пары,
а это работа лаунчера — грамматика FROZEN.

---

## Ответы на вопросы §49

**§A.20 — исполняет ли Dart `on_invalid: {action: "default_from"}`?**
**ДА, исполняет** (`interpreter.dart:1842-1847`): при `action == 'default_from'`
и совпавшем предикате `when.value` запись ведёт себя так, будто значения не
было, и дальше срабатывает её же `default_from`. Это выбор ИСТОЧНИКА, а не
суждение о значении.

Go его НЕ исполняет — проверено прогоном: `anytls://p@h.example:443/?sni=localhost`
даёт у эталона `server_name: "localhost"`, а `?sni=🔒` — `server_name: "🔒"`.
Поэтому кейс `uri/anytls/sni_label_falls_back_to_server` (ожидание
`server_name: "Germany"`) у нас КРАСНЫЙ: мы даём `any.example-1.com`.

**Паритет здесь — поведение сегодня, и реализовывать ничего не надо: примитив
у нас уже есть.** Кейсу нужен **per-app override** `.expected.lxbox.json` со
`server_name` = адрес сервера — ровно та развилка, которую §49 и называет
(«если ваш движок действие исполняет — скажите»). Файлы `.expected.lxbox.json`
живут в репозитории лаунчера, и завести его может только он.

**§A.9 — исполняет ли Dart предикат `has_key`?**
**ДА, читается — как ПРЕЖНЕЕ НАПИСАНИЕ того же предиката**
(`interpreter.dart:859`: `(j['required_keys'] ?? j['has_key'])`). FROZEN-имя —
`required_keys` (GRAMMAR_SYNC §4 №7), и новые секции пишутся только им; `has_key`
принимается ради старых. Лишнего примитива у нас нет: это одно имя в двух
написаниях, а не два разных предиката.

Следствие для §49 п.9: формы `endpoint` у `wireguard`/`tailscale` срабатывали у
нас и ДО правки реестра, поэтому замена `has_key` → `required_keys` состав
узлов не изменила — что и подтвердилось побайтно равным составом отказов.

---

## Состояние раннеров

| Раннер | До синка | После синка | Итог |
|---|---|---|---|
| `contract_test` (URI) | 5 | 6 | **6** |
| `body_contract_test` (тела, СОСТАВ) | 12 | 15 | — |
| `body_contract_test` (тела, ТЕЛО ЦЕЛИКОМ) | — | 30 | **27** |

Полностью зелёными оба раннера не стали. Ни один из оставшихся отказов не
вызван этой волной: они либо приехали с 1.1.53 как новые кейсы, либо
существовали до неё, либо вскрыты включением глубокой сверки. Разбор:

### URI-раннер (6)

| Кейс | Причина |
|---|---|
| `anytls/sni_label_falls_back_to_server` | **дельта**: Dart исполняет `on_invalid: default_from`, Go — нет (см. ответ на §A.20). Нужен `.expected.lxbox.json` у лаунчера |
| `naive/empty_host_rejected`, `socks/socks5_base64_userinfo{,_colon_password}`, `vmess/not_base64_rejected`, `wireguard/amneziawg_scheme_full_name` | предсуществующие, в базовой линии ДО синка |

### Раннер тел (27)

| Группа | Кейсы | Причина |
|---|---|---|
| Подстановка `server_name` с адреса сервера (6) | `xray/dialer_chain_vless_relay`, `multinode_310`, `ws_ed_flat_only`, `ws_ed_path_tail_beats_flat`, `ws_eh_without_ed`, `reality_key_share_not_carried` | `json_parsers.dart:1434` — откат МОДЕЛИ (§472 шаг 5), чтобы у обычного узла стояло имя, которое ядро и так подставит. **Снятие меняет identity** (`before_480_identity_snapshot`, trojan; `engine_xray_pilot`) — по рамке задачи СТОП |
| Поля, которых модель не несёт (8) | `singbox/dialer_tcp_keep_alive` (`fallback_delay`, `network_type`…), `xray/mux_concurrency` (`multiplex`), `shadowsocks_uot` (`udp_over_tcp`), `vmess_security_junk`/`vmess_tls` (`alter_id`), `wireguard_settings_full` (`workers`), `wgconf/ini_no_allowedips` (`listen_port`), `xray/balancer_group` | предсуществующие пробелы модели, к §49 не относятся |
| Лишние поля модели (3) | `singbox/socks_version_{absent,invalid}` (`version`), `list_non_string_items` (`server_ports`) | то же, в обратную сторону |
| Санитайзер TLS (4) | `singbox/outbound_array_tls_fields`, `tls_alpn_item_nonstring`, `tls_disabled_block`, `list_non_string_items` | разная строгость судьи, предсуществующее |
| Предсуществующий разрыв Xray-входа (6) | `hysteria_v1_skipped`, `malformed_stream`, `unsupported_protocol`, `socks_settings_users`, `vless_encryption_junk`, `hysteria_version_3_unrecognized`, `hysteria2_bandwidth_…` | §49 п.C.4 просит починить в 533 — **не сделано**, см. ниже |

### Что осталось (честно)

1. **Разрывы Xray-входа** (`xray/hysteria_v1_skipped`, `xray/malformed_stream`)
   — §49 п.C.4. Не сделано: оба требуют разбора того, почему LxBox не даёт
   узла там, где лаунчер даёт, и это отдельная работа по отбору
   `_xrayToSpec`, а не снятие оверлея. Оба были красными ДО синка.
2. **Подстановка `server_name`** — уперлась в запрет менять identity.
   Развилка за владельцем: либо дельта с per-app override, либо смена
   identity отдельной волной с миграцией.
3. **Пробелы модели** (`multiplex`, `udp_over_tcp`, `alter_id`, `workers`,
   `listen_port`, `network_type`…) — вскрыты глубокой сверкой, к §49 не
   относятся, каждый стоит отдельной задачи.
4. **`.expected.lxbox.json` завести нечем**: файлы живут в репозитории
   лаунчера, LxBox открыт на чтение.

## Эталон корпуса публичных подписок (§525)

После влития CI на `d9008135` покраснел `PublicSubsCorpus`: из 68 подписок у 47
изменилось только число `warnings.uri_param_unknown`, и только вниз (сумма по
корпусу 9300 → 7858; у 14 подписок предупреждение ушло совсем, например
`01-github-vless-universal` 3 → 0, `24-github-bypass-5` 1166 → 534). Реестр
1.1.53 объявляет параметры URI, которые 1.1.52 считал незнакомыми. Число узлов,
`dropped` и прочие предупреждения не сдвинулись. Эталон переписан регламентом
раннера (`LX_CORPUS_UPDATE_EXPECTED=1`), вместе с ним `contract_version`
1.1.52 → 1.1.53.
