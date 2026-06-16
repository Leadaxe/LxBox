# 136 — WARP QUIC i1-генератор + рандом endpoint (замена WG-traffic шаблона)

| Field | Value |
|------|----------|
| Status | Implemented (device-smoke pending) |
| Started | 2026-06-16 |
| Trigger | Field-report (Iliya, Крым): наш junk (WG-traffic / SIP) DPI провайдера НЕ пробивает, а конфиги с `warp-generator.github.io` — работают «из коробки, настройки по умолчанию, сервер стандартный». Реверс генератора (2026-06-16) показал: (1) i1 = **настоящий QUIC Initial** (голый SNI-ClientHello) с CPS-нарезкой `<b>/<r>`, тег `<r>` рандомит изменчивые байты на каждый пакет; (2) endpoint = **чистый рандом** IP:port из зашитых Cloudflare-блоков, без пробы/скана. Эмпирически: синтетический «шум под QUIC» (`0xc3…`+random payload) у Ильи НЕ сработал → нужен валидный QUIC Initial + `<r>`-нарезка. |
| Related | [§126](126-warp-amneziawg-obfuscation.md) (наш i1-генератор — заменяем WG-traffic на QUIC); [§135](135-warp-custom-endpoint-not-overwritten.md) (custom endpoint — предпосылка рандома); [§132](132-warp-endpoint-scanner-research.md) (endpoint research — рандом вместо скана); [§133](133-warp-junk-generators-research.md) (junk research — QUIC = планка-2026); [§127](127-pseudo-name-domain-generator.md) (PseudoGen для SIP); [[reference_awg_cps_tags]] |
| Files touched | NEW `assets/warp_endpoints.json`, `services/warp/quic_i1.dart`, `services/warp/warp_endpoint_picker.dart`; EDIT `services/warp/awg_junk.dart`, `warp_client.dart`, `screens/warp_wizard_screen.dart`, `controllers/subscription_controller.dart`, `pubspec.yaml` |

## TL;DR

Заменяем слабый **WG-traffic** junk-шаблон на **QUIC** (настоящий QUIC Initial,
порт `quic.js` из warp-generator). **SIP оставляем** как второй вариант. Шаблон
выбирается **dropdown** (QUIC default / SIP). У QUIC — параметры в **Advanced**
(SNI / Level 0-4 / Jc-Jmin-Jmax), по умолчанию рабочие. При включённой
обфускации с дефолтным endpoint — **рандомизируем IP:port** из зашитых блоков
Cloudflare (списки в assets).

## Реверс warp-generator (источник истины)

### i1 = QUIC Initial (quic.js)
- База: настоящий QUIC Initial, RFC 9001 крипта (`INITIAL_SALT 0x38762cf7…`,
  HKDF `client in`→`quic key/iv/hp`, AES-GCM + header protection). **Та же крипта
  что в нашем sing-box-lx-тесте `i2:"<c><t><r 10>"` — ядро ест `<r>`.**
- ClientHello **голый**: `03 03 | random[32] | sid=0 | cipher=[] | ext=SNI`.
  Нет ALPN/key_share/supported_versions — DPI нужен только SNI на месте.
- DCID = 1 байт, SCID=0, token=0, pkn=`[00]`.
- **Нарезка на `<b>/<r>`** (`quicToAWG` + `cutSettings`): статичные части
  (заголовок, SNI) → `<b 0x…>`; изменчивые (TLS random[32], хвост шифротекста) →
  `<r N>` → **ядро рандомит на каждый пакет** = нет общей сигнатуры/beacon.
  - level 0 (legacy): `<b><r 32><b><r 16>`.
  - level 1-4: иные `cutPresets` (разная агрессивность нарезки).

### endpoint = чистый рандом (script.js generateRandomEndpoint)
- **БЕЗ пробы/скана.** `prefix + rand(1..10) + ":" + pick(ports)`.
- Prefixes: `162.159.192.` `162.159.195.` `188.114.96/97/98.` + 8.x
  (`8.6.112 8.34.70 8.34.146 8.35.211 8.39.125/204/214 8.47.69`) + `engage…`.
