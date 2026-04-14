# 014 — Subscription Detail View

## Контекст

На экране подписок тап по элементу ничего не делает. Пользователь не может посмотреть что внутри подписки — какие ноды, откуда они, без обновления всего списка. Редактирование (переименование, удаление) доступно только через long press → bottom sheet, что неочевидно.

## Что делаем

**Тап** → открывается detail screen с содержимым подписки.
**Long press и свайп** — убираем: всё управление переносим в detail screen.

### Detail Screen

Открывается через `Navigator.push` (полноэкранный роут, не bottom sheet).

**AppBar:**
- Заголовок: `entry.displayName`
- Кнопка `Edit` (карандаш) → inline переименование прямо в AppBar title (TextField)
- Кнопка `Delete` (корзина) → confirm dialog → удаление + pop

**Тело:**

Секция с мета-информацией:
```
URL / source          [текст, selectable, с кнопкой copy]
Последнее обновление  [время, например "2h ago"]
Нод                   [число]
```

Список нод — загружается при открытии экрана через `SourceLoader.loadNodesFromSource`:
- Каждый элемент: иконка протокола + имя ноды (tag)
- Если загрузка идёт — LinearProgressIndicator под AppBar
- Если ошибка — текст с описанием
- Если подписка ещё не обновлялась (nodeCount == 0) — placeholder "Update subscription to see nodes"

### Хранение нод

Сейчас `SubscriptionEntry` хранит только `nodeCount`, имена нод нигде не сохраняются. Стратегия: **загружать при открытии** (не хранить), так как:
- Подписки могут быть большими
- Данные меняются при каждом обновлении
- `SourceLoader.loadNodesFromSource` уже есть и используется в контроллере

При открытии detail screen делаем один вызов `SourceLoader.loadNodesFromSource(entry.source)` и показываем результат. Кэш не нужен — экран живёт пока открыт.

### Изменения в существующем UI

| Было | Станет |
|------|--------|
| `onLongPress → _showEditSheet` | убирается |
| `Dismissible` (свайп → удалить) | убирается |
| `onTap` — отсутствует | `onTap → Navigator.push(DetailScreen)` |

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/subscription_detail_screen.dart` | Новый экран |
| `lib/screens/subscriptions_screen.dart` | Убрать Dismissible и onLongPress, добавить onTap |

## Критерии приёмки

- [ ] Тап по подписке открывает detail screen.
- [ ] Detail screen показывает URL/source, дату обновления, количество нод.
- [ ] Список нод загружается при открытии (индикатор пока грузится).
- [ ] Rename работает прямо в detail screen, сохраняется в `SubscriptionController.renameAt`.
- [ ] Delete работает из detail screen с подтверждением, закрывает экран после удаления.
- [ ] Свайп и long press с основного списка убраны.
