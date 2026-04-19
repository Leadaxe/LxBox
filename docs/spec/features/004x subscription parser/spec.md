# 004 — Парсер подписок

> # 🚫 SUPERSEDED
>
> **Полностью заменено спекой [`026 parser v2`](../026%20parser%20v2/spec.md)** (2026-04-18, v1.3.0).
> Все файлы, упомянутые здесь (`node_parser.dart`, `source_loader.dart`, `subscription_fetcher.dart`, `subscription_decoder.dart`, `xray_json_parser.dart`, модели `ParsedNode`, `ProxySource`), **удалены** в Фазе 4 спеки 026.
>
> **Текущая реализация:** `lib/services/parser/` + `lib/services/subscription/sources.dart`. Sealed `NodeSpec` вместо `ParsedNode`, sealed `ServerList` (`SubscriptionServers` / `UserServer`) вместо `ProxySource`.
>
> Документ оставлен **только как исторический контекст** — для понимания эволюции архитектуры. Не использовать как reference для актуального кода.

| Поле | Значение |
|------|----------|
| Статус | 🚫 Superseded — v1 удалён, см. 026 |
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

## 5. Xray JSON Array Parser + Chained Proxy (Jump)

### Проблема

Некоторые провайдеры возвращают JSON массив полных Xray/v2ray конфигов вместо base64-encoded URI. Каждый элемент — полный конфиг с `outbounds`, `dns`, `routing`, `remarks`. Proxy outbound использует Xray формат (`protocol`/`vnext`/`streamSettings`).

Дополнительно, эти конфиги часто используют **chained proxies** через `dialerProxy` в `streamSettings.sockopt`.

### Решение

Порт Xray JSON Array парсера из singbox-launcher (Go) в Dart:

1. **Detect** Xray JSON Array формат в `SubscriptionDecoder`
2. **Parse** каждый элемент массива: извлечь основной VLESS outbound + опциональный jump server
3. **Convert** Xray outbound fields в sing-box outbound формат
4. **Generate** jump outbounds с `detour` полем в `ConfigBuilder`

### Формат примера

```json
[
  {
    "remarks": "🇨🇦Канада|Gemini bypass",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": { "vnext": [{ "address": "...", "port": 443, "users": [...] }] },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": { "serverName": "...", "publicKey": "...", "shortId": "..." },
          "sockopt": { "dialerProxy": "ru-upstream" }
        }
      },
      {
        "protocol": "socks",
        "tag": "ru-upstream",
        "settings": { "servers": [{ "address": "...", "port": 62531, "users": [...] }] }
      }
    ]
  }
]
```

## 6. Допущения

- Сетевые запросы выполняются из Dart (пакет `http`); нет необходимости в нативном коде.
- Формат outbound JSON идентичен лаунчеру — совместимость с тем же sing-box ядром.
- Валидация Shadowsocks методов: только поддерживаемые sing-box (2022-blake3-*, AEAD, none).

## 7. Нецели

- Автообновление подписок по таймеру (отдельная фича при необходимости).

## 8. Файлы

| Файл | Изменения |
|------|-----------|
| `lib/models/parsed_node.dart` | ParsedNode, ParsedJump |
| `lib/services/xray_json_parser.dart` | Xray JSON Array → List<ParsedNode> |
| `lib/services/source_loader.dart` | Detect format, branch to xray parser |
| `lib/services/config_builder.dart` | Emit jump outbounds with `detour` |

## 9. Критерии приёмки

- [x] Fetch подписки по URL возвращает декодированный контент.
- [x] Base64-encoded подписка корректно декодируется (все 4 варианта).
- [x] Plain text подписка парсится построчно.
- [x] Xray JSON array корректно распознаётся и парсится.
- [x] Каждый поддерживаемый протокол (§2.2) парсится в `ParsedNode` с корректным outbound JSON.
- [x] Skip-фильтры применяются корректно.
- [x] Теги уникализируются при дубликатах.
- [x] SOCKS/VLESS jump серверы создают отдельный outbound с `detour`.
- [x] Non-Xray элементы в массиве пропускаются gracefully.
- [x] Существующие base64/URI подписки продолжают работать без изменений.
