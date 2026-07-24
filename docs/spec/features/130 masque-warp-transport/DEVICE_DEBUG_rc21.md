# MASQUE (SPEC 021) — отладка на устройстве, ядро rc.21

**Устройство:** CPH2411 (ColorOS/Android 15), сеть wifi.
**Ядро:** v1.14.0-lx.1-rc.21. **App:** LxBox 2.8.2-dev.5 (§130 Dart-часть).
**Симптом:** MASQUE-узел создаётся, но соединение не поднимается.

## Что РАБОТАЕТ (наша сторона, подтверждено)
- Регистрация MASQUE в Cloudflare прошла: ECDSA-ключи сгенерены, PATCH-enroll вернул серверный pubkey + ip/ipv6 + endpoint.
- Ключи ПАРСЯТСЯ ядром — при старте нет x509-ошибки (иначе был бы fail-fast). private_key/public_key валидны.
- Конфиг собран по схеме option/masque.go корректно (см. ниже).

## Ошибка (app-лог, dial)
```
🔥🎭 WARP (MASQUE) → captive.apple.com — dial udp: dial wlan0 (38): dial udp 162.159.198.2:443: i/o timeout
```
→ QUIC (h3=UDP) на 162.159.198.2:443 таймаутит.

## Проверенные факты сети
- ICMP-ping 162.159.198.2 И 162.159.198.1 — ОБА отвечают (~1.3ms, 0% loss). Хосты доступны.
- UDP:443 — таймаут (не дозвон). TCP/UDP-пробы дальше не делались.
- ВОПРОС к ядру: 162.159.198.2 — это h2-эндпоинт (в референсных Clash-yaml server=162.159.198.2 идёт с network=h2). Мы шлём h3/QUIC на .2. Возможно для h3 нужен .1, или проблема в другом.
  Регистрация Cloudflare вернула endpoint = 162.159.198.2 (мы берём peers[0].endpoint.v4 из ответа enroll).

## ПОЛНЫЙ MASQUE-outbound конфиг (реальные ключи, одноразовые)
```json
{
  "type": "masque",
  "tag": "🔥🎭 WARP (MASQUE)",
  "server": "162.159.198.2",
  "server_port": 443,
  "profile": "cloudflare",
  "network": "h3",
  "private_key": "MHcCAQEEIBHycXZ91kiI2e84oh/8xYih2iUR5Qh79+RleDa0PLPtoAoGCCqGSM49AwEHoUQDQgAE1oCSCZUJFcbtPz65BAS0L2XaZ0b+qphTuzk/13OQQv8rNVUmzIXrMguvHte0j+BjbL/ZHv9f7ElnEivyDC+VQQ==",
  "public_key": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w==",
  "ip": "172.16.0.2/32",
  "ipv6": "2606:4700:110:85d9:a82b:698a:2478:433/128",
  "mtu": 1280
}
```

## Верификация DER-ключей (уже пройдена offline)
private_key парсится x509.ParseECPrivateKey, public_key — x509.ParsePKIXPublicKey (P-256).
Сверено байт-в-байт против Go: scripts/masque_der_check.go в репо LxBox → OK.

## Core-логи (сырые, последние)
```
info | status=Starting
info | status=Stopped
info | status=Stopping
info | status=Started
info | status=Starting
info | status=Stopped
info | status=Stopping
info | status=Started
info | status=Starting
info | status=Stopped
info | status=Stopping
info | status=Started
info | status=Starting
info | status=Stopped
info | status=Stopping
info | status=Started
info | status=Starting
info | status=disconnected
error | ERROR[1183] [2221388249 10.3s] outbound/direct[direct-out]: receive ICMP echo reply: i/o timeout
error | ERROR[1123] [2472311199 10.5s] outbound/direct[direct-out]: receive ICMP echo reply: i/o timeout
```

## Открытые вопросы для команды ядра
1. Для network=h3 корректен ли endpoint 162.159.198.2:443, или QUIC-листенер только на .1? (мы берём то, что вернула регистрация)
2. Ядро реально пытается QUIC-handshake, или падает раньше? Нужен ли verbose-лог MASQUE-транспорта (ConnectTunnel/DialQuic)?
3. Возможно UDP/QUIC режется на этой сети — стоит ли пробовать network=h2 как fallback (h2 device-verified в SPEC 021)?

---

## ОТВЕТ КОМАНДЫ ЯДРА (rc.21, разбор от 2026-07-02)

**Диагноз: причина — отсутствие `sni` в конфиге. Не баг ядра.**

Взяли ВАШ точный outbound из этого отчёта (те же `private_key`/`public_key`/`endpoint`/`ip`/`ipv6`)
и прогнали на стенде **с той же категории сети**:

| Конфиг | Результат |
|---|---|
| ваш конфиг **как есть** (без `sni` → дефолт `consumer-masque.cloudflareclient.com`) | ❌ `dial quic: timeout: no recent network activity` — **воспроизвели вашу ошибку** |
| тот же + **`"sni": "4pda.to"`** | ✅ `warp=on`, стабильно 3/3 |

