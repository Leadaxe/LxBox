# 138 — WARP: закешированный аккаунт игнорирует выбранный в Advanced endpoint

| Field | Value |
|------|----------|
| Status | Fixed |
| Started | 2026-06-16 |
| Trigger | Жалоба юзера (v2.3.2): «созданный конфиг не сохраняет настройки из Advanced — выбираю любой endpoint, в сохранённой конфигурации остаётся вариант от обычного WARP». §135 чинил `register`, но баг остался — корень глубже. |
| Related | [§135](135-warp-custom-endpoint-not-overwritten.md) (endpoint не затирается ответом Cloudflare — но только в `register`); [§136](136-warp-quic-i1-generator.md) (рандом endpoint); [§025](../features/025%20warp%20integration/spec.md) |
| Files touched | `controllers/subscription_controller.dart` (`addWarp` — резолв+применение endpoint), `test/services/warp_obfuscation_test.dart` (+регресс) |

## Корень

[subscription_controller.dart](../../../app/lib/controllers/subscription_controller.dart) `addWarp`:

```dart
WarpAccount? account =
    (reuse && !forceNew) ? await SettingsStorage.getWarpAccount() : null; // кеш!
...
account ??= await warp.register(... endpoint ...);  // ← register ТОЛЬКО если account==null
```

Если у юзера уже есть закешированный WARP-аккаунт (создавал раньше), при
повторном Get WARP берётся **кеш** (`reuse=true` по умолчанию). Тогда
`account ??= register(...)` — account уже не null → **`register` НЕ вызывается**,
и весь endpoint-код (§135/§136) внутри register **минуется**. Узел собирается из
`account.endpoint` = старый дефолтный endpoint из кеша. Выбор юзера в Advanced
теряется.

§135 был необходим, но недостаточен: он чинил путь `register`, а баг — на пути
переиспользования кеша, где register не зовётся.

## Фикс

Резолв endpoint вынесен **до** register и **применяется к аккаунту независимо**
от того, свежий он или из кеша:

```dart
final userPicked = endpoint != WarpAccount.defaultEndpoint;
final resolvedEndpoint = userPicked
    ? endpoint                                            // юзер вписал свой
    : (obfuscate ? (picker.randomEndpoint() ?? endpoint)  // §136 рандом
                 : endpoint);                             // дефолт

account ??= await warp.register(endpoint: resolvedEndpoint, randomEndpoint: null, ...);

// КЛЮЧЕВОЕ: применяем к аккаунту даже из кеша.
if (resolvedEndpoint != account.endpoint && (userPicked || obfuscate)) {
  account = account.copyWith(endpoint: resolvedEndpoint);
}
```

- Свежий register: endpoint уже правильный (§135 в `_parseReg` не затрёт, т.к.
  `resolvedEndpoint != default`) → `copyWith` идемпотентен.
- Кешированный аккаунт: register минуется, но `copyWith(endpoint:)` применяет
  выбранный/рандомный endpoint поверх кеша → в узел идёт правильный.
- Рандомизация перенесена из `register` сюда (одна точка); `register` больше не
  рандомит (`randomEndpoint: null`).

## Acceptance

- [x] Закешированный аккаунт + кастомный endpoint в Advanced → в узел идёт кастомный (не старый из кеша).
- [x] Закешированный аккаунт + обфускация + дефолт → рандомный endpoint применяется.
- [x] Свежая регистрация (без кеша) — поведение §135/§136 не сломано.
- [x] Регресс-тест: `copyWith(endpoint)` применяет endpoint, доходит до URI узла.
- [x] `flutter analyze` чисто; WARP-тесты зелёные.
- [ ] Device-smoke: на телефоне с уже существующим WARP выбрать endpoint → проверить узел.

## NB

Так же лечится для **QUIC-параметров/SNI**: `_syncWarpObfuscation` уже
перегенерирует `awg` поверх закешированного аккаунта с `resolvedParams` (это
работало). Проблема была только с endpoint (он живёт в самом `WarpAccount`, а не
в awg). После §138 и endpoint, и awg применяются к кешу.
