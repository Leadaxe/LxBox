# 016 — Statistics & Connections

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Пользователю нужен мониторинг: сколько трафика прошло, какие соединения активны, через какие outbound'ы.

## Statistics Screen (stats_screen.dart)

- **Summary card**: Upload total, Download total, Connections count.
- **Traffic by Outbound**: карточки по каждому outbound (vpn-1, auto-proxy-out, direct-out, конкретные ноды).
- **Expandable cards**: тап раскрывает список соединений внутри outbound.
- **Детали соединения**: host:port, протокол (TCP/UDP), rule + payload, трафик (↑/↓), длительность, chain.
- **Auto-refresh**: каждые 3 секунды через Clash API `/connections`.

### Агрегация по outbound

Ключ группировки — `chains.first` (innermost, самый глубокий outbound в цепочке, который sing-box отчитывает). Для коннекшена `[Литва-bypass, auto-proxy-out, vpn-1]` → группа "Литва-bypass".

### Detour chain в шапке карточки

Если у outbound-узла карточки есть `detour` в конфиге (dialer-посредник), под его именем отображается цепочка ступеньками:

```
🇱🇹 Литва-bypass                   ↑ 102.0 KB
   ↳ via ⚙ socks 45.142.73.159     ↓ 299.7 KB
   4 connections                         ⌄
```

Цепочка строится рекурсивно из `configRaw` (передаётся в `StatsScreen.configRaw`): `_detourChain(tag)` идёт по `outbound.detour` → `detour.detour` → ... с защитой от циклов (`seen` set).

**Почему не отдельная карточка:** sing-box Clash API не включает dialer-detour в `chains` (он не outbound-hop в понятиях clash, а sockopt.dialerProxy). Отдельной карточки с агрегированным трафиком через ⚙ быть не может — трафик атрибутирован к innermost node. Поэтому detour только приписывается к карточке родительского узла.

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
