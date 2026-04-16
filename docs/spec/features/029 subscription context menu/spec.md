# 029 — Subscription Context Menu

**Status:** Реализовано

## Контекст

Для быстрых действий с подпиской (копирование URL, обновление, удаление) без перехода в detail screen нужно контекстное меню по long-press.

## Реализация

### Bottom Sheet по long-press

Long-press на элементе списка подписок открывает `showModalBottomSheet` с тремя действиями:

```
┌────────────────────────────────┐
│  Provider A                    │
│  ──────────────────────────    │
│  📋 Copy URL                   │
│  🔄 Update                     │
│  🗑 Delete                      │
└────────────────────────────────┘
```

### Действия

**Copy URL** — копирует URL подписки в буфер обмена, показывает SnackBar "URL copied".

**Update** — запускает обновление конкретной подписки через `SubscriptionController.updateSource(source)`. Bottom sheet закрывается, в списке отображается индикатор загрузки.

**Delete** — показывает `AlertDialog` с подтверждением:

```dart
showDialog(
  context: context,
  builder: (_) => AlertDialog(
    title: Text('Delete subscription?'),
    content: Text('${source.name} will be removed'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
      TextButton(
        onPressed: () {
          Navigator.pop(context); // dialog
          Navigator.pop(context); // bottom sheet
          _deleteSource(source);
        },
        child: Text('Delete', style: TextStyle(color: Colors.red)),
      ),
    ],
  ),
);
```

При удалении выставляется флаг `_dirty = true` для регенерации конфига при выходе с экрана (см. 027 autosave).

### GestureDetector

```dart
GestureDetector(
  onLongPress: () => _showContextMenu(source),
  child: ListTile(...),
)
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/subscriptions_screen.dart` | Long-press handler, bottom sheet, диалог подтверждения удаления |

## Критерии приёмки

- [x] Long-press на подписке открывает bottom sheet
- [x] Copy URL копирует URL в буфер обмена
- [x] Update запускает обновление подписки
- [x] Delete показывает диалог подтверждения
- [x] После удаления выставляется `_dirty` для регенерации конфига
- [x] Bottom sheet закрывается после выбора действия
