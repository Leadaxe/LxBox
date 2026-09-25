# 529 — корпус контракта 1.1.55: разбор локально красных кейсов

| Поле | Значение |
|------|----------|
| Статус | In progress (диагностика закрыта; правки и запрос лаунчеру — следующими шагами) |
| Дата старта | 2026-09-25 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | tasks/512, tasks/514, tasks/533, tasks/544; `app/contract/docs/CANON.md`, `IDENTITY.md`, `corpus/README.md` |

## Проблема

При локальном прогоне корпуса контракта 1.1.55 (`app/contract` = лаунчер
`1cdb3279`) красные:

- `test/contract/contract_test.dart` (URI) — `+369 ~9 -6`;
- `test/contract/body_contract_test.dart` (тела) — `+113 ~1 -27`.

На CI этого не видно: `app/contract/` gitignored, корпусные раннеры там
пропускаются (`corpusTestSkip`). Правка §544 (`cf61158a`) ни при чём: кейсы
красные и без неё.

## Диагностика

**Корпус не «давно не гонялся».** Состав красных совпадает ПОКЕЙСОВО с
остатком §533 («Состояние раннеров»: URI 6, тела 27). Часть тянется с §512/§514.
Новых расхождений с 1.1.53 не появилось. Остаток не разбирали: в §533 записано
«каждый стоит отдельной задачи». Запросы лаунчеру из §514/§533 до сих пор не
выполнены: `.expected.lxbox.json` у socks5-base64 и anytls в корпусе нет.

Порядок: контракт восстановлен `bash app/tool/sync_contract.sh` (sha256 совпал с
`contract.lock`). Раннеры прогнаны по одному файлу Sonnet-субагентом, каждый
кейс разобран Opus-субагентами по реестру, CANON и эталону Go
(`git show 1cdb3279:…`) без правок кода.

Классы: **A** — LxBox отстаёт, чинить Dart; **B** — фикстура/норма, запрос
лаунчеру; **C** — решение владельца; **D** — дефект раннера.

### URI-раннер (6)

| Кейс | Класс | Расхождение → причина |
|---|---|---|
| `anytls/sni_label_falls_back_to_server` | B | want `server_name:"Germany"`. Реестр (`anytls.json` `sni.on_invalid: default_from`) даёт адрес сервера; прав Dart (`interpreter.dart:1842`). В Go `default_from` не исполняется, и шапка фикстуры сама говорит «по факту, не по норме» |
| `socks/socks5_base64_userinfo{,_colon_password}` (2) | B | Отличается только `scheme` (`socks`↔`socks5`), IDENTITY §4a класс C. У шести соседних кейсов `.expected.lxbox.json` есть, у этих двух — нет |
| `naive/empty_host_rejected` | A | want `reason:emit_error, code:field_missing`. Санитайзер в ветке отсутствующего поля не разрешает `ref: dialer.common` и не видит `required` (`body_sanitizer.dart:~457`); узел умирает молча в `json_parsers.dart:1034` |
| `vmess/not_base64_rejected` | A | want `field_missing`, got `form_unrecognized`. Go-декодер base64 нестрогий (хвостовые биты), `not-base64` у него декодируется как RawURL; Dart `Base64Codec` строгий (`interpreter.dart:597`, `_tryBase64`). Вопрос §514 §4б закрыт |
| `wireguard/amneziawg_scheme_full_name` | A | `value` у `wgconf_dns_ignored` — по CANON:109 сырое значение до декода. Go отдаёт `+` как есть, Dart — после `_decodeQueryValue` (`interpreter.dart:1893`). Вывод §512/§514 «прав Dart» ошибочен |

### Раннер тел (27)

