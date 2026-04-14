# Задачи: 004 — Парсер подписок

Спека: [`spec.md`](spec.md) | План: [`plan.md`](plan.md)

## Чеклист

- [ ] Модели: `ParsedNode`, `ProxySource`, `OutboundConfig`, константы
- [ ] `subscription_decoder.dart`: base64 (4 варианта), Xray JSON array, plain text
- [ ] `subscription_fetcher.dart`: HTTP GET, UA, таймаут, лимит
- [ ] `node_parser.dart`: VLESS, VMess, Trojan, SS, Hysteria2, SSH, SOCKS, WireGuard
- [ ] `node_parser.dart`: TLS, REALITY, transport (ws/grpc/http/httpupgrade)
- [ ] `node_parser.dart`: `buildOutbound` — генерация sing-box JSON
- [ ] `source_loader.dart`: `loadNodesFromSource`, tag processing, skip filters
- [ ] Unit-тесты

## Статус

| Пункт | Статус |
|-------|--------|
| Модели | — |
| Decoder | — |
| Fetcher | — |
| Node Parser | — |
| Source Loader | — |
| Тесты | — |
