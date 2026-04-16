# 038 — Subscription Detail Enhancements

**Status:** Реализовано

## Контекст

Экран деталей подписки нуждался в доработках: отсутствовала иконка Telegram, ссылки копировались вместо открытия, при открытии экрана автоматически загружались данные (медленно при плохой сети), не было возможности переименовать подписку.

## Реализация

### Иконка Telegram

Иконка `Icons.telegram` с цветом `#2AABEE` отображается в двух местах:

1. **Список подписок** — рядом с названием подписки, если у подписки есть Telegram-ссылка
2. **Detail screen** — как `ActionChip` в секции ссылок

```dart
ActionChip(
  avatar: Icon(Icons.telegram, color: Color(0xFF2AABEE)),
  label: Text('Telegram'),
  onPressed: () => UrlLauncher.open(source.telegramUrl!),
)
```

### Открытие ссылок через UrlLauncher

Ссылки support page и web page открываются через `UrlLauncher.open()` (см. 030) вместо копирования в буфер обмена. Используется Intent.ACTION_VIEW на Android.

### Без автозагрузки при открытии

При открытии detail screen:
- Узлы загружаются **из кеша** (см. 028), если кеш доступен
- Если кеша нет — показывается пустой список с предложением обновить
- Автоматический HTTP запрос **не выполняется**
- Кнопка refresh в AppBar для ручного обновления

```dart
@override
void initState() {
  super.initState();
  _loadFromCache(); // Не HTTP запрос
}
```

### Редактирование названия

Иконка `Icons.edit` в AppBar. По нажатию открывается диалог с TextField для переименования:

```dart
IconButton(
  icon: Icon(Icons.edit),
  onPressed: () => _showRenameDialog(),
)
```

Новое название сохраняется в модель `ProxySource`.

### Список узлов

Узлы отображаются после загрузки из кеша или после ручного refresh. Каждый узел — ListTile с названием и типом протокола.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/subscription_detail_screen.dart` | Telegram ActionChip, UrlLauncher для ссылок, загрузка из кеша, edit иконка, rename диалог |
| `lib/screens/subscriptions_screen.dart` | Telegram иконка рядом с названием в списке |

## Критерии приёмки

- [x] Иконка Telegram (Icons.telegram, цвет #2AABEE) в списке и detail screen
- [x] Ссылки support/web page открываются через UrlLauncher
- [x] При открытии detail screen нет автозагрузки — данные из кеша
- [x] Кнопка refresh для ручного обновления
- [x] Иконка edit в AppBar для переименования подписки
- [x] Список узлов появляется после refresh или из кеша