| Кейс(ы) | Класс | Расхождение → причина |
|---|---|---|
| `singbox/dialer_tcp_keep_alive` | A | Модель не несёт `network_strategy/network_type/fallback_*` (`dialer.json`; `tcp_keep_alive.dart:31`) |
| `wgconf/ini_no_allowedips`, `xray/wireguard_settings_full` | A (listen_port — ждёт решения) | Нет `listenPort`/`workers` в `WireguardSpec`. У `listen_port` реестр сам себе противоречит (URI `ext: desktop`, conf/body без `ext`) → вопрос лаунчеру |
| `xray/mux_concurrency` | A | Нет `MultiplexSpec` в модели (`multiplex.json:140`) |
| `xray/shadowsocks_uot` | A | Нет `udp_over_tcp` у SS (`shadowsocks.json:472`) |
| `xray/vmess_security_junk`, `xray/vmess_tls` | A | `materialize_default: true` (наша же заявка), а модель с `int alterId = 0` и эмиттер `if (alterId != 0)` (`node_spec_emit.dart:155`) ноль от отсутствия не отличают |
| `singbox/socks_version_absent` | A | Дефолт `'5'` материализуется (`json_parsers.dart:1143`, `node_spec_emit.dart:354`), CANON §2.4 запрещает |
| **Группа S:** `singbox/socks_version_invalid`, `list_non_string_items`, `tls_alpn_item_nonstring`, `outbound_array_tls_fields` (часть «пин»), `tls_disabled_block` | A | JSON sing-box идёт в модель мимо санитайзера (§472 шаг 1 «тело не меняется»), CANON §8 требует маппер → санитайзер → эмиттер. Коды санитайзер ставит верно, очищенную карту выбрасывают. Правка — `singbox_config.dart:265` подавать `RegistrySanitizer.sanitize(...).body`, как xray (`uri_pipeline.dart:385`); плюс `toString()` у `alpn`/`server_ports` (`json_parsers.dart:~1439, 537`) |
| `singbox/outbound_array_tls_fields` (часть `disable_sni:false`, `insecure:false`) | A после B | Явные `false` теряются (`kTlsBoolKeys` только `true`). Проза `tls.json emit_allowlist` («булевы только при true») противоречит фикстуре → вопрос лаунчеру |
| `xray/{dialer_chain_vless_relay, multinode_310, reality_key_share_not_carried, ws_ed_flat_only, ws_ed_path_tail_beats_flat, ws_eh_without_ed}` (6) | A, нужно решение владельца | Одна причина: откат `serverName ?? server` (`json_parsers.dart:1434`, §472 шаг 5). У `tls#xray` нет `default_from`. Identity по IDENTITY §1 (тег) не меняется; меняются снапшоты `legacyNodeIdentityHash` (`before_480_identity_snapshot`, `engine_xray_pilot`), дедуп-подпись и `sni=` в `toUri()` |
| `xray/hysteria_version_3_unrecognized`, `malformed_stream`, `unsupported_protocol` | A | Отбраковка элемента Xray уходит warning'ом на соседа или пропадает (§321 P5; `json_parsers.dart:240, 300, 313-329`). CANON §4.1 требует запись в `dropped[]` на каждую |
| `xray/hysteria_v1_skipped` | B | В ожидании нет `meta.extension: desktop` (`hysteria.json:14`, `corpus/README.md:70`) |
| `xray/vless_encryption_junk` | B | want `ref:"enc-junk"` (метка из remarks); по CANON §4.1 ref у JSON-тела — тег outbound (`proxy`), как у соседних кейсов |
| `xray/socks_settings_users` | C | Отбор §321 (socks из Xray — только звено `dialerProxy`, `json_parsers.dart:647`). Оставить → запрос override в лаунчер; снять → узел появится |
| `xray/hysteria2_bandwidth_suffix_finalmask_obfs` | D | Код верен. Раннер: `sortWarningsByBodyOrder` (`corpus_warnings.dart`) опознаёт коды маппера по пути, а не по коду (`json_field_unknown` уезжает за `tls.*`); `normalizeNodeWarnings` сопоставляет по позиции и стирает `value`. Предложение §514 «сортировать по паре» снято: порядок теперь нормирован CANON §6 |
| `xray/balancer_group` | D + B | (D) `AutoSelectSpec.emitRaw` отдаёт `outbounds:[]`, раннер состав не раскрывает. (B) want `outbounds:["bal proxy"]` — тег Go вопреки CANON §5 («члены по label»); `group.json` без секции `body`, лишние `tolerance/idle_timeout/interrupt_exist_connections` не нормированы |

