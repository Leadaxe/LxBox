# 016 — Statistics & Connections

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Пользователю нужен мониторинг: сколько трафика прошло, какие соединения активны, через какие outbound'ы.

## Statistics Screen (stats_screen.dart)

- **Summary card**: Upload total, Download total, Connections count.
- **Traffic by Outbound**: карточки по каждому outbound (proxy-out, auto-proxy-out, direct-out и т.д.).
- **Expandable cards**: тап раскрывает список соединений внутри outbound.
- **Детали соединения**: host:port, протокол (TCP/UDP), rule + payload, трафик (↑/↓), длительность, chain.
- **Auto-refresh**: каждые 3 секунды через Clash API `/connections`.

## Connections Screen (connections_screen.dart)

- Полный список всех активных соединений, сортировка по времени (newest first).
- Каждое соединение: destination, chain, network/type, duration, upload/download.
- **Close connection** — кнопка × на каждом соединении (DELETE `/connections/{id}`).
- **Close all** — кнопка в AppBar (DELETE `/connections`).
- Auto-refresh каждые 2 секунды.

## Навигация

- **Traffic bar** на главном экране → тап → Statistics.
- **Connections chip** на Statistics → тап → Connections Screen.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/stats_screen.dart` | Statistics с expandable outbound cards |
| `lib/screens/connections_screen.dart` | Live connections с закрытием |
| `lib/screens/home_screen.dart` | Traffic bar → Stats navigation |
| `lib/services/clash_api_client.dart` | fetchConnections, closeConnection, closeAllConnections |

## Критерии приёмки

- [x] Summary: upload/download total, connection count
- [x] Traffic сгруппирован по outbound
- [x] Карточки раскрываются с деталями соединений
- [x] Connections screen: живой список, закрытие отдельных и всех
- [x] Навигация с главного экрана и из Statistics
