# §123 — Имя сервера в шторке (foreground notification)

**Статус:** Done (проверено на устройстве 2026-06-14)
**Тип:** task (UX-улучшение существующей фичи [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md))
**Дата:** 2026-06-14

## Хотелка

> «хорошо бы имя сервера видно было в шторке»

Сейчас постоянное уведомление foreground-сервиса показывает только бренд и статус:

```
L×Box
Connected
```

Из шторки нельзя понять, на какой сервер/ноду сейчас идёт трафик и куда указывает дефолтный маршрут.

## Целевой вид

```
L×Box [final = direct]          ← title:  бренд + сырое route.final
vpn-1: L: 🇫🇮⚡Финляндия-2        ← text:   <селектор>: <выбранная нода>
```

- **title** = `L×Box [final = <route.final>]`, где `<route.final>` — **сырое** значение
  `route.final` из конфига (`direct`, имя группы/селектора, тег ноды и т.п.).
- **text** = `<селектор>: <выбранная нода>`:
  - **селектор** = `HomeState.selectedGroup` (активный селектор, напр. `vpn-1`) —
    динамически из стейта, **не** хардкод.
  - **нода** = `HomeState.activeInGroup` — это `now` селектора (выбранный outbound),
    который `applyGroup` берёт из `entry['now']` группы. Показываем **целиком как
    есть**, с префиксом `L: ` и эмодзи (напр. `L: 🇫🇮⚡Финляндия-2`).

> Изначально подтекст планировался как один `activeInGroup`, но `activeInGroup` —
> это уже выбранная нода (`now`), а не имя селектора. Юзер хочет видеть **обе**
> части: и селектор (`vpn-1`), и куда он указывает. Отсюда формат `<селектор>: <нода>`.

### Fallback'и для text

| Условие | text |
|---|---|
| есть селектор и нода | `<селектор>: <нода>` (`vpn-1: L: 🇫🇮⚡Финляндия-2`) |
| есть селектор, нет ноды | `<селектор>` (`vpn-1`) |
| нет селектора, есть нода | нода целиком |
| нет селектора и ноды, есть `route.final` | `route.final` (напр. `direct`) |
| ничего (момент старта) | статус от native: `Connecting…` / `Connected` |

## Архитектурное решение

**Принцип: Dart владеет обеими строками уведомления, native их не затирает.**

Проблема текущего кода: title берётся из `ConfigManager.notificationTitle`
(управляется из Dart через `setNotificationTitle`), а **text хардкодится в native**
(`BoxService.kt`: `"Starting..."`, `"Connected"`, `"Error"`). Если бы Dart слал text
другим каналом, любой следующий native-вызов `show(...)` (реконнект, reload) затёр бы
его обратно на `"Connected"`.

Решение — симметрия с `notificationTitle`: завести `notificationText` в `ConfigManager`,
дать method-channel `setNotificationText`, и в native использовать
`ConfigManager.notificationText` вместо хардкода (с fallback на `"Connected"`, если пусто).
Так оба значения живут в `ConfigManager`, native при своих `show(...)` берёт актуальные,
ничего не теряется.

## Изменения

### Native (Kotlin)

| Файл | Изменение |
|---|---|
| `ConfigManager.kt` | + `var notificationText: String = ""` (private set) + `fun setNotificationText(text: String)` — симметрично `notificationTitle` |
| `VpnPlugin.kt` | + handler `"setNotificationText"` → `ConfigManager.setNotificationText(text)` |
| `BoxService.kt` | строка `"Connected"` (point §«Started») → `ConfigManager.notificationText.ifEmpty { "Connected" }`. `"Starting..."` и `"Error"` оставляем (ноды/тега ещё/уже нет) |
| `ServiceNotification.kt` | без изменений — `show(title, text)` уже параметризован |

### Dart

| Файл | Изменение |
|---|---|
| `vpn/box_vpn_client/method_names.dart` | + `static const setNotificationText = 'setNotificationText'` |
| `vpn/box_vpn_client.dart` | + `Future<bool> setNotificationText(String text)` (по образцу `setNotificationTitle`, timeout `_Timeouts.settings`) |
| `controllers/home_controller.dart` | + приватный `_pushNotificationLabels()`: собирает title (`L×Box [final = …]` через `ClashEndpoint.routeFinalTag`) и text (тег / final / пусто), шлёт `setNotificationTitle` + `setNotificationText`. Вызывается из `_startInternal` (вместо хардкода `setNotificationTitle('L×Box')`), `applyGroup`, `switchNode` |

### Точки вызова `_pushNotificationLabels()`

- `_startInternal()` — заменяет текущий `await _vpn.setNotificationTitle('L×Box')`.
- `applyGroup()` — после того как `activeInGroup` стал известен (первичная загрузка прокси).
- `switchNode()` — после успешного `selectInGroup` + `reloadProxies` (юзер сменил ноду
  при активном VPN; шторка должна обновиться сразу).

## Контракт строк (Dart `_pushNotificationLabels`)

```
final routeFinal = ClashEndpoint.routeFinalTag(_state.configRaw);   // напр. "direct"
final title = routeFinal == null || routeFinal.isEmpty
    ? 'L×Box'
    : 'L×Box [final = $routeFinal]';

final node = _state.activeInGroup;
final text = (node != null && node.isNotEmpty)
    ? node
    : (routeFinal ?? '');   // пусто → native fallback на "Connected"
```

## Не делаем

- Реальный хост (`server[:port]`) из конфига — не показываем, по решению: text = тег.
- Разыменование `final = <группа>` → активная нода группы — не делаем, title = сырое
  `route.final`.
- Live-обновление при auto-switch внутри url-test/load-balance группы без участия юзера —
  вне скоупа (нет события). Обновляется на: старт, первичную загрузку, ручной switch.

## Acceptance

- [x] При активном VPN в шторке title = `L×Box [final = <route.final>]`
      (проверено: `L×Box [final = vpn-1]`).
- [x] text = `<селектор>: <нода>`; меняется при ручном переключении ноды
      (проверено: `vpn-1: L: 🇫🇮⚡Финляндия-2`).
- [x] Нет ноды → `<селектор>`; нет селектора → нода/`route.final`; ничего →
      `Connecting…`/`Connected`.
- [x] Реконнект / reload не затирает строки на хардкод (Dart владеет обеими).
