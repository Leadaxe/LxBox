# §270 — TLS Fragment ломает naive-outbound

## Симптом

Пользователь включил **TLS Fragment** (§028) и выбрал naive-ноду → VPN не
стартует, ядро бросает fatal:

```
fragment is not supported on naive outbound
```

## Причина

Post-step `applyTlsFragment` (`post_steps/tls_transforms.dart`) проставляет
`tls.fragment = true` (и `record_fragment`) **всем** first-hop outbound'ам с
`tls.enabled == true`. Но sing-box naive-outbound
(`protocol/naive/outbound.go:75`) отвергает `fragment`/`record_fragment` fatal —
naive принимает в TLS-блоке только `enabled` + `server_name` (+ cert/ECH).
Полный список запрещённого у naive: `disable_sni`, `insecure`, `alpn`,
`min/max_version`, `cipher_suites`, `curve_preferences`, `client_cert/key`,
`fragment`, `record_fragment`, `kernel_tx/rx`, `utls`, `reality`.

Naive-эмиттер сам кладёт чистый `{enabled, server_name}` — ломает именно
глобальный post-step, накладываемый поверх.

## Фикс

В `applyTlsFragment` пропускать naive-outbound (`ob['type'] == 'naive'`):
fragment для него физически невозможен на уровне ядра.

`applyMixedCaseSni` naive НЕ ломает — он меняет только `server_name` (валидное
поле). Не трогаем.

Прочие протоколы: `anytls` (§269) fragment **принимает** (стандартный
`tls.Config`) — не исключаем. Только naive особенный.

## Область

- `services/builder/post_steps/tls_transforms.dart` — гейт `type != 'naive'` в
  `applyTlsFragment`.

## Тесты

- `test/builder/` — конфиг с naive + tls_fragment=true → у naive-outbound НЕТ
  `fragment`/`record_fragment`, у обычного (vless/trojan) — есть.
