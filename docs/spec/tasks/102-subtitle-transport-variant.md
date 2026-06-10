# 102 — Transport-variant в subtitle node-row

**Дата:** 2026-06-10 · **Статус:** DONE
**Запрос:** видеть в подзаголовке ноды не только протокол, но и транспорт
(`xhttp`), если он есть.

## Решение (финальная таксономия)

Лейбл = `протокол · транспорт · security`, пустые слоты опускаются.

- `ConfigNode.transportLabel`: `transport.type` из конфига
  (`ws`/`grpc`/`xhttp`/`httpupgrade`/`quic`; sing-box `http` ≙ H2 → `h2`);
  без transport-блока → `tcp` для v2ray-протоколов (vless/vmess/trojan);
  `null` для протоколов со встроенным транспортом (wg/hy2/tuic/…).
- `ConfigNode.securityLabel`: для wireguard — уровень обфускации
  (транспорта и TLS у WG нет):

  | уровень | как определить |
  |---|---|
  | plain WG (`null`) | нет ни одного AWG-поля |
  | `awg` (1.x) | есть jc/jmin/jmax, s1/s2, h1–h4 |
  | `awg2` | дополнительно s3/s4 (transport padding) и/или CPS i1–i5 |

  Иначе по `tls`: `Reality` > `TLS` > `null`; при `flow=xtls-rprx-vision` —
  суффикс `+Vision` (`Reality+Vision`/`TLS+Vision`). NB: Vision живёт только
  на голом TCP — с v2ray-транспортами (ws/grpc/xhttp/…) несовместим по
  протоколу, так что `xhttp·…+Vision` в валидном конфиге не встретится.
- `node_list.dart` itemBuilder: все три слота берутся с **одного** узла
  (сам tag или urltest-выбор, §048 fallback); лейбл — join('·').

Примеры: `VLESS·tcp·Reality`, `VLESS·xhttp·TLS`, `VLESS·ws`, `TROJAN·tcp·TLS`,
`Hy2·TLS`, `WG·awg2`, `WG`.

Layout NodeRow не менялся: protocol-label нефиксированной внутренней ширины,
стрелка `→ node` уступает место (Flexible + ellipsis).

## Тесты

`test/models/config_node_test.dart` — группа «§102 — variant»: transport.type,
отсутствие transport, AWG-детект, чистый WG.
