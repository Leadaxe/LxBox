# 121 — Адаптация на ядро sing-box 1.14

| Поле | Значение |
|------|----------|
| Статус | Реализовано (ветка `feat/libbox-1.14-migration`; Kotlin-обвязка под libbox 1.14, ядро `v1.14.0-lx.1`) |
| Дата старта | 2026-06-23 |
| Прообраз | upstream sing-box 1.14 changelog + migration-гайд; форк-база lx уже смержена до `1.14.0-alpha.33` |
| AAR | CI-run `27991734294` (Leadaxe/sing-box-lx, ветка `lx-1.14`, артефакт `android-aar-lx-1.14`); НЕ GitHub Release — пин пока не бампается |
| Связанные spec'ы | [`117 dns-rework`](../117%20dns-rework/spec.md) — DNS-структура, которую 1.14 рефакторит; [`045 tls ech`](../045%20tls%20ech/spec.md) — ECH остаётся Draft, НЕ часть этой миграции; §010 (ядро `SPECS/010`) — WG-GRO фикс, в 1.14 решён апстримом; §126 WARP-AWG-обфускация; §037 hysteria/протоколы |
| Память | [[project_libbox_114_migration_api_breaks]], [[project_wg_endpoint_detour_speed]], [[project_jni_callbacks_must_not_throw]] |

## TL;DR

Ядро мигрировано на sing-box 1.14. **Breaking-правок под совместимость на стороне
клиента НЕТ** — аудит кода (5 подсистем, адверсариальная верификация) подтвердил:
все потенциально ломающие изменения 1.14 (DNS-рефакторинг, removed legacy-форматы,
`store_rdrc`/`independent_cache`) нас **не касаются** — мы их не генерируем. Ценность
1.14 для lx — это **anti-DPI возможности** (Hysteria2 gecko/bbr/port-hopping) и
ядерный WG-GRO фикс §010, наследуемый автоматически.

Главный gate релиза — **не код, а device-верификация** собранного 1.14 AAR (включая
старый Android). Уже сделано: device-тест §010 на CPH2411/Tele2 LTE — регрессии нет
(WARP/WG download 16.1 Mbps Ookla, вровень с vless; при баге было 0.44).

## Что проверено аудитом (фактура)

Верифицировано в реальном коде форка (`app/lib`, `app/assets`) и ядре
(`/Users/macbook/projects/sing-box-lx/option/*.go`):

| Изменение 1.14 (changelog) | Статус в lx | Класс |
|---|---|---|
| WG-GRO split-brain §010 | фикс в `wireguard-go v0.0.3` (submodule), клиентского кода нет | **auto** |
| `package_name_regex` | бэкпорт lx.15, в 1.14 апстримный — дубля нет, пресет `block_unknown` стабилен | **auto** |
| DNS `evaluate`/`match_response`, deprecated address-filter в DNS-rule | не используем (DNS-rules простые) | **no-op** |
| `store_rdrc`→`store_dns`, `independent_cache` убран | **0 вхождений** в коде/ассетах; используем `cache_file` (`wizard_template.json:606`) — корректный механизм | **no-op** |
| legacy DNS server string-формат, legacy fakeip | не используем (все серверы object-формат) | **no-op** |
| `default_domain_resolver` + `dns.final` | семантика стабильна 1.13→1.14; валидатор `validator.dart:68` ловит dangling refs; §121-гейт на месте | **auto** |
| Native TLS engine (Apple/Windows) | Android не входит | **no-op** |
| ACME → `certificate_providers` | server-side (inbound TLS); мы чисто outbound-клиент | **no-op** |
| `format:domain_suffix` в inline rule_set | уже удалён из живого шаблона (0 вхождений); остался в тест-фикстурах намеренно | **soft-breaking** (см. PR-1) |
| Reality + uTLS fingerprint round-trip | API без изменений; код принимает любой fingerprint-ID (нет hardcoded enum) → новые ID работают сами | **auto** |
| gRPC API service / Dashboard / USB-IP / remote-control | вне scope Android-клиента (companion/web/server) | **skip** |
| Kotlin/JNI обвязка на 1.14 API | коммит `8a23251`, backward-compat, верифицирована на железе | **done** |

## Этапы (PR-разбивка)

### PR-1 — release-критичное (обязательно к тегу 1.14)

**Главное: код под совместимость НЕ требуется.** Состав:

1. **Сборка AAR под 1.14 + бамп пина.** `app/android/libbox.version` → версия 1.14
   (когда ядро выпущено как GitHub Release; сейчас только CI-артефакт). До этого —
   тестовая подмена через gitignored `libs/libbox.aar` (см. [[project_libbox_114_migration_api_breaks]]).
2. **Мерж ветки `feat/libbox-1.14-migration`** (Kotlin-обвязка, коммит `8a23251`)
   в develop — **только синхронно с бампом пина** (обвязка 1.14-only, со старым AAR
   не компилируется).
