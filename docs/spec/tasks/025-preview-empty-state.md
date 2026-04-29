# 025 — Preview empty-state без потери данных

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`031 debug api`](../features/031%20debug%20api/spec.md), [`003 home screen`](../features/003%20home%20screen/spec.md) |

## Проблема

Чтобы посмотреть как выглядит главный экран при пустом состоянии (без подписок и узлов), нужно делать `pm clear` или ручную чистку — теряются реальные данные пользователя. Для скриншотов / regression UX / демо новых empty-state'ов это слишком destructive.

## Решение

UI-only override-флаг в `HomeController`:

```kotlin
bool _previewEmpty = false;
bool get previewEmpty => _previewEmpty;
void setPreviewEmpty(bool on) { … notifyListeners(); }
```

В [`HomeScreen.build`](../../../app/lib/screens/home_screen.dart) — effective state через `copyWith`:

```dart
final state = _controller.previewEmpty
    ? realState.copyWith(configRaw: '', nodes: const [])
    : realState;
```

Реальные данные `_controller._state` не трогаются — только UI рендерит empty.

Управление через Debug API: новый action в [`handlers/action.dart`](../../../app/lib/services/debug/handlers/action.dart):

```
POST /action/preview-empty-state?on=true|false
```

## Verification

```bash
# Включил preview — UI пустой, данные на месте
curl -X POST -H "$HDR" "$BASE/action/preview-empty-state?on=true"
# Сделал скриншот / проверил UX
curl -X POST -H "$HDR" "$BASE/action/preview-empty-state?on=false"
# UI вернулся к нормальному виду со всеми подписками
```
