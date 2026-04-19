# Parser v2 fixtures

Тестовые входы для Parser v2 (спека [`026`](../../../docs/spec/features/026%20parser%20v2/spec.md)).

## Структура

```
test/fixtures/
├── vless/          # vless:// URIs
├── vmess/          # vmess:// URIs (base64 + legacy cleartext)
├── trojan/
├── shadowsocks/    # ss:// SIP002 + legacy base64
├── hysteria2/      # hysteria2:// и hy2://
├── tuic/           # tuic:// v5 (нет в v1, добавлен в v2)
├── ssh/
├── socks/          # socks:// и socks5://
├── wireguard/      # wg:// / wireguard:// URIs + .conf INI
├── json/           # Xray JSON array + одиночный sing-box outbound/endpoint
├── base64/         # обёртка над URI-списком
└── subscriptions/  # "сырые" тела подписок (анонимизированные)
```

## Конвенции

- Один кейс = одно имя: `case_name.uri` (+ `case_name.expected.json` после Фазы 2).
- Данные **синтетические, детерминированные**: host'ы `example-N.com`, UUID `1111...`, password `testpass123`, key-base64 — валидный по длине, но не настоящий.
- Комментарии в начале файла — через `#` (парсер их игнорирует).
- Edge-case'ы помечены суффиксом: `_edge_missing_flow.uri`, `_edge_fallback_xhttp.uri`.

## Использование в тестах

- **Юнит-тесты парсеров** (`test/parser/<protocol>_test.dart`): берут `*.uri`, парсят, сравнивают с `*.expected.json` (golden).
- **Round-trip**: `parseUri(spec.toUri()) ≈ spec` на всём корпусе.
- **Parity v1↔v2** (`test/parity/`): реальные подписки в `subscriptions/*.txt`, ожидание — `jsonDiff(v1, v2) == {}`.

Спек требует ≥5 кейсов на протокол. Текущий корпус — стартовый, растёт при каждом новом баге.