3. **Device-smoke чеклист** (главный gate, не код):
   - §010 WG-download на LTE no-detour — отсутствие регрессии (✅ сделано на CPH2411).
   - Смоук на **старом Android (10)** — JNI-callbacks не бросают (память:
     [[project_jni_callbacks_must_not_throw]], краши на Android 10 не репро на тест-телефоне 13).
   - Краш локали `ru_IL` — починен в `8a23251` (`setLocale` стал строгим в 1.14).
4. **Import-sanitizer** невалидного `format` в inline rule_set — защита от тихого
   слома (см. ниже). Объём низкий, ценность UX высокая.
5. CHANGELOG + pin-note.

### PR-2 — anti-DPI фичи 1.14 (после релиза)

Это **реальная причина** идти на 1.14 для anti-DPI проекта. Полный дизайн ниже.

- **Hysteria2 gecko obfs + BBR profile + port-hopping** (P0) — §NNN task, extend §037.
- **Hysteria2 Realm / NAT traversal через STUN** (P1) — для юзеров за CGNAT; реальная
  фича (аудит её ошибочно опроверг, исправлено ниже).
- **TLS spoof** (P0 по changelog, но **под вопросом на Android** — см. ниже; нужна
  device-проверка до реализации) — отдельная feature-спека если подтвердится.

### PR-3 — протоколы/роутинг (по запросу)

- SSH ciphers/macs/key_exchanges (`option/ssh.go`) — ниша, дёшево.
- inline `package_name_regex` exposing в UI custom-rule editor (ядро уже умеет).
- DNS `preferred_by`/mDNS, `source_mac_address`/`source_hostname`, TUN `dns_mode`.

---

## Дизайн: BREAKING-защита (PR-1)

### Import-sanitizer невалидного `format`

**Риск тихого слома:** юзер импортирует raw rule_set со старым полем
`"format":"domain_suffix"` (inline rule_set 1.14 не имеет поля `format` —
`option/rule_set.go`). 1.14 со строгой валидацией **отклонит весь конфиг** → VPN
молча не стартует, невнятная ошибка. В 1.12/1.13 поле молча игнорировалось → у
юзера «работало», после апдейта «сломалось без причины».

**Реализуется только при импорте сырого rule_set** (редкий путь — обычно импортят
подписки/пресеты). Поэтому soft-breaking, защитный фикс.

**Фикс:** при импорте/парсинге inline rule_set — **strip неизвестных полей** (в т.ч.
`format` на inline-типе) вместо передачи в ядро как есть. Точка: parser ingest-слой
(`app/lib/services/parser/json_parsers.dart` / import-путь). Альтернатива — explicit
allowlist полей inline rule_set. Решение по месту реализации — при имплементации.

---

## Дизайн: Hysteria2 anti-DPI (PR-2, P0)

Точные поля из ядра (`/Users/macbook/projects/sing-box-lx/option/hysteria2.go`):

```go
BBRProfile  string  `json:"bbr_profile,omitempty"`           // congestion control
ServerPorts Listable[string] `json:"server_ports,omitempty"` // port-hopping
HopInterval Duration `json:"hop_interval,omitempty"`
HopIntervalMax Duration `json:"hop_interval_max,omitempty"`
// obfs.type: "salamander" | "gecko" (constant/hysteria2.go)
// gecko: { min_packet_size, max_packet_size }   (Hysteria2ObfsGecko)
```

**Текущий `Hysteria2Spec`** (`app/lib/models/node_spec.dart:243-266`) — только
`password / obfs('' | 'salamander') / obfsPassword / tls / upMbps / downMbps`.
Нет congestion, gecko, port-hopping.

### Изменения (кросс-слой, round-trip)

| Слой | Файл | Что добавить |
|---|---|---|
| Model | `models/node_spec.dart:243` | поля `bbrProfile: String?`, `serverPorts: List<String>`, `hopInterval: String?`, `hopIntervalMax: String?`; в `obfs` допустить `'gecko'` + `geckoMinSize/geckoMaxSize: int?` |
| Emit | `node_spec_emit.dart:254` | сейчас emit только `obfs=='salamander'`. Добавить ветку `gecko` (`obfs:{type:'gecko', min_packet_size, max_packet_size}`), `bbr_profile`, `server_ports`/`hop_interval`/`hop_interval_max` |
| Parse JSON | `json_parsers.dart` (hysteria2-ветка) | читать новые поля round-trip |
| Parse URI | `uri_parsers/hysteria2_parser.dart` + `toUriHysteria2` (`node_spec.dart:275`) | query-параметры port-hopping/obfs/bbr |
| UI | hysteria2 node-editor | поля obfs-type (salamander/gecko), congestion, port-range |
| Template | `wizard_template.json` | если hysteria2-пресеты — новые vars |

### Hysteria2 Realm / NAT traversal (P1) — ⚠️ ПОПРАВКА к аудиту

**Аудит ОШИБОЧНО опроверг** «NAT traversal + Hysteria Realm» как «таких полей нет».
По коду ядра — фича **реальная и работает в outbound** (`protocol/hysteria2/outbound.go:87-102`).
Это **одна** фича, не две: NAT traversal реализован через realm-механизм + STUN.