**Итого (33):** A — 25 (из них 6 ждут решения по `server_name`, 1 — ответа по
`listen_port`, 1 частично ждёт ответа по bool'ам TLS), B — 5 (+ B-части у
`balancer_group`, `outbound_array_tls_fields`, `listen_port`), C — 1, D — 2.

## Решение

Диагностика — этот документ. Дальше, отдельными шагами:

1. **Запрос лаунчеру** (пакетом, после решений владельца по п.2):
   - `uri/anytls/sni_label_falls_back_to_server` — исполнить `default_from` в
     `linkmap/exec.go` и перегенерировать ожидание (то же у hysteria2), либо
     `.expected.lxbox.json` с `server_name` = адрес + класс «Dart исполняет
     норму, Go — нет» в IDENTITY §4a;
   - `uri/socks/socks5_base64_userinfo{,_colon_password}` — `.expected.lxbox.json`
     (`"scheme": "socks"`), в IDENTITY §4a «6 кейсов» → «8»;
   - `body/xray/hysteria_v1_skipped` — `meta.extension: "desktop"`;
   - `body/xray/vless_encryption_junk` — `dropped[0].ref` = `proxy` (тег), и Go;
   - `body/xray/balancer_group` — члены по label (CANON §5) или правка §5;
     нормировать поля тела группы / override;
   - `tls.json emit_allowlist` — подтвердить, что явный `false` из тела
     sing-box сохраняется, поправить прозу;
   - `wireguard.json listen_port` — развести `ext` (после решения владельца);
   - `body/xray/socks_settings_users` — override, если §321 остаётся.
2. **Вопросы владельцу:** снимать ли откат `server_name` (6 кейсов, меняются
   снапшоты хеша, не identity); оставить ли §321 для socks из Xray; нужен ли
   `listen_port`/`workers` WireGuard на мобильном.
3. **Правки Dart (A)** — отдельными задачами, по группам: (а) санитайзер для
   JSON sing-box — группа S + `socks_version_absent`; (б) `dropped[]` у Xray-отбраковок;
   (в) URI: naive `required` через ref, нестрогий base64, `value` до декода;
   (г) модель: `alterId?`, dialer-поля, `multiplex`, `udp_over_tcp`,
   `listenPort/workers`; (д) раннер: сортировка по коду, сопоставление
   warnings по `(code, path)`, раскрытие состава группы.

## Риски и edge cases

- Нестрогий base64 затронет `base64?` у ss/socks (открытое одиночное имя
  начнёт декодироваться в мусор) — проверять весь корпус URI.
- Группа S и откат `server_name` меняют `legacyNodeIdentityHash`: дедуп-подпись,
  миграция старых хешевых отметок выключения (IDENTITY §5.1).
- Правка `dropped[]` у Xray может покраснеть тесты §321 P5 / §404 P3.

## Верификация

Диагностика: оба раннера прогнаны локально по одному файлу, 33 кейса
сопоставлены с остатком §533 один к одному. Критерий закрытия задачи: после
правок A и ответа лаунчера оба раннера зелёные локально на синкнутом корпусе.

## Нерешённое / follow-up

Всё из «Решения» п.1–3. Поправки к прошлым записям: §514 §4б (vmess)
закрыт; вывод §512/§514 «прав Dart» по `amneziawg_scheme_full_name` неверен;
предложение §514 о сортировке `warnings[]` снято.