- Ports (54): `500,854,…,988,…,2408,…,8886` (полный список в asset).
- Работает т.к. почти любой IP в этих /24 на любом порту из списка = живой WARP
  anycast; DPI режет только дефолтный `engage…:2408`.

### SNI default = РФ-сайты (script.js:663)
`apteka.ru, psbank.ru, lenta.ru, www.pochta.ru, rzd.ru, rutube.ru, gosuslugi.ru`
— DPI в РФ их НЕ режет (критичная инфраструктура). + добавляем международные
`www.google.com, cloudflare-quic.com, www.microsoft.com` для выбора. Рандом из
пула на каждую регистрацию; юзер может переопределить в Advanced.

### НЕ применимо: Id/Ip/Ib
Основной поток генератора пишет `Id=<домен>/Ip=quic/Ib=curl` — это формат
**нового форка AmneziaWG**, которого в нашем ядре НЕТ (lx.10 ест только
`i1..i5` CPS-теги, проверено по `lx-test/config/awg2_basic.json`). Поэтому идём
путём `quic.js` (CPS), не Id/Ip/Ib.

## Модель данных

```dart
// awg_junk.dart — было {wgTraffic, sipTraffic}
enum JunkTemplate { quic, sip }          // wgTraffic УБРАН

// quic_i1.dart — параметры QUIC-шаблона
class QuicParams {
  final String sni;        // '' → рандом из пула на генерации
  final int level;         // 0..4, default 0
  final int jc, jmin, jmax; // default 4/40/70
  const QuicParams({this.sni='', this.level=0, this.jc=4, this.jmin=40, this.jmax=70});
}
```

## Control flow

```
WarpWizard
  ☑ obfuscate
  template: [ QUIC ▼ ] / SIP          (dropdown)
  ▼ Advanced (template==QUIC):
     SNI [www.google.com ▼/ввод]  Level [0▼]  Jc[4] Jmin[40] Jmax[70]
        │
        ▼ register(obfuscate, template, quicParams, endpoint)
  WarpClient.register:
    1. POST /reg (unchanged)
    2. if obfuscate:
         awg = preset(jc/jmin/jmax из QuicParams, s1=s2=0, h1..h4=1234)
         template==quic → i1 = generateQuicI1(sni||randomSni(), level)
         template==sip  → i1 = generateSipI1()          (keep §126)
    3. if obfuscate && endpoint==defaultEndpoint:
         endpoint = WarpEndpointPicker.random()           (asset-driven)
       else: §135 (custom уважаем / дефолт→ответ API)
    → WarpAccount(awg, endpoint) → .conf → node
```

## Файлы

| Файл | Изменение |
|---|---|
| `assets/warp_endpoints.json` | NEW: `{prefixes:[…], ports:[…], sni_pool:[…]}` |
| `services/warp/quic_i1.dart` | NEW: `QuicParams`, `generateQuicI1(sni,level)` — порт quic.js (Initial+нарезка), `randomSni()` |
| `services/warp/warp_endpoint_picker.dart` | NEW: load asset, `random()` → `ip:port` |
| `services/warp/awg_junk.dart` | EDIT: `enum JunkTemplate{quic,sip}`; убрать `_wgTrafficJunk`; `generateJunkI1` только sip; quic вынесен в quic_i1.dart |
| `services/warp/warp_client.dart` | EDIT: `register(template, QuicParams)`; ветка quic/sip; рандом-endpoint; preset из QuicParams.jc/jmin/jmax |
| `screens/warp_wizard_screen.dart` | EDIT: dropdown QUIC/SIP; Advanced QUIC-params |
| `controllers/subscription_controller.dart` | EDIT: прокинуть QuicParams |
| `pubspec.yaml` | EDIT: `assets/warp_endpoints.json` |

## QUIC Initial — алгоритм (порт quic.js → Dart)

