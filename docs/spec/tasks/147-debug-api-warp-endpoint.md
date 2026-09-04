# 147 — Debug API: POST /warp (регистрация WARP-узла без UI)

| Field | Value |
|------|----------|
| Status | Implemented (analyze ✅, device-test pending) |
| Started | 2026-06-18 |
| Trigger | Для device-тестов WARP-обфускации (§143/§146 — генерит ли ядро `lx.12` фрагментированный QUIC из `id/ip/ib`) нужно заводить WARP-узел программно. В Debug API **не было** эндпоинта для Get WARP — регистрация только из UI-визарда (`WarpWizardScreen`). `/subs` принимает лишь готовый конфиг (raw_body), а не штатный `addWarp` (регистрация в Cloudflare + генерация ключей на устройстве). |
| Related | [§025](../features/025%20warp%20integration/spec.md) (WARP), [§143](143-warp-masquerade-id-ip-ib.md) (id/ip/ib), [§146](146-warp-quic-initial-fragmented-i1.md) (фрагментированный i1), [§031] (Debug API) |
| Files touched | NEW `services/debug/handlers/warp.dart`; EDIT `services/debug/transport/server.dart` (mount), `services/debug/handlers/help.dart` (capability map text+json) |

## Что сделано

`POST /warp` — дёргает `SubscriptionController.addWarp(...)` тем же путём, что кнопка Get WARP. `addWarp` сам регистрирует аккаунт в Cloudflare (приватник на устройстве), синкает обфускацию и **добавляет узел в подписки** (`_addWarpObfuscated`/`_addWarpPlain`). Handler только маппит body → параметры, проверяет `lastError`, опц. rebuild.

### Body (все поля опц., дефолты = как в визарде)

```jsonc
{
  "licenseKey": "...",        // null/пусто → free WARP
  "endpoint": "IP:port",      // дефолт WarpAccount.defaultEndpoint
  "obfuscate": true,          // §126/§143 AmneziaWG обфускация
  "forceNew": false,          // игнор кеша, регать заново
  "includeReserved": false,   // §142; null → дефолт по obfuscate
  "quicParams": {             // §143 masquerade (при obfuscate)
    "sni": "www.google.com",  // пусто → рандом из пула
    "ip": "quic",             // quic|dns|stun|sip
    "ib": "curl",             // chrome|firefox|curl (только quic)
    "jc": 4, "jmin": 40, "jmax": 70
  }
}
```

`?rebuild=true` — после успеха `generateConfig` + `saveParsedConfig` (узел в рантайме ядра без отдельного rebuild-config). Паттерн `maybeRebuild` как у `/subs`.

### Ответ (201)

```json
{"ok": true, "action": "warp-add", "warp_plus": false,
 "obfuscated": true, "endpoint": "...", "address": "172.16.0.2", ...rebuild-extras}
```

Ошибка `addWarp` (null + `lastError`) → `BadRequest('addWarp failed: ...')`.

## Контракт (повторяет визард)

- `licenseKey` пусто → null (free). `endpoint` пусто → `WarpAccount.defaultEndpoint`.
- `quicParams` собирается из вложенного объекта; отсутствующие поля → дефолты `QuicParams`. Неверный тип поля → `BadRequest` (strict `fieldString/fieldInt`).
- `includeReserved` null → `addWarp` применит дефолт по `obfuscate` (§142).

## Acceptance

- [x] `flutter analyze` — No issues (warp.dart, server.dart).
- [ ] Device: `POST /warp {obfuscate:true, quicParams:{ip:quic}}` → 201, узел в подписках, `?rebuild=true` кладёт в конфиг ядра.
- [ ] Device: free WARP (без body) → 201, plain-узел.
- [ ] Невалидный quicParams-тип → 400 BadRequest.

## NB

Debug-only инструмент (§031, bind 127.0.0.1, bearer-token). Не влияет на прод-поток Get WARP (UI-визард не тронут). Цель — программный device-тест §146 (фрагментированный QUIC из ядра `lx.12`).
