# План: 004 — Парсер подписок

## Этапы

### 1. Модели данных

Создать `lib/models/parsed_node.dart` и `lib/models/proxy_source.dart` с портом структур из Go:
- `ParsedNode` (tag, scheme, server, port, uuid, flow, label, comment, query, outbound)
- `ProxySource` (source, connections, skip, outbounds, tag_prefix/postfix/mask, exclude_from_global)
- `OutboundConfig` (tag, type, options, filters, addOutbounds, comment, wizard)
- Константы: `maxNodesPerSubscription = 3000`, `maxURILength = 8192`, `subscriptionUserAgent`

### 2. Subscription Decoder

Создать `lib/services/subscription_decoder.dart`:
- `decodeSubscriptionContent(Uint8List content)` — порт `decoder.go`
- `tryDecodeBase64(String s)` — 4 варианта base64
- Определение типа: base64 → Xray JSON → plain text → ошибка

### 3. Subscription Fetcher

Создать `lib/services/subscription_fetcher.dart`:
- `fetchSubscription(String url)` — HTTP GET, UA, 30s timeout, 10MB limit
- Вызов `decodeSubscriptionContent` на результат

### 4. Node Parser

Создать `lib/services/node_parser.dart` — основной парсер:
- `parseNode(String uri, List<Map<String, String>> skipFilters)` — порт `ParseNode`
- Вспомогательные: `buildOutbound`, `isDirectLink`, `isSubscriptionURL`
- Парсинг по протоколам: VLESS, VMess, Trojan, SS, Hysteria2, SSH, SOCKS, WireGuard
- TLS/transport helpers

### 5. Source Loader

Создать `lib/services/source_loader.dart`:
- `loadNodesFromSource(ProxySource source, Map<String, int> tagCounts, ...)` — порт `LoadNodesFromSource`
- Tag prefix/postfix/mask с переменными
- MakeTagUnique

### 6. Тесты

- Unit-тесты для decoder (base64, plain text, JSON array)
- Unit-тесты для node_parser (каждый протокол)
- Интеграционный тест source_loader

## Зависимости

- Пакет `http` (уже есть)
- Пакет `json5` (уже есть — для обратной совместимости с JSONC-конфигами)
- Dart стандартная библиотека: `dart:convert` (base64, json, utf8)