```
generateQuicI1(sni, level):
  ch  = clientHelloSniOnly(sni)              // 03 03 rand[32] 00 0000 ext=SNI
  dcid= 1 random byte; scid=0; token=0; pkn=[00]
  (payload, cut) = clientHelloToFrames(ch, level)  // CRYPTO frame(s)
  pkt = quicInitial(dcid,scid,token,pkn,payload)    // RFC9001 encrypt+HP
  cut = fixCutSettings(cut, pkt.len, 1, payload.len)
  return toAWG(pkt, cut)                       // "<b 0x…><r 32><b 0x…>…"
```
Крипта: `Random.secure()` для random[32]/dcid (не seeded — уникальность).
`<r>`-сегменты (TLS random, хвост) ядро регенерит per-packet.

## Acceptance

- [ ] Dropdown QUIC(default)/SIP в визарде; WG-traffic убран.
- [ ] QUIC i1 = валидный QUIC Initial с `<b>/<r>` нарезкой; SNI на месте; level 0-4 дают разную нарезку; i1 различается между регистрациями.
- [ ] SIP-ветка не сломана (§126 generateSipI1 как был).
- [ ] Advanced QUIC-params (SNI/Level/Jc/Jmin/Jmax) применяются; дефолты рабочие; SNI пустой → рандом из пула.
- [ ] Endpoint: obfuscate+дефолт → рандом ip:port из asset; custom → уважаем (§135); без обфускации → как раньше.
- [ ] `assets/warp_endpoints.json` грузится; prefixes/ports/sni_pool как в генераторе + 3 межд. SNI.
- [ ] Тесты: quic_i1 (структура Initial, нарезка, рандом), endpoint_picker (формат ip:port, диапазоны), preset из QuicParams, dropdown маппинг.
- [x] `flutter analyze` чисто; `flutter test` зелёный (1131 тест).
- [ ] Device-smoke (у Ильи): QUIC-узел через Get WARP даёт трафик. **PENDING.**

## Implementation (2026-06-16)

| Spec item | Code |
|---|---|
| QUIC Initial генератор (порт quic.js) | `services/warp/quic_i1.dart` — `QuicI1.generate(sni,level)`: ClientHello(SNI-only) → CRYPTO frame(s) по level → RFC 9001 Initial (encrypt+HP) → `<b>/<r>` нарезка |
| AES-128 (ECB + GCM) синхронный | `services/warp/aes_min.dart` — `encryptBlock`, `gcmEncrypt`; покрыт FIPS-197 + NIST GCM TC3/TC4 векторами |
| Endpoint/SNI рандом | `services/warp/warp_endpoint_picker.dart` + `assets/warp_endpoints.json` (prefixes/ports/sni_pool) |
| Enum + QuicParams | `awg_junk.dart` — `JunkTemplate{quic,sip}` (wgTraffic убран), `QuicParams`, `generateSipI1`/`generateQuicI1` |
| Preset + ветка + рандом-ep | `warp_client.dart` — `amneziaPreset(jc/jmin/jmax)`, `buildAmneziaAwg(template,params)`, `register(quicParams,randomEndpoint)` |
| Прокидка + sync | `subscription_controller.dart` — `addWarp(quicParams)`, резолв SNI/random-ep через picker |
| UI dropdown + Advanced QUIC params | `screens/warp_wizard_screen.dart` — DropdownButtonFormField QUIC/SIP, Advanced: SNI/Level/Jc/Jmin/Jmax |
| Тесты | `quic_i1_test.dart` (крипта против RFC/NIST + структура), `warp_endpoint_picker_test.dart`, обновлены `awg_junk_test.dart`/`warp_obfuscation_test.dart` |

**Крипта доказана:** AES-ECB = FIPS-197 B; AES-GCM = NIST TC3 (no AAD) + TC4 (AAD);
QUIC key derivation = RFC 9001 A.1 (key/iv/hp точь-в-точь). i1 — валидный
расшифровываемый QUIC Initial, не «структурный шум» (тот §136-trigger эмпирически
провалился у Ильи).

## NB
- `<r N>`-теги подтверждены в ядре `v1.13.13-lx.10` (`obfBuilders["r"]`,
  `lx-test/config/awg2_basic.json i2:"<c><t><r 10>"`) — ядро рандомит их per-packet.
- Формат `Id/Ip/Ib` (новый форк AmneziaWG) НАШЕ ядро не ест — поэтому CPS-путь.
- 8.x-префиксы empirical (§132) — в asset, легко обновить без релиза кода.
```
