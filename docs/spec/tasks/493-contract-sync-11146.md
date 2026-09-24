# §493 — синк зеркала контракта 1.1.42 → 1.1.46

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | лаунчер `7e2945bf` (контракт 1.1.46, TASKS_LXBOX §39–§42) |
| **Связанные** | фича 480, §492 (merge append / unwrap), §488 (dialerProxy freedom fragment) |

## Проблема

Зеркало реестра отставало на четыре минорных версии контракта (1.1.43–1.1.46).
Лаунчер привёз корпусные кейсы и записи реестра, которые у нас уже закрыты
кодом (§492, §488), но оверлеи `contract_draft` дублировали совпавшие с
реестром ключи класса A, а часть xray-оверлеев ждала синка (`_awaitingContractSync`).

## Решение

1. Синк зеркала скриптом: `LX_CONTRACT_SRC=/tmp/x_1146/contract` из архива
   лаунчера `7e2945bf` (VERSION 1.1.46 + TASKS_LXBOX §42).
2. Сняты 25 оверлеев класса A по описи `/tmp/lx_review/overlays.md` (emit-поля
   http/naive/anytls/trojan/vless/vmess/wireguard, tls `fp_dialect`/`sni`/`sid`,
   xray `include` trojan/vless, vmess `defaults`).
3. Удалён `xray/vmess.json` — единственный ключ совпал с реестром.
4. Сняты `_awaitingContractSync` у xray/trojan, xray/vless, xray/socks.
5. Документация: фича 480 §15, CHANGELOG Unreleased, draft релиза v2.25.0.

Минимальные правки под корпус: `emitTuic` не материализует пустой `password`;
конвейер прокидывает `type_invalid` в `dropped[]` при отбраковке санитайзером;
`section_loader` — fallback реестра для `$ref` блоков (fp_dialect после снятия
оверлея tls); `interpreter` — `on_empty` для `""`, пустой `userinfoPass`.

## Критерии приёмки

- [x] `app/assets/contract/VERSION` = 1.1.46, `contract.lock` с `source_sha=7e2945bf`.
- [x] `dart run tool/check_contract_lock.dart` зелёный.
- [x] Корпус 1.1.43–1.1.46: hysteria2 mport+authority, двойной base64, CIDR wg,
  fractional_port, dialer_proxy_freedom_fragment — зелёные.
- [x] Оверлеи класса A сняты; B/C (ss padding, xhttp emit_as, ws.eh, vmess json_map,
  vless/trojan emit, xray forms) — на месте.
- [x] `mapper_sections_*_test.dart` зелёные.
- [x] `flutter analyze` без новых issues; identity/emit/golden зелёные без
  переписывания фикстур. `test/contract/` + `test/parser/`: ровно шесть
  заявленных красных корпуса (`naive/empty_host_rejected` и пять `xray/*`;
  поимённо и со сверкой 24.09.2026 — фича 480, §12 «Осталось красным»).
