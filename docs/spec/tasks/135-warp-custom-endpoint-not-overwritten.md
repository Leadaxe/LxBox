# 135 — WARP: кастомный endpoint из Advanced не должен затираться ответом Cloudflare

| Field | Value |
|------|----------|
| Status | Done (device-smoke pending) |
| Started | 2026-06-16 |
| Trigger | Поле field-report (Iliya, Крым): «Меняю endpoint на ваш ip:port — register, файл создаётся, но если глянуть в json то endpoint **сохраняется без изменений**». Юзер вписывал в Advanced `188.114.97.6:988` (живой Cloudflare-endpoint на нестандартном порту из публичного генератора), а в конфиг шёл дефолтный `engage.cloudflareclient.com:2408` — заблокированный его провайдером. Advanced-поле Endpoint было фактически мёртвым. |
| Related | [§025 warp integration](../features/025%20warp%20integration/spec.md) (Advanced → Endpoint); [§126](126-warp-amneziawg-obfuscation.md) (обфускация поверх); [§132](132-warp-endpoint-scanner-research.md) (research: подбор живого endpoint — этот фикс его предпосылка); [[project_warp_integration]] |
| Files touched | `app/lib/services/warp/warp_client.dart` (`_parseReg`); `app/test/warp/warp_client_test.dart` (+2 теста) |

## Корень

[warp_client.dart](../../../app/lib/services/warp/warp_client.dart) `_parseReg`:

```dart
String host = endpoint;                 // взяли endpoint из Advanced
if (peersRaw is List && ...) {
  final ep = peer['endpoint'];
  if (ep is Map) {
    final h = (ep['host'] as String?) ?? '';
    if (h.isNotEmpty) host = h;         // ← БЕЗУСЛОВНО затирал ответом API
  }
}
```

Cloudflare на `/reg` **всегда** возвращает `peer.endpoint.host = engage.cloudflareclient.com:2408`.
Поэтому `host` всегда перезаписывался дефолтом, и пользовательский ввод из
Advanced молча терялся. Юзер видел «endpoint без изменений» в JSON.

## Фикс

Кастомный endpoint (юзер вписал не-дефолт) **приоритетнее** ответа Cloudflare.
Ответ API используем только как fallback, когда юзер оставил дефолт.

```dart
final userPickedEndpoint = endpoint != WarpAccount.defaultEndpoint;
...
if (ep is Map && !userPickedEndpoint) {   // ← затираем ТОЛЬКО при дефолте
  final h = (ep['host'] as String?) ?? '';
  if (h.isNotEmpty) host = h;
}
```

- Юзер вписал `188.114.97.6:988` → `userPickedEndpoint=true` → ответ API игнорируется → в конфиг идёт его endpoint.
- Юзер оставил дефолт (`WarpAccount.defaultEndpoint`) → старое поведение (host из ответа Cloudflare).

Сигнал «юзер выбрал» = «endpoint != defaultEndpoint». Визард
([warp_wizard_screen.dart:54](../../../app/lib/screens/warp_wizard_screen.dart#L54))
уже передаёт `defaultEndpoint`, когда поле пустое → корректно различается.

## Acceptance

- [x] Кастомный endpoint из Advanced доезжает до `WarpAccount.endpoint` (и в `.conf`/JSON узла).
- [x] Дефолтный endpoint → fallback на host из ответа Cloudflare (старое поведение не сломано).
- [x] Тесты: `§135 ... НЕ затирается` + `§135 ... fallback на host`; существующий `register: 200 → ...` (без аргумента endpoint) проходит без изменений.
- [ ] Device-smoke: с кастомным endpoint узел реально подключается и даёт трафик у заблокированного провайдера. **PENDING — на устройстве у клиента** (отдельно от того, что i1-QUIC-шаблон может потребоваться — см. §133).

## NB

Этот фикс — **предпосылка** для §132 (подбор живого endpoint): без него любой
подобранный/введённый `IP:port` всё равно затирался дефолтом. Сам по себе фикс
не гарантирует обход DPI — если провайдер режет WG-паттерн на любом IP, нужен
ещё junk-шаблон под живой протокол (QUIC, §133/§126). Разделение причин — в
field-report'е: правильный endpoint **необходим, но может быть недостаточен**.