С `sni: 4pda.to` через туннель прошёл реальный трафик (не только cdn-cgi/trace):
- example.com / google.com / api.ipify.org / ifconfig.me → все **HTTP 200**, 0.27–0.6с
- внешний IP = `104.28.162.51` (Cloudflare WARP edge)
- urltest-проба `https://www.gstatic.com/generate_204` → **HTTP 204, 0.33с** (узел был бы «зелёным»)

**Почему без SNI не работает, хотя дефолт есть:** ядро подставляет дефолтный
`consumer-masque.cloudflareclient.com`, но на сетях с DPI QUIC по этому «палевному» Cloudflare-SNI
режется — таймаут наступает на самом первом шаге (установка UDP-сокета к endpoint), ЕЩЁ ДО
QUIC-handshake и до CONNECT-IP. Поэтому ключи/TLS/CONNECT-IP тут ни при чём — до них не дошло.
С маскирующим SNI (domain-fronting, любой нейтральный хост) handshake проходит.

### По открытым вопросам
1. **Endpoint `162.159.198.2:443` корректен для h3.** Он транспорт-независим (и h3/UDP, и h2/TCP на
   одном anycast-адресе). Берите то, что вернула регистрация. `.1` vs `.2` роли не играет.

   > **Уточнение §305 (device-verified, позже):** транспорт-независимость держится только на
   > четырёх адресах — `162.159.198.1/.2`, `162.159.199.1/.2` (на всех четырёх работают и h3,
   > и h2, на всех 7 портах). **За их пределами транспорт решает:** h2 живёт по всему блоку
   > `.198.0/24`+`.199.0/24`, а **h3 не поднимается вообще**. Поэтому в пуле генератора для h3
   > заведена отдельная секция `masque.h3_v4_cidr`. См. [spec/tasks/305](../../tasks/305-masque-endpoint-h2-pool-and-override.md).
2. **Ядро реально пытается QUIC** и падает на `dial udp` (первый шаг, до handshake) — это видно по
   тексту ошибки. Verbose-лог не требуется для этого случая, ошибка самодостаточна.
3. **h2 не нужен как первый шаг** — h3 работает с правильным SNI. h2 остаётся fallback'ом на сетях
   с жёсткой блокировкой UDP (тогда `network: "h2"` уйдёт по TCP:443).

### ФИКС на стороне LxBox (Dart)

В `emitMasque` SNI добавляется только при непустом значении:
```dart
if (s.sni.isNotEmpty) 'sni': s.sni,
```
Значит если поле пустое — в JSON его нет → ядро берёт дефолт → таймаут. **Проставляйте `sni`
всегда** (сделать настраиваемым, дефолт — рабочий фронт-домен, напр. `4pda.to`).

Рабочий outbound (ваш + одна строка):
```json
{
  "type": "masque",
  "tag": "🔥🎭 WARP (MASQUE)",
  "server": "162.159.198.2",
  "server_port": 443,
  "profile": "cloudflare",
  "network": "h3",
  "sni": "4pda.to",
  "private_key": "MHcCAQEEIBHy...VQQ==",
  "public_key": "MFkwEwYH...r6w==",
  "ip": "172.16.0.2/32",
  "ipv6": "2606:4700:110:85d9:a82b:698a:2478:433/128",
  "mtu": 1280
}
```

**public_key** одинаков у разных регистраций — это нормально: для consumer-WARP это фиксированный
публичный ключ MASQUE-endpoint'а Cloudflare, а не пер-девайсный. Ложная тревога, не трогать.

---

## ФИНАЛЬНЫЙ ДИАГНОЗ (через debug-API, на самом устройстве CPH2411, 2026-07-02 ночь)

**Корневая причина: на этой сети/устройстве режется входящий UDP (QUIC-ответы) → h3 не работает.
Решение — `network: "h2"` (CONNECT-IP по TCP:443). Проверено на устройстве: h2-узел поднялся, delay 272ms.**

(Раздел про SNI выше остаётся в силе — SNI действительно нужен и он в конфиге есть. Но он был НЕ
единственной причиной; после добавления SNI всплыл транспортный слой. Ниже — доказанный на живом
устройстве корень.)

### Что реально показало устройство (debug-API :9269)
1. **SNI долетел** — в активном конфиге `sni = 4pda.to` присутствует (GET /config), выдумки про
   «не пробросилось» отпадают. Конфиг masque-узла корректен полностью.
2. **h3 (QUIC) ошибка: `dial quic: context deadline exceeded`** на реальном трафике (cp.cloudflare.com),
   не только urltest. Прогресс с прошлого раза: `dial udp i/o timeout` → теперь `dial quic deadline`
   (UDP-сокет создаётся, но handshake не завершается).
