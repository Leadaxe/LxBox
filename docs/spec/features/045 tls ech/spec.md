# 045 — TLS ECH (Encrypted Client Hello)

| Поле | Значение |
|------|----------|
| Статус | **Draft** — spec only, не реализовано |
| Дата | 2026-05-10 |
| Зависимости | [`020 security and dpi bypass`](../020%20security%20and%20dpi%20bypass/spec.md), [`026 parser v2`](../026%20parser%20v2/spec.md), [`028 antidpi sni obfuscation`](../028%20antidpi%20sni%20obfuscation/spec.md) |
| Связано | [`017 custom nodes and node settings`](../017%20custom%20nodes%20and%20node%20settings/spec.md) (UI editor) |
| Поддерживается в libbox | Да — `tls.ech.{enabled, config, pq_signature_schemes_enabled, dynamic_record_sizing_disabled}` |

---

## Цель и рамки

**ECH (Encrypted Client Hello)** — расширение TLS 1.3 ([RFC draft-ietf-tls-esni-18](https://datatracker.ietf.org/doc/draft-ietf-tls-esni/)) которое **полностью прячет SNI** в зашифрованной части ClientHello. Сейчас даже с TLS 1.3 SNI отправляется plaintext — DPI видит `server_name` и матчит его. С ECH видит только outer-SNI (обычно CDN-front вроде `cloudflare-ech.com`), а реальный target host зашифрован.

После §028 (mixed-case SNI — обходит наивный exact-match) ECH — **следующий уровень**: вместо мутации plaintext'а **прячем его целиком**. Это закрывает DPI-движки которые после §028 fallback'аются на substring/regex или на ML-классификацию по SNI-распределению.

**В скопе:**
- Per-server flag `ech: bool | EchConfig` в `TlsSpec` модели
- URI-parser добавляет `?ech=1` (auto-resolve через DNS HTTPS-record) и `?ech=<base64>` (вшитый ECHConfig)
- Builder-emit `tls.ech.{enabled, config?}` в sing-box outbound JSON
- UI checkbox "Enable ECH" в edit-node screen рядом с TLS toggle
- Tooltip / inline-help объясняющий что нужно от server side

**Не в скопе:**
- Auto-fallback "если ECH handshake fail → отключить ECH автоматически" — sing-box не даёт hook'ов; юзер сам видит fail и снимает флаг
- ECH-server side (мы клиент)
- Padding ClientHello / другие TLS-extension obfuscations — отдельные задачи
- Wildcard "включить ECH глобально на все узлы" — рискованно (server без ECH-support упадёт), only per-server opt-in
- HTTP-3 / QUIC ECH — sing-box H3 outbound'ы это самостоятельная экосистема, отдельный track

---

## Контекст

### Как ECH работает (TL;DR)

1. **Server publishes ECHConfig** — обычно через DNS HTTPS-record (тип 65), как `_443._https.example.com IN HTTPS 1 . ech="<base64>"`.
2. **Client resolves DNS** → видит `ech` параметр → берёт public key.
3. **Outer ClientHello** идёт с фейковым SNI (server_name из ECHConfig public_name, обычно CDN-front).
4. **Inner ClientHello** (с реальным SNI) шифруется HPKE через server's public key, кладётся в TLS extension `encrypted_client_hello`.
5. **Server-side**: shared frontend (CDN edge, Cloudflare) расшифровывает inner CH через свой private key → routes к реальному backend.

DPI видит TLS handshake к outer-SNI (CDN). Что внутри — не разглядеть без private key.

### Кто поддерживает на сервер-side

| Provider | Status |
|---|---|
| **Cloudflare** | Все домены за Cloudflare proxied — поддерживают ECH out-of-the-box. ~30% веба. Most likely use-case. |
| Self-hosted nginx + ECH patch | Manual setup |
| sing-box / V2Ray REALITY servers | REALITY != ECH — это другой механизм (mimick TLS handshake к стороннему сайту). Не пересекаются. |
| AWS / Akamai | Roadmap, не shipped |
| ВНИМАНИЕ — VPN providers | Большинство **не** поддерживает ECH на своих VLESS/Trojan серверах. ECH полезен **только** когда server side configured. |

### Почему Per-server toggle, не глобальный

ECH — **opt-in на сторону сервера**. Если включить на узле где сервер не поддерживает — TLS handshake fail'ится cryptic-ошибкой ("decode_error" / "missing_extension"). Глобальный switch ломает все non-ECH узлы → юзер не знает кто виноват.

Per-server toggle:
- Юзер включает только для тех узлов где знает что server поддерживает (например, Cloudflare-fronted Trojan).
- Fail mode локализован одним узлом, ping показывает -1 → юзер видит и снимает флаг.

---

## Архитектурное решение

### Модель — расширение `TlsSpec`

```dart
class TlsSpec {
  final bool enabled;
  final String? serverName;
  final List<String> alpn;
  final bool insecure;
  final String? fingerprint;
  final RealitySpec? reality;
  final EchSpec? ech;        // 🆕 §045

  const TlsSpec({
    ...
    this.ech,
  });
  ...
}

class EchSpec {
  /// Включить ECH. `config` опционально:
  /// - null → sing-box делает DNS-resolve HTTPS-record чтобы получить ECHConfig.
  /// - non-null → юзер вшил base64 ECHConfig напрямую (для серверов которые
  ///   не публикуют через DNS).
  const EchSpec({this.config, this.pqSignatureSchemesEnabled = false});

  final String? config;
  final bool pqSignatureSchemesEnabled;

  Map<String, dynamic> toSingbox() {
    final m = <String, dynamic>{'enabled': true};
    if (config != null && config!.isNotEmpty) m['config'] = config;
    if (pqSignatureSchemesEnabled) m['pq_signature_schemes_enabled'] = true;
    return m;
  }
}
```

### Builder emit — `tls_spec.dart` toSingbox()

```dart
Map<String, dynamic> toSingbox() {
  if (!enabled) return const {};
  final m = <String, dynamic>{'enabled': true};
  ...existing...
  if (ech != null) m['ech'] = ech!.toSingbox();
  return m;
}
```

### URI-parser — два формата

| URI param | Семантика |
|---|---|
| `?ech=1` (или `?ech=true`) | DNS-resolve mode (sing-box сам fetcher ECHConfig из HTTPS record) |
| `?ech=<base64-string>` | Inline mode — base64 ECHConfig вшит в URI |

Парсер ([uri_parsers.dart](../../../app/lib/services/parser/uri_parsers.dart)):
```dart
final echRaw = qp['ech'];
EchSpec? ech;
if (echRaw != null) {
  if (echRaw == '1' || echRaw == 'true') {
    ech = const EchSpec();             // DNS-resolve
  } else {
    ech = EchSpec(config: echRaw);     // inline
  }
}
```

Применяется ко всем URI parser'ам где есть TLS: vless, vmess, trojan, hysteria2, naive, anytls, tuic.

### UI — Edit Node screen

Под существующим TLS блоком (`Enable TLS / Server Name / SNI / ALPN / Skip cert verify` ...) добавляется:

```
┌─────────────────────────────────────────┐
│ TLS                                     │
│  [✓] Enable TLS                         │
│  Server name: example.com               │
│  ...existing TLS fields...              │
│  ───────────────────────────────────    │
│  [✓] Encrypted Client Hello (ECH)       │
│      ⓘ Hides SNI from DPI. Server must  │
│      support ECH (e.g. Cloudflare-      │
│      proxied domains).                  │
│      ECH config:                        │
│      [ resolve via DNS (recommended) ▾ ]│
│      OR                                 │
│      [ <inline base64 ECHConfig> ]      │
└─────────────────────────────────────────┘
```

`ECH config` dropdown:
- `Resolve via DNS (recommended)` — sing-box сам fetcher через HTTPS-record (RR-type 65)
- `Inline base64` — TextField для вставки ECHConfig вручную (для self-hosted)

Tooltip / info-icon → линк на доку: что такое ECH, какие server'ы поддерживают, troubleshooting.

### Per-protocol notes

- **VLESS/VMess/Trojan/AnyTLS** — full ECH support через `tls.ech` блок.
- **Hysteria2** — sing-box использует QUIC; ECH в QUIC отдельный draft, libbox 1.13.11 пока не поддерживает в hy2 outbound. **Скрывать toggle для hy2** (или disable с tooltip "ECH not supported in Hysteria2 yet").
- **TUIC** — то же что hy2, QUIC-based, нет.
- **Naive** — поддерживает (использует Chromium TLS stack который умеет ECH).
- **WireGuard / SS / SSH / SOCKS** — TLS не используется, toggle не показываем.

---

## Алгоритм работы (runtime)

```
Юзер включил ECH на узле:
  Edit node → TLS section → ✓ ECH → Resolve via DNS → Save

builder/build_config.dart:
  NodeSpec.toOutbound() → TlsSpec.toSingbox() → emit:
    "tls": {
      "enabled": true,
      "server_name": "example.com",
      "ech": { "enabled": true }
    }

Sing-box reload config:
  При первом connection через этот outbound:
    1. DNS resolve example.com (обычно через наш local DNS)
    2. Параллельно DNS HTTPS-record query (тип 65)
       → возвращает: ech="<base64-pubkey>" outerName="cloudflare-ech.com"
    3. Build outer ClientHello: server_name=cloudflare-ech.com
    4. Encrypt inner ClientHello (real server_name=example.com)
       через HPKE с pubkey
    5. TLS handshake идёт к IP example.com, но SNI=cloudflare-ech.com
    6. Cloudflare edge расшифровывает → routes к реальному backend

DPI на пути видит:
  TCP+TLS handshake к Cloudflare IP, server_name=cloudflare-ech.com
  Реальный target скрыт.
```

### Failure modes

| Симптом | Причина | Что делать |
|---|---|---|
| Ping узла -1 + лог `tls: ech: missing key share` | Server не поддерживает ECH | Снять toggle |
| Ping -1 + лог `dns: HTTPS record not found` | DNS provider не возвращает HTTPS-record (часть public DoH'ов фильтруют) | Use DNS-over-HTTPS to Cloudflare/Google directly, либо inline mode |
| Ping OK но соединение медленнее | Дополнительный DNS roundtrip за HTTPS-record | Acceptable cost, обычно <50ms |

---

## UI

### Edit Node screen

Новый блок в TLS section (см. диаграмму выше).

### Custom nodes индикатор

В списке узлов (Home screen) — мелкая 🔒 icon рядом с node.tag когда `tls.ech.enabled = true`. Tooltip "ECH enabled" на long-press. Helps user spot который узел "защищённый плотнее".

### Tooltip контент

```
Encrypted Client Hello (ECH)

Шифрует SNI в TLS handshake — DPI видит только
прокси-имя (обычно CDN front), не реальный сервер.

Требует поддержку на стороне сервера. Cloudflare-
proxied домены поддерживают ECH из коробки. Self-
hosted сервера обычно нет.

Если включение приводит к -1 ping, отключите —
сервер не настроен.
```

---

## Тесты

- `test/models/tls_spec_test.dart` — `TlsSpec.copyWith` сохраняет `ech`, `toSingbox` правильный shape с/без `config`.
- `test/parser/uri_parsers_test.dart` — `?ech=1` и `?ech=<base64>` парсятся в `EchSpec` с правильными полями для VLESS/Trojan/VMess.
- `test/builder/build_config_test.dart` — outbound JSON содержит `tls.ech.enabled=true` когда node.tls.ech != null.
- Snapshot test — fixture с EchConfig inline + DNS-resolve mode, expected sing-box JSON.

---

## Ограничения и риски

| # | Риск | Mitigation |
|---|---|---|
| 1 | Юзер включает ECH на узле где сервер не поддерживает → ping -1, юзер не понимает в чём дело | Tooltip + добавить в /diag handler специальный hint когда видим `tls: ech` errors в core logs |
| 2 | DNS provider не поддерживает HTTPS-record → ECH не активируется | Auto-fallback: если HTTPS-record empty → log warning, продолжаем без ECH (sing-box default behavior). Юзер видит warning. |
| 3 | Inline ECHConfig устаревает (server rotates keys) | DNS-resolve mode рекомендован по дефолту — refresh keys автоматически. Inline только для self-hosted edge cases. |
| 4 | ECH в QUIC (hy2/tuic) не поддерживается libbox 1.13.11 | Скрываем toggle для этих protocols. Когда libbox upgrade — pereenable. |
| 5 | Anti-ECH censorship (Россия, Иран блокируют ECH хэндшейки) | Тогда юзеру нужно **отключить** ECH на проблемной сети. Возможно future spec — auto-disable per network ([§051 wifi conditions](../../tasks/051-custom-rule-wifi-conditions.md) infrastructure можно reuse) |
| 6 | Flutter URI parser breaking change при добавлении `?ech=` — old URIs остаются валидными | URI params backward-compat — отсутствующий `ech` → null → старый behavior |

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `app/lib/models/tls_spec.dart` | `EchSpec` class + `ech` field в `TlsSpec` + copyWith + ==/hashCode + toSingbox emit |
| `app/lib/services/parser/uri_parsers.dart` | Парсинг `?ech=` для всех TLS-protocol URI parsers (vless / vmess / trojan / hysteria2 / naive / anytls / tuic) |
| `app/lib/services/parser/json_parsers.dart` | Если sing-box JSON outbound содержит `tls.ech.{enabled, config}` — парсить в `EchSpec` |
| `app/lib/screens/node_settings_screen.dart` | UI блок ECH (checkbox + dropdown DNS/inline + TextField для inline base64) |
| `app/lib/widgets/node_row.dart` | 🔒 indicator на node row когда `node.tls.ech != null` |
| `test/models/tls_spec_test.dart` | Unit тесты EchSpec + TlsSpec.copyWith |
| `test/parser/uri_parsers_test.dart` | URI param `?ech=` для каждого protocol |
| `test/builder/build_config_test.dart` | Snapshot — outbound с ECH в final JSON |
| `docs/PROTOCOLS.md` | Раздел "ECH support" — какие protocols поддерживают |

Estimated work: **~1 день** (модель + парсер + emit + 1 UI блок + тесты).

---

## Критерии приёмки

- [ ] Юзер открывает edit-node для VLESS/Trojan узла → видит "Encrypted Client Hello" toggle.
- [ ] Toggle ON + DNS-resolve mode → save → builder emit'ит `tls.ech.enabled=true` (без `config`).
- [ ] Toggle ON + inline mode + base64 → save → builder emit'ит `tls.ech.{enabled, config: "<base64>"}`.
- [ ] URI с `?ech=1` парсится в node с `tls.ech` non-null.
- [ ] URI с `?ech=<base64>` парсится с `EchSpec(config: <base64>)`.
- [ ] Edit node → отключаем ECH → save → outbound JSON без `ech` блока.
- [ ] Hysteria2 / TUIC / WireGuard / SS / SSH узлы — ECH toggle скрыт (или disabled с tooltip "not supported").
- [ ] На реальном Cloudflare-proxied узле (тест-сервер): handshake проходит, ping ОК.
- [ ] На non-ECH узле: после включения toggle ping становится -1, в core-логах `tls: ech: <error>`. Юзер видит, понимает.
- [ ] 🔒 indicator появляется на node row когда ECH enabled, исчезает при отключении.

---

## Будущие расширения (вне §045)

- **Per-network auto-toggle** — когда юзер на network где ECH блокируется (Россия, Иран) — авто-disable. Использует [§051](../../tasks/051-custom-rule-wifi-conditions.md) wifi-conditions infrastructure.
- **ECH in HTTP/3** — когда libbox upgrade и hy2/tuic outbound'ы получат ECH support.
- **Auto-discover ECH-capable servers** — сделать background HTTPS-record probe для каждого нового узла + предложить включить ECH автоматически (может быть annoying — ставить на «advanced» toggle).

---

## Ссылки

- [RFC draft-ietf-tls-esni-18 — ECH spec](https://datatracker.ietf.org/doc/draft-ietf-tls-esni/)
- [Cloudflare ECH announcement (2023)](https://blog.cloudflare.com/announcing-encrypted-client-hello/)
- [sing-box TLS docs — ech](https://sing-box.sagernet.org/configuration/shared/tls/#ech)
- [§028 — mixed-case SNI](../028%20antidpi%20sni%20obfuscation/spec.md) — предыдущая anti-DPI ступень
- [§020 — security and DPI bypass](../020%20security%20and%20dpi%20bypass/spec.md) — TLS Fragment + общая anti-DPI стратегия