Поле `realm` в `Hysteria2OutboundOptions` (`option/hysteria2.go:185`):
```go
type Hysteria2Realm struct {
    ServerURL   string   `json:"server_url"`           // realm-координатор
    Token       string   `json:"token,omitempty"`
    RealmID     string   `json:"realm_id"`
    STUNServers Listable[string] `json:"stun_servers"` // ← NAT traversal через STUN hole-punching
    HTTPClient  *HTTPClientOptions `json:"http_client,omitempty"`
}
```

**Польза для нас:** STUN hole-punching сквозь NAT — потенциально ценно для юзеров за
**strict NAT / CGNAT** (массово у мобильных операторов!). Raw-socket НЕ требуется
(STUN/QUIC) → работает на Android. Приоритет P1: требует realm-сервер на стороне
узла, поэтому полезно только тем, у кого он настроен — ниша, но реальная.

**Изменения:** `Hysteria2Spec` + nested `Hysteria2RealmSpec` (server_url/token/
realm_id/stun_servers/http_client) → emit `realm:{...}` → parse round-trip → UI.

**Платформо-безопасно:** gecko = QUIC obfs-padding, port-hopping = UDP, BBR =
congestion-алгоритм. Raw-socket НЕ требуется → работает на Android.

**Приоритет внутри P0:** port-hopping (`server_ports`/`hop_interval`) — критичен для
CN/IR (обход блокировки по порту); gecko obfs — мимикрия трафика; BBR — скорость на
throttled-сетях.

---

## Дизайн: TLS spoof (PR-2 P0 — ⚠️ ПОД ВОПРОСОМ НА ANDROID)

**Важная поправка против changelog-отчёта.** `tls_spoof` — это **НЕ** мимикрия
ClientHello другого сервера, как можно прочитать из changelog. По коду ядра
(`common/tlsspoof/spoof.go`) это **TCP-level decoy-инъекция против DPI**:

```go
// spoof = адрес decoy-цели; spoof_method = тип «сломанного» TCP-сегмента
MethodNameWrongSequence  = "wrong-sequence"   // default
MethodNameWrongChecksum  = "wrong-checksum"
MethodNameWrongAcknowledgment = "wrong-ack"
MethodNameWrongMD5Sig    = "wrong-md5"
MethodNameWrongTimestamp = "wrong-timestamp"
```
Поля в TLS-секции: `spoof` + `spoof_method` (`option/tls.go:123-124`).

**Механизм:** посылает поддельный TCP-сегмент с намеренно битым полем (seq/checksum/
ack/md5/timestamp), чтобы middlebox-DPI его учёл и сбился, а реальный сервер
проигнорировал как мусор. Требует **raw-socket** (`raw_linux.go`/`raw_darwin.go`/
`raw_windows.go`; иначе `raw_stub.go` → `PlatformSupported=false`).

**Риск split-brain (как §010):**
- `raw_linux.go` компилируется на Android (build-семейство linux) →
  `PlatformSupported = true` на compile-time.
- НО raw-socket (`AF_PACKET`/`SOCK_RAW`) на Android требует **CAP_NET_RAW**, которого
  у обычного приложения без root НЕТ.
- Прогноз: парсинг spoof проходит, но открытие raw-socket в рантайме → permission
  denied. **TLS spoof, вероятно, нерабочий на нашем Android-клиенте.**

**Взаимоисключения (по коду ядра):**
- `reality_client.go:62`: `spoof` + `reality` = ошибка «spoof is unsupported in
  reality». Валидатор должен запрещать комбинацию.

**Решение:** НЕ включать TLS spoof в PR-2 как готовую фичу. Сначала —
**device-проба на 1.14 AAR**: задать `tls.spoof` на тестовом vless-узле, проверить в
core-log, открывается ли raw-socket или «not supported / permission denied». Если
рабочий (вдруг на новых Android с особыми правами) — отдельная feature-спека с
полным дизайном (model nested `SpoofSpec`, emit `spoof`/`spoof_method`, валидатор
конфликта с reality, UI). Если нет — пометить как «недоступно на Android без root»,
не тратить UI-работу.

---

## CLEANUP

| Что | Действие |
|---|---|
| §010/§150 клиентские следы | спека §150 уже удалена; grep `app/lib` на `GRO`/`rxoffload`/`UDP_GRO`/`§010` — вычистить мёртвые упоминания/no-op флаги если остались |
| `045 tls ech` | отметить: ECH = Draft, НЕ часть 1.14-миграции (комментарий `node_spec.dart:285` — аспирационный, не реализация) |
| тест-фикстуры с `format:domain_suffix` | оставить (намеренный regression-тест старого формата) |

## Открытые вопросы / honest gaps

| Gap | Как закрыть |
|---|---|
| TLS spoof на Android (raw-socket/CAP_NET_RAW) | device-проба на 1.14 AAR ДО любой реализации |
| Backward-compat 1.14 API в рантайме на Android 10 | смоук на старом устройстве, не только тест-телефон 13 |
| §010 транзитивный фикс на собранном 1.14 AAR | ✅ закрыто device-тестом 2026-06-23 (CPH2411/Tele2 LTE) |
| Точные query-имена port-hopping в URI-формате Hysteria2 | свериться с `docs/PROTOCOLS.md` при реализации PR-2 |
