# 026 — Subscription Toggles

**Status:** Реализовано

## Контекст

При наличии нескольких подписок пользователю нужна возможность временно отключить часть из них без удаления. Отключённые подписки не должны участвовать в генерации конфига и массовом обновлении — это позволяет быстро переключать наборы узлов.

## Реализация

### Модель ProxySource

Поле `enabled` (bool, по умолчанию `true`) добавлено в модель `ProxySource`. Сериализуется/десериализуется в JSON вместе с остальными полями подписки. При загрузке старых данных без поля `enabled` значение по умолчанию — `true` (обратная совместимость).

```dart
class ProxySource {
  // ...existing fields...
  bool enabled;

  ProxySource({
    // ...
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    // ...
    'enabled': enabled,
  };

  factory ProxySource.fromJson(Map<String, dynamic> json) => ProxySource(
    // ...
    enabled: json['enabled'] ?? true,
  );
}
```

### UI: Switch в списке подписок

На экране `SubscriptionsScreen` каждая подписка отображается с `Switch` виджетом в leading позиции. При отключении:
- Текст названия и статуса становится серым (`Colors.grey`)
- Switch переключает `source.enabled` и вызывает сохранение
- Список не перестраивается — подписка остаётся на месте

```
┌────────────────────────────────────┐
│  Subscriptions                [+]  │
│  ┌──────────────────────────────┐  │
│  │ [✓] Provider A  · 42 nodes  │  │
│  │ [ ] Provider B  · 18 nodes  │  │  ← серый текст
│  │ [✓] Provider C  · 7 nodes   │  │
│  └──────────────────────────────┘  │
└────────────────────────────────────┘
```

### ConfigBuilder

`ConfigBuilder` при генерации конфига фильтрует список источников:

```dart
final enabledSources = sources.where((s) => s.enabled).toList();
```

Узлы из отключённых подписок не попадают в outbounds, preset groups и т.д.

### SubscriptionController

Метод `updateAllAndGenerate()` пропускает отключённые подписки при массовом обновлении:

```dart
final toUpdate = sources.where((s) => s.enabled).toList();
for (final source in toUpdate) {
  await _updateSource(source);
}
```

Обновление отдельной подписки через контекстное меню или detail screen работает независимо от `enabled`.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/models/proxy_source.dart` | Поле `enabled`, сериализация/десериализация |
| `lib/controllers/subscription_controller.dart` | Фильтрация disabled в `updateAllAndGenerate()` |
| `lib/screens/subscriptions_screen.dart` | Switch виджет, визуальное затемнение disabled подписок |
| `lib/services/config_builder.dart` | Фильтрация disabled источников при генерации конфига |

## Критерии приёмки

- [x] Поле `enabled` на модели ProxySource, по умолчанию `true`
- [x] Поле сохраняется и загружается из JSON
- [x] Switch отображается в списке подписок
- [x] Отключённая подписка отображается серым текстом
- [x] ConfigBuilder исключает узлы отключённых подписок
- [x] updateAllAndGenerate пропускает отключённые подписки
- [x] Обратная совместимость: старые данные без поля `enabled` трактуются как `true`
