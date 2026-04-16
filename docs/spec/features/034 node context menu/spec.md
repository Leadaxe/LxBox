# 034 — Node Context Menu

**Status:** Реализовано

## Контекст

Для быстрого взаимодействия с узлом на главном экране нужно контекстное меню. Ранее был пункт "Copy name", но он оказался не нужен — заменён на более полезные действия.

## Реализация

### Long-press на узле

Long-press на `NodeRow` в списке узлов на главном экране показывает popup menu:

```dart
showMenu(
  context: context,
  position: RelativeRect.fromLTRB(dx, dy, dx, dy),
  items: [
    PopupMenuItem(value: 'ping', child: Text('Ping')),
    PopupMenuItem(value: 'use', child: Text('Use this node')),
    PopupMenuItem(value: 'copyJson', child: Text('Copy outbound JSON')),
  ],
);
```

### Действия

**Ping** — запускает пинг конкретного узла. Результат отображается в строке узла.

**Use this node** — переключает текущий outbound на выбранный узел через Clash API. Аналог тапа по узлу, но доступен из меню.

**Copy outbound JSON** — сериализует proxy entry узла из Clash API в JSON и копирует в буфер обмена. Callback `onCopyJson`:

```dart
void _onCopyJson(ProxyEntry entry) {
  final json = jsonEncode(entry.toOutboundJson());
  Clipboard.setData(ClipboardData(text: json));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Outbound JSON copied')),
  );
}
```

### NodeRow callback

`NodeRow` виджет принимает callback `onLongPress` или `onCopyJson`, который передаётся из `HomeScreen`.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/widgets/node_row.dart` | Long-press handler, popup menu |
| `lib/screens/home_screen.dart` | Передача callbacks в NodeRow, реализация onCopyJson |

## Критерии приёмки

- [x] Long-press на узле показывает popup menu
- [x] Пункт Ping запускает пинг узла
- [x] Пункт Use this node переключает outbound
- [x] Пункт Copy outbound JSON копирует JSON в буфер
- [x] Пункт Copy name удалён
