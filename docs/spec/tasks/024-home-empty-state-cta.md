# 024 — Home empty-state guide + tap-to-connect zone

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), [`009 ux and theme`](../features/009%20ux%20and%20theme/spec.md) |

## Проблема

На главном экране — два пустых состояния, оба пассивные:

1. **Нет конфига** (`configRaw.isEmpty`): disabled Start + текст «No config loaded. Use Quick Start or add a subscription.» без CTA. Свежеустановленное приложение → disabled UI без явного маршрута.
2. **Конфиг есть, VPN не запущен** (`nodes.isEmpty && !tunnelUp`): текст «Tap Start to connect.» — но это **просто текст**, тап не работает; нужно прицеливаться в маленькую FilledButton сверху.

## Решение

Изменения только в [`home_screen.dart`](../../../app/lib/screens/home_screen.dart).

### Empty state — `state.configRaw.isEmpty`

В `_buildNodeList`:
- Крупная иконка `Icons.dns_outlined` (64dp).
- Заголовок «Add a server» (titleLarge, bold).
- Subtitle «Connect a subscription or add a node manually».
- Круглая `FloatingActionButton` (большой `+`) → push `SubscriptionsScreen`.

`_buildControls` в этом состоянии не рендерится — стартовать нечего, disabled-кнопка только путает (`if (state.configRaw.isNotEmpty) _buildControls(...)` в `build()`).

### Tap-to-connect zone — `nodes.isEmpty && !tunnelUp && configRaw.isNotEmpty`

Кликабельная зона `InkWell` по центру: иконка `Icons.play_circle_outline` (64dp, `cs.primary`) + текст «Tap to connect» (titleMedium, primary color, bold). Тап стартует VPN тем же путём что и FilledButton в `_buildControls` (haptic + `_startWithAutoRefresh()`). Disabled во время transient состояний (`busy`/`connecting`/`stopping`).

## Verification

- Чистая инсталляция — большой `+` ведёт на `SubscriptionsScreen`.
- Конфиг есть, не подключены — большая `Tap to connect` зона стартует VPN.
- VPN активен — узлы рендерятся как раньше, никаких изменений.
