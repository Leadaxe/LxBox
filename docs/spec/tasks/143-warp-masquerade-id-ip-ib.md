# 143 — WARP-обфускация на core masquerade `id/ip/ib` (ядро 009), выпил Dart-генератора i1

> ⚠️ **Коллизия номера §143** (параллельные сессии). Это «§143-warp». Второй файл под тем же
> номером — [`143-interrupt-connections-on-node-switch.md`](143-interrupt-connections-on-node-switch.md) («§143-interrupt»).
> Не перенумеровано намеренно — см. [README §«Известные коллизии»](README.md#известные-коллизии-номеров).

| Field | Value |
|------|----------|
| Status | Implemented (device-smoke ✅) |
| Started | 2026-06-16 |
| Trigger | Ядро `sing-box-lx v1.13.13-lx.11` (downstream 009) получило WireSock-style поля `id/ip/ib` на `wireguard`-endpoint — ядро само разворачивает их в AmneziaWG `i1` CPS-пакет нужного протокола. LxBox генерил `i1` сам в Dart (§126/§136) — дублирующая логика. Переходим на поля ядра (модель A): меньше Dart-кода, один источник истины, 4 протокола вместо одного, домен реально виден для dns/sip. |
| Related | [§126](126-warp-amneziawg-obfuscation.md)/[§136](136-warp-quic-i1-generator.md) (Dart-генератор i1 — ВЫПИЛЕН); [§142](142-warp-reserved-optional.md) (reserved); [§025](../features/025%20warp%20integration/spec.md); ядро: `sing-box-lx/SPECS/009-F-O-WIRESOCK_MASQUERADE_PROFILES` |
| Files touched | `models/node_spec.dart` (Awg.strKeys += id/ip/ib), `services/warp/warp_client.dart` (buildAmneziaAwg), `services/warp/masquerade_params.dart` (был awg_junk.dart → QuicParams), `controllers/subscription_controller.dart`, `screens/warp_wizard_screen.dart`, `android/libbox.version` (lx.11) |

## Поля masquerade (WireSock-формат, ядро 009)

| Key | Значение | Допустимо |
|---|---|---|
| `ip` | протокол маскировки | `quic` \| `dns` \| `stun` \| `sip` |
| `id` | домен — на провод идёт только для `dns` (QNAME) / `sip` (host); для `quic`/`stun` декоративен | LDH-host |
| `ib` | браузер | `chrome` \| `firefox` \| `curl` — только при `ip=quic` |

**Правила ядра:** `id/ip/ib` **взаимоисключающи с явным `i1`** (оба → ошибка); ядро само генерит i1. `ip=dns`/`sip` без `id` → ошибка.

## Что сделано

### Модель (A) — генерация i1 на стороне ядра
- `buildAmneziaAwg(QuicParams)` пишет `ip`/`id`/`ib` в Awg-поля, **БЕЗ `i1`**. QUIC → +`ib`; dns/sip → только id/ip; пустой id → `www.google.com`.
- `Awg.strKeys += {id, ip, ib}` ([node_spec.dart](../../../app/lib/models/node_spec.dart)) — проходят через `.conf`(UPPER)→ini(lowercase)→fromQuery→endpoint-JSON.
- UI визарда (Advanced): dropdown **Masquerade protocol** (quic/dns/stun/sip), **domain (id)** combo-box + кубик, **Browser (ib)** dropdown (виден при quic). Контекст-подсказка: «домен виден на проводе» (dns/sip) vs «декоративен» (quic/stun).

### Выпил мёртвого Dart-генератора i1
Удалены файлы: `quic_i1.dart`, `aes_min.dart`, `pseudo_gen.dart` (§127, единственный потребитель — SIP-junk), тесты `quic_i1_test.dart`/`awg_junk_test.dart`/`pseudo_gen_test.dart`. Удалены: `JunkTemplate` enum, `useCoreMasquerade` флаг, `generateQuicI1`/`generateSipI1`, SIP-helpers, `level`-параметр, `template:` из register/addWarp/buildAmneziaAwg/_syncWarpObfuscation. `awg_junk.dart` → `masquerade_params.dart` (только `QuicParams`).

## Device-smoke (2026-06-16, CE8XX48PCI79U4XG, ядро 009)

Узел `ip=dns id=telemost.yandex.ru` через Get WARP: ядро **приняло** (нет «conflicts»/«awg not built»), `tunnel: connected`, `i1`=нет, reserved=нет (§142). **Реальный трафик: Clash delay через узел = `{"delay":300}`** — HTTP-204 прошёл через WARP. Узел активен.

> ⚠️ Проверено на **чистой сети** (туннель+трафик работают). Пробивает ли реальный DPI — отдельный тест (только в заблокированном регионе).

## Acceptance

- [x] `buildAmneziaAwg` пишет id/ip/ib, БЕЗ i1; ib только при quic; пустой id → дефолт.
- [x] id/ip/ib доходят до endpoint-JSON (conf→ini→spec→emit), round-trip persist.
- [x] UI: выбор protocol/domain/browser в Advanced.
- [x] Dart-генератор i1 и зависимости выпилены; `flutter analyze` чисто; 1140 тестов.
- [x] Ядро 009 принимает узел, туннель+трафик на устройстве (`delay:300`).
- [x] Пин ядра → `v1.13.13-lx.11` (официальный релиз, fetch SHA256-verify).

## NB
`ip=quic` — short header **без SNI**, домен не виден цензору (это выбор WireSock, не TLS-fingerprinted Initial). Для видимости домена — `dns`/`sip`. `ib` — косметические QUIC-биты, НЕ JA3.
