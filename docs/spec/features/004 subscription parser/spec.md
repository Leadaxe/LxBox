# 004 — Парсер подписок

| Поле | Значение |
|------|----------|
| Статус | черновик |
| Задачи | [`tasks.md`](tasks.md) |
| План | [`plan.md`](plan.md) |
| Референс | singbox-launcher `core/config/subscription/` |

## 1. Цель

Порт логики парсинга подписок из десктопного лаунчера (Go) в Dart для мобильного приложения. Результат — набор сервисов, позволяющих:

- скачать подписку по URL;
- декодировать содержимое (base64, plain text, Xray JSON array);
- распарсить каждый узел в структуру `ParsedNode`;
- сгенерировать outbound JSON для sing-box.

## 2. Поддерживаемые форматы

### 2.1 Подписки (контейнеры)

| Формат | Описание |
|--------|----------|
| **Base64** | URL-safe и standard, с padding и без (4 варианта) |
| **Plain text** | Строки с `://` разделённые переносами |
| **Xray JSON array** | Массив JSON-объектов (`[{...}, {...}]`) |

### 2.2 Протоколы узлов (URI)

| Протокол | Схема URI |
|----------|-----------|
| VLESS | `vless://` |
| VMess | `vmess://` (base64-encoded JSON) |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` (SIP002 и legacy) |
| Hysteria2 | `hysteria2://`, `hy2://` |
| SSH | `ssh://` |
| SOCKS5 | `socks5://`, `socks://` |
| WireGuard | `wireguard://` |

### 2.3 Поддержка транспортов

Для VLESS/VMess/Trojan: WebSocket, gRPC, HTTP, HTTP Upgrade, H2.

## 3. Архитектура модулей

```
lib/
  models/
    parsed_node.dart       — ParsedNode, ParsedJump
    proxy_source.dart      — ProxySource, OutboundConfig
  services/
    subscription_fetcher.dart   — HTTP GET, UA, лимиты
    subscription_decoder.dart   — base64/plain/Xray detection
    node_parser.dart            — ParseNode по схемам
    source_loader.dart          — LoadNodesFromSource
```

### 3.1 Fetcher

- HTTP GET с `User-Agent: SubscriptionParserClient`
- Таймаут: 30 секунд
- Лимит ответа: 10 MB
- Возвращает декодированные байты

### 3.2 Decoder

Порядок декодирования:
1. Попытка base64 (4 варианта encoding)
2. Если `[` — проверка JSON array (Xray)
3. Если содержит `://` — plain text
4. Иначе — ошибка

### 3.3 Node Parser

- Валидация длины URI (макс. 8192)
- Определение схемы по префиксу
- Парсинг URI, извлечение: server, port, UUID/password, query, fragment
- Генерация outbound JSON (`buildOutbound`)
- Поддержка TLS/REALITY (SNI, ALPN, uTLS fingerprint)
- Фильтрация по skip-правилам
- Sanitize и нормализация тегов (UTF-8, флаги, дубликаты)

### 3.4 Source Loader

- Обработка `ProxySource.source` (URL или direct link)
- Обработка `ProxySource.connections[]`
- Применение `tag_prefix`, `tag_postfix`, `tag_mask` с переменными
- Лимит `MaxNodesPerSubscription = 3000`
- Уникализация тегов (`MakeTagUnique`)

## 4. Модель данных

```dart
class ParsedNode {
  String tag;
  String scheme;    // vless, vmess, trojan, ss, hysteria2, ssh, socks, wireguard
  String server;
  int port;
  String uuid;      // UUID или password (зависит от протокола)
  String flow;
  String label;
  String comment;
  Map<String, String> query;
  Map<String, dynamic> outbound;  // Готовый JSON для sing-box
}
```

## 5. Допущения

- Сетевые запросы выполняются из Dart (пакет `http`); нет необходимости в нативном коде.
- Формат outbound JSON идентичен лаунчеру — совместимость с тем же sing-box ядром.
- Валидация Shadowsocks методов: только поддерживаемые sing-box (2022-blake3-*, AEAD, none).

## 6. Нецели

- Автообновление подписок по таймеру (отдельная фича при необходимости).
- Xray `dialerProxy` → sing-box `detour` chain (ParsedJump) — упрощённо в первой версии.

## 7. Критерии приёмки

- [ ] Fetch подписки по URL возвращает декодированный контент.
- [ ] Base64-encoded подписка корректно декодируется (все 4 варианта).
- [ ] Plain text подписка парсится построчно.
- [ ] Xray JSON array корректно распознаётся и парсится.
- [ ] Каждый поддерживаемый протокол (§2.2) парсится в `ParsedNode` с корректным outbound JSON.
- [ ] Skip-фильтры применяются корректно.
- [ ] Теги уникализируются при дубликатах.
- [ ] Unit-тесты покрывают основные сценарии парсинга.
