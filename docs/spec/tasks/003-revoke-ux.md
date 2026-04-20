# 003 — Revoke UX: friendly handling когда другое VPN захватило туннель

| Поле | Значение |
|------|----------|
| Статус | Done (code + build) / pending manual verification |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | `82b5b49` feat(vpn): revoke UX + lifecycle resume re-sync |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md) |

## Проблема

Android позволяет только одному VPN-клиенту быть активным одновременно. Когда юзер запускает другое VPN-приложение (Hiddify, WireGuard, FortiClient и т.д.), Android вызывает `VpnService.onRevoke()` на нашем service — туннель отзывается.

Native корректно ловит revoke:
- `onRevoke()` → `setStatus(Stopped, error='VPN revoked by another app')`
- broadcast → `_handleStatusEvent` → `tunnel = TunnelStatus.revoked`

Но UX до этой задачи был хреновый:
- Status chip показывал красную пилюлю «Revoked by another VPN» с warning-иконкой
- Постоянно висела на экране — пугающее error-состояние
- Юзеру непонятно что делать: Start есть, но state «ошибочный»

**Что нужно:** нейтральный UX. Юзер видит уведомление «VPN taken by another app» с быстрой кнопкой Start, всё остальное выглядит как обычный off-state. Нажал Start → система показывает диалог подтверждения → конкурент отдаёт слот → мы поднимаемся. Естественный flow.

## Диагностика

Не баг, feature request / UX polish. Причина уродства — ранний вариант кода использовал revoked для визуального алярма. После того как добавили keep-on-exit и всё остальное lifecycle — revoked утратил смысл «error», стал «state transition, вызванный внешним событием».

Единственное что нужно проверить: что native-path для Start после revoked реально работает. Проверил:

- `VpnService.prepare(activity)` при занятом слоте возвращает non-null intent (требуется permission у юзера).
- `VpnPlugin.startVpn()` [290-303](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) обрабатывает этот путь: сохраняет `pendingVpnResult`, вызывает `startActivityForResult(VPN_REQUEST_CODE)`, ждёт `onActivityResult`.
- При approve юзером — `BoxVpnService.start(context)` вызывается → конкурирующий VPN получает свой `onRevoke` → мы занимаем слот.

Механизм native готов, трогать не надо.

## Решение

Три точки касания:

### 1. SnackBar при transition → revoked

**`home_screen.dart`:**

```dart
TunnelStatus _prevTunnel = TunnelStatus.disconnected;

@override
void initState() {
  // ...
  _prevTunnel = _controller.state.tunnel;
  _controller.addListener(_onControllerChange);
}

void _onControllerChange() {
  final now = _controller.state.tunnel;
  if (_prevTunnel != TunnelStatus.revoked && now == TunnelStatus.revoked) {
    _showRevokedSnackBar();
  }
  _prevTunnel = now;
}

void _showRevokedSnackBar() {
  if (!mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('VPN taken by another app'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Start',
          onPressed: () => unawaited(_controller.start()),
        ),
      ),
    );
}

@override
void dispose() {
  _controller.removeListener(_onControllerChange);
  // ...
}
```

Listener — не AnimatedBuilder (который уже rebuildит UI). AnimatedBuilder вызывает builder внутри build-фазы, делать там `showSnackBar` нельзя. Отдельный listener для side-effect'ов вне build.

### 2. UI mapping: revoked как disconnected

**`home_screen._buildStatusChip`** — убраны все ветки `isRevoked ? error... : up...`, chip рисуется как обычный off-state:

```dart
final icon = state.tunnelUp ? Icons.shield
    : isConnecting ? Icons.sync : Icons.shield_outlined;
// color/bgColor только для tunnelUp
final label = isRevoked ? TunnelStatus.disconnected.label : state.tunnel.label;
```

Внутреннее значение `state.tunnel == revoked` сохраняется — оно нужно для `_onControllerChange` чтобы детектить transition. UI-слой маппит в нейтральное представление только на visual output.

### 3. Сброс Clash endpoint в revoked-ветке

**`home_controller._handleStatusEvent`**, revoked/disconnected branch:

```dart
_clash = null;
```

Предыдущий endpoint указывал на мёртвый sing-box с невалидным secret'ом. На следующем `connected` event `_refreshClashAfterTunnel` → `_rebuildClashEndpoint` пересоздаст из свежего конфига.

Все callers `_clash` в коде (см. grep `_clash\?`) уже проходят через null-check, поэтому безопасно — просто станут no-op до следующего connected.

## Риски и edge cases

### Покрыто

- **Multiple revokes подряд.** `clearSnackBars()` + новый показ — юзер не увидит накопившиеся сообщения.
- **SnackBar на другом экране.** `ScaffoldMessenger.maybeOf(context)` берёт ближайший. Если юзер открыл другую страницу (например Settings) и в этот момент revoke — SnackBar покажется на той странице. Scaffold-based, работает.
- **Listener leak.** `removeListener` в dispose.
- **SnackBar lifecycle.** `mounted` check перед show.
- **Revoked → connected → revoked:** `_prevTunnel` обновляется в listener'е, каждый новый transition в revoked show'ит SnackBar.
- **App suspended в revoked, resume:** `_prevTunnel` пересчитается через resume-pull path (P3 004); если native = Stopped (не revoked) — SnackBar не покажется, правильно.

### Намеренно НЕ покрыто

- **Silent revoke без broadcast.** Если Android убил наш service тихо (OOM, Doze, etc.) и потом мы resume'имся — получаем `status=Stopped` на pull, а не `revoked`. Юзер увидит обычный off-state, без snackbar'а. Это acceptable trade-off: мы не знаем что случился именно revoke (как отличить OOM от revoke без error-string?).
- **Retry если Start при revoked fails.** Если после SnackBar-Start юзер отказался в системном диалоге — snackbar'а не будет снова (юзер сам решил). Но chip остаётся disconnected, обычная Start кнопка активна.
- **`TunnelStatus.fromNative` default `disconnected`.** Сейчас неизвестный raw → disconnected. Лучше бы `unknown`. Отложено — не блокирует текущую фичу.

## Верификация

- `dart analyze` clean
- `flutter build apk --debug` succeeds

**Manual test (pending, требует device + другое VPN-приложение):**
1. На устройстве запущен L×Box, tunnel connected.
2. Запустить Hiddify / WireGuard / FortiClient, запустить их VPN.
3. Ожидание: SnackBar «VPN taken by another app» с action Start. Chip показывает Disconnected.
4. Нажать Start в SnackBar. Ожидание: system dialog «VPN connection request». Approve.
5. Ожидание: L×Box поднимается, конкурент получает onRevoke и ложится.
6. Проверить logcat: native path прошёл через VpnService.prepare, onActivityResult, BoxVpnService.start.

## Нерешённое / follow-up

- ~~**`TunnelStatus.unknown`**~~ — закрыто, см. [007](./007-peer-review-tasks-001-006.md) follow-up.
- ~~**Unified cleanup `_onTunnelDead` vs `_handleStatusEvent`**~~ — закрыто после peer review: `_onTunnelDead` теперь сбрасывает `_clash=null`, `traffic=zero`, `connectedSince=null`, `configStaleSinceStart=false`, `_autoPingTimer.cancel` — совпадает с ветвью revoked/disconnected в `_handleStatusEvent`. Единый контракт очистки.
- **Battery/Doze silent kill detection** — отдельная задача (отложено пользователем).
- Spec `003 home screen` обновлён в коммите `fa248b5` (§8c Revoke UX).