3. **goroutine-дамп ядра (GET /diag/pprof?profile=goroutine)** — QUIC-conn висит в:
   `quic-go.(*Conn).run → crypto/tls.clientHandshake → quicReadHandshakeBytes → readHandshakeBytes`.
   Т.е. ядро **отправило ClientHello и ждёт ServerHello, которого нет.** Исходящие QUIC-пакеты уходят,
   ответные от `162.159.198.2` не возвращаются. Классика: UDP:443 в одну сторону проходит (ICMP-ping
   этого IP у вас работал), обратный QUIC режется (CGNAT/DPI/мобильный firewall).
4. **Переключил узел на `network: h2` (PUT /config + reload-vpn) → delay стал 272ms** (был -1),
   `URLTest ... cp.cloudflare.com/generate_204: 272ms`. **Туннель по TCP встал сразу.** Это
   доказывает: транспорт h3/UDP — единственная проблема; h2/TCP на той же сети работает.

### Почему ваше direct-правило для 162.159.198.2 не помогло
Правило `Rule 10 → direct-out {ip_cidr: 162.159.198.2/32}` применяется к трафику, ИДУЩЕМУ ЧЕРЕЗ
роутер из inbound (tun/mixed). Но dial самого MASQUE-узла к своему серверу идёт НЕ через маршрутизатор
— он использует свой `dialer` напрямую (с `protect()`/bind к wlan0, что видно по `dial wlan0 (38)`).
Так что маршрутной петли не было, и route-правило тут ни при чём — резалась именно обратка QUIC на
сетевом уровне. Правило можно убрать.

### ЧТО ДЕЛАТЬ В LxBox (постоянный фикс)
1. **Дать выбор транспорта MASQUE в UI: `network: h3 | h2`** (сейчас Dart всегда шлёт h3 из модели).
   На сетях где UDP режется — h2 обязателен.
2. **Идеально — авто-fallback:** urltest по h3; если delay = -1 / deadline → пересобрать узел на h2 и
   повторить. h3 быстрее там, где UDP проходит; h2 — универсальный fallback по TCP. Это ровно тот
   паттерн, что уже device-verified: h3 -1, h2 272ms.
3. **Endpoint/ключи/SNI НЕ трогать** — они верны. Менять только `network`.

### Дифференциал: почему AWG (тоже UDP) работает, а MASQUE нет
На устройстве одновременно есть рабочий **AWG-узел (WireGuard, UDP!)** — endpoint `188.114.97.5`,
delay 67ms, живой. То есть **UDP на устройстве в принципе ходит** — тотальной блокировки UDP нет.
Разница:
- AWG UDP идёт на **нестандартный порт** (WARP WG: 2408/500/1701/4500…) → проходит.
- MASQUE QUIC идёт на **UDP:443** (well-known QUIC-порт) → режется.

Вывод: это **DPI/провайдер, режущий QUIC именно по UDP:443** (очень частый паттерн). Не баг ядра
(на стенде Mac тот же endpoint:443 по QUIC давал warp=on), не тотальный UDP-блок (AWG живой).

Отсюда ещё один возможный путь помимо h2: **альтернативный UDP-порт для MASQUE** (если WARP MASQUE
принимает QUIC не только на 443 — надо проверить, что вернёт регистрация с другим endpoint-портом).
Но самый надёжный и уже проверенный путь — **h2 (TCP:443)**.

### h2 device-verified: реальный трафик прошёл (не только ping)
После переключения на h2 активировал masque в final-группе (set-group vpn-1 + switch-node) и снял
live-профайлер (`GET /profiler/live`): **боевой трафик реально пошёл через MASQUE-узел** —
`outbound_chain` содержит `🔥🎭 WARP (MASQUE) 4`:
- `udpOpen rr2---sn-...googlevideo.com:443` (YouTube video)
- `tcpOpen/tcpClose youtubei.googleapis.com:443`
- `tcp/udpOpen ...playstoregatewayadapter-pa.googleapis.com:443` (Play Store)
Т.е. h2-туннель несёт настоящий трафик, а не только даёт urltest-delay.

### Устройство ВОЗВРАЩЕНО в исходное состояние
После проверки: switch-node обратно на `🔥⛈️ WARP (AWG 1.5)` (рабочий, 67ms) + `rebuild-config`
(стёр мой временный h2-оверрайд → masque снова h3 из настроек). Туннель connected, активен AWG —
как было до тестов. config_locked НЕ трогал. Ваш обычный флоу не нарушен.

**Итого одной строкой:** ядро/ключи/SNI исправны; на этой сети режется QUIC по UDP:443 (h3 виснет
в handshake — ClientHello ушёл, ServerHello не пришёл), при этом AWG-UDP на порту 2408 и MASQUE-**h2**
на TCP:443 работают. Фикс в LxBox — дать/выбрать `network: h2` (в идеале авто-fallback h3→h2).
