# 688 — URL Check: раскрытие этапов, дерево, ответ DNS

| Поле | Значение |
|------|----------|
| Статус | Done — ядро `v1.14.3-lx.24-rc.2`, эмулятор 5/6 (находки не воспроизвелись) |
| Дата начала | 2026-10-27 |
| Источник | владелец после проверки §687 на телефоне: «по каждому этапу раскрывашку и пару слов, что за этап; вложенность и зависимость показывать»; «состав ответа не видим — какой резолв и какие типы данных пришли?» |
| Ядро | SPEC 139 релиз 2 (sing-box-lx#59, комментарий 27.10 15:40): `answer` на каждую запись, `authority` при NXDOMAIN/NODATA, `source` / `cache_age` / `stale`; склеенный `answers` снят |
| Связанные спеки | [687](687-diagnostics-url-check.md) — раздел Diagnostics и URL Check |

## Проблема

1. В дереве §687 строка этапа — это `kind` ядра (`app_dns`, `lookup`,
   `proxy_header`…). Человеку без знания ядра непонятно, что за шаг.
   Раскрывается строка только при наличии атрибутов, и тогда видны сырые
   `key: value`.
2. Вложенность показана только отступом. На глубоких деревьях (узел →
   lookup → dns → detour) отступ не говорит, где кончается одна ветка и
   начинается другая. Почему этап пропущен (`SKIPPED`), не сказано.
3. Ответ DNS в релизе 1 ядра — склеенная строка `answers` без TTL и без
   параметров HTTPS-записи. Откуда ответ (сеть, кэш, fakeip/hosts), не видно.

## Решение

### Строка этапа

- Шеврон справа у каждой строки: раскрыть можно любой этап, не только этап с
  атрибутами.
- Линии дерева слева вместо голого отступа: вертикаль у предков, у
  которых ниже есть ещё братья; уголок `├`/`└` у самой строки.
- Для `app_dns` и `dns` код ответа, отличный от `NOERROR`, виден в строке
  без раскрытия, цветом ошибки; в раскрытии атрибут `rcode` и ошибка вида
  `rcode NXDOMAIN` тогда не повторяются.

### Раскрытый этап (сверху вниз)

1. **Описание шага** — одна строка по `kind` (таблица ниже). У незнакомого
   `kind` строки нет (словарь ядра открыт, SPEC 139 §4).
2. **Пояснение исхода**, кроме OK и RUNNING:
   - SKIPPED: «Not run: %s failed» с корневой стадией итога, без неё — «Not run».
   - REUSED: «Reused: an open connection or a cached answer».
   - NO_ACK: «Sent; the protocol gives no confirmation».
   - NOT_EVALUATED: «Not evaluated».
3. **Источник ответа** (`source`):
   - `network` → «From the network»;
   - `cache` → «From cache, %s old» (`cache_age`: секунды до 2 мин, минуты до 2 ч, дальше часы), плюс «expired, refreshing» при `stale=true`;
   - `local` → «Local answer: fake IP or hosts».
   - Нет `source` — строки нет.
4. **Answer** — все атрибуты `answer`, по одному на строку, моноширинно,
   в порядке ядра. Для `app_dns` с `NOERROR` без записей — «No records»; если
   при этом нет `source`, ядро не спрашивало DNS-сервер (ответило правило или
   тип отсекла стратегия домена, SPEC 139 §4) — «No records: the core answered
   without asking a DNS server (a rule or the domain strategy)».
   Склеенного `answers` у `app_dns` в релизе 2 нет; у стадии `dns`
   `answers` — число записей, он идёт в прочие атрибуты.
5. **Authority** — атрибуты `authority`, по одному на строку.
6. **Остальные атрибуты** `key: value`, кроме уже показанных (`type`,
   `answer`, `authority`, `source`, `cache_age`, `stale`).
7. **Ошибка** этапа цветом ошибки.

### Что раскрыто без тапа

- корневая стадия итога (`rootCause`);
- `app_dns` с `rcode` ≠ `NOERROR` или с `NOERROR` без записей (пустой ответ —
  частая причина «не открывается»);
- стадии находки, на которую нажали (см. ниже).

Тап по строке переключает её против этого умолчания.

### Находки

Тап по находке подсвечивает и раскрывает её стадии (`stages` находки);
повторный тап снимает подсветку.

### Copy

В текстовой трассе каждый `answer` и `authority` — своя строка
(атрибуты уже выводятся по одному). Описания шагов в текст не идут: он
машинный.

### Описания шагов (EN, ключи l10n; ru и zh в словарях)

| kind | Текст |
|------|-------|
| app_dns | DNS query the app makes for the site |
| route | Routing rule match: which outbound takes the connection |
| group | Node selection inside a group |
| chain | Chain unfolded into its nodes |
| dial | Connection through a node |
| detour | Hand-off to the detour that carries this node |
| lookup | Resolving the server address of a node or DNS server |
| dns | Query to a DNS server |
| connection | Connection to the DNS server, already open: idle in the pool or opened by a parallel query (ядро rc.3, дочерняя `dns`, всегда REUSED) |
| wake | Waking an endpoint that was idle-suspended |
| udp | UDP socket to the server; UDP has no handshake to confirm |
| tcp_connect | TCP connection to the server |
| quic | QUIC connection to the server |
| tls | TLS handshake with the server |
| reality | REALITY check: did the server recognize the client |
| transport | Transport over TLS: WS, gRPC, XHTTP, HTTPUpgrade or H2 |
| auth | Authentication: the server confirms the credentials |
| wg_handshake | WireGuard handshake with the peer |
| proxy_header | Protocol header to the server; this protocol sends no confirmation |
| target_tls | TLS with the site itself, through the tunnel |
| first_byte | First bytes of the site's response |
| http | HTTP response of the site |

## Файлы

- `app/lib/services/diagnostics/connection_test.dart`: у `TestStage`
  появляется `attrsOf(key)`; у `TraceRow` — `lastPath` (по уровням: последний
  ли брат), для линий дерева.
- `app/lib/screens/diagnostics/url_check_tab.dart`: строка этапа, раскрытие,
  описания, подсветка находок.
- `app/assets/l10n/{ru,zh}/ui.json`: новые ключи.
- `app/test/services/diagnostics/connection_test_test.dart`: `lastPath` и
  `attrsOf`.

## Проверка

На эмуляторе с ядром релиза 2 (rc.2):

1. Полная проверка `youtube.com`: у каждой строки шеврон, линии дерева
   сходятся. У `app_dns A` раскрываются CNAME и адреса с TTL, у `HTTPS` —
   параметры alpn/ech.
2. Повторная проверка без «From scratch»: у `app_dns` «From cache, N s old».
3. Несуществующий домен: `app_dns` раскрыт сам, в строке `NXDOMAIN`, в
   Authority — SOA.
4. Узел с неверным паролем или выключенный сервер: корневая стадия раскрыта,
   у пропущенных — «Not run: … failed».
5. Тап по находке подсвечивает её стадии.
6. Copy: `answer` построчно.

## Итог эмулятора (27.10.2026, ядро `v1.14.3-lx.24-rc.2`, release-сборка arm64)

1. ✓ `youtube.com` Full: шевроны у всех строк, линии дерева сходятся (dial →
   group / udp / tcp_connect / tls). `cloudflare.com` Route: у `A` две записи
   с TTL, у `HTTPS` — `HTTPS 300 1 . alpn="h3,h2" ipv4hint="…"`.
2. ✓ Повтор без From scratch: «From cache, 32 s old»; у просроченной записи —
   «… · expired, refreshing». Первая сборка показывала «64915 s old» — возраст
   переведён в с/мин/ч (46232734).
3. ✓ Несуществующий домен, DNS + From scratch: `app_dns A` раскрыт сам, в
   строке `NXDOMAIN`, «From the network», Authority `com. SOA 900
   a.gtld-servers.net. …`. Атрибут `rcode` и ошибка «rcode NXDOMAIN» больше
   не дублируют строку (46232734).
4. ✓ Узел MASQUE оборвался на `tls` (EOF, сеть эмулятора): корень раскрыт и
   подсвечен, у `first_byte` — «Not run: tls consumer-masque.cloudflareclient.com
   failed».
5. — Находок в прогонах не было; подсветка по тапу не проверена на устройстве.
6. — Copy не проверялся: `answer` и `authority` — отдельные атрибуты, выгрузка
   пишет атрибут на строку (по построению).

Попутно: у ядра есть стадия `udp` (сокет WG-узла, `protocol/wireguard`), её
нет в таблице SPEC 139 §4 — описание добавлено. `app_dns AAAA` приходит
`NOERROR` без записей, без `source` и без дочерней `dns` — по ядру (#59, сессия
ядра 27.10) это стратегия домена `ipv4_only`: `dns/client.go` отвечает на AAAA
пустым NOERROR до стадии `dns`; SPEC 139 §4 дописан. Строка «No records»
уточнена для этого случая после тега rc.2 — едет в следующую сборку.
