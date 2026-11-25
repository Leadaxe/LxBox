# 760 — предупреждение о туннеле на позиции ≥1 цепочки

| | |
|---|---|
| **Статус** | Done — редактор цепочки, не проверено на устройстве |
| **Дата** | 2026-11-25 |
| **Повод** | Issue #233: группа WG-узлов внутри цепочки — urltest зелёный, трафик не идёт |
| **Связанные** | §393 / SPEC 110 (форма цепочки, `chain_form_validation.dart`), ядро `protocol/chain/clone.go` |

## Docs to update

- `docs/USER_GUIDE.md` / `.ru.md` — «A chain needs a recent core and compatible hops».
- `docs/api/debug-api-reference.md` — коды находок формы.
- `CHANGELOG.md` — `[Unreleased]`.

## Problem

Цепочка на позиции ≥1 ходит не через сам узел, а через его копию: ядро
(`hop.go` `ResolveLeaf` → `cloneFor`) создаёт рантайм-экземпляр узла с detour
на позицию i−1. Позиция 0 не копируется — уходит в сеть как есть.

У WireGuard (и AmneziaWG — в конфиге тоже `type: wireguard`) состояние живёт
на сервере: одна сессия и один адрес клиента на пару «ключ клиента × ключ
сервера». Копия и оригинал с одним ключом перебивают друг другу хендшейки.
Оригинал держит живым urltest группы (он проверяет оригинал, а не копию),
поэтому копия проигрывает: в логе `chain[…]#1/<узел>: handshake did not
complete`, каждое соединение — `context deadline exceeded`. Группа при этом
зелёная, ручная диагностика отдаёт 200 — обе ходят через оригинал.

Дамп #233: `c-proton = [o-direct, o-proton]`, `o-proton` — Направление →
selector → urltest на 198 WG-узлов, interval 10s, round_robin pool=1.

## Solution

Решение владельца (25.11): пока только предупреждение в интерфейсе — не
рекомендовать туннели на позициях цепочки после первой. Ни запретов, ни
изменений сборки и ядра.

**Что считается туннелем** (сверено по ядру sing-box-lx): протокол, который
поднимает свой сетевой стек и держит одну сессию на ключ/учётку, а не
открывает соединение на запрос.

| Тип | Где в конфиге | Признак в ядре |
|---|---|---|
| `wireguard` (и AmneziaWG) | `endpoints` | `protocol/wireguard`, netstack |
| `tailscale` | `endpoints` | `protocol/tailscale`, netstack |
| `openvpn-client` | `endpoints` | `protocol/openvpn/endpoint.go`, tun-flow |
| `openconnect` | `endpoints` | `protocol/openconnect/endpoint.go`, tun-flow |
| `masque` | `outbounds` | `protocol/masque`: CONNECT-IP, `tun.WithGVisor` |

Первые четыре — `kind: endpoint` реестра контракта. MASQUE в реестре
`kind: outbound`, поэтому добавлен по типу. Hysteria2, TUIC, SSH, TrustTunnel
мультиплексируют соединения, но это прокси — не туннели, не помечаются.

1. `ChainHopCandidate.tunnelInside` — позиция сама туннель (узел секции
   `endpoints` или `type: masque`) или группа/Направление, где такой узел есть
   среди членов (рекурсивно по `outbounds`). Считает `collectChainHopTargets`
   по собранному конфигу; для Направления — по его тегу в конфиге.
2. `ChainIssueCode.tunnelOnLink`, уровень `warning` (сохранение не
   запрещено): одна находка на все такие позиции с индексом ≥1, теги
   перечислены. Позиция 0 не предупреждается — ядро её не копирует
   (`hop.go` `ResolveLeaf`: index 0 → сам узел).
3. Показ — баннеры формы (`_issueBanners`). Debug API (`handlers/chains.dart`)
   получает находку тем же сбором кандидатов и тем же валидатором.
4. Пикер «Add position»: при непустой цепочке (новая позиция будет ≥1)
   у туннелей значок ⚠ с подсказкой «Tunnel: not recommended after the first
   position».

Условие срабатывания — только «туннель на позиции ≥1». Используется ли тот же
узел где-то ещё, не проверяется: предупреждение безусловное.

## Risks and edge cases

- Предупреждение видно только в редакторе цепочки. На списке цепочек
  (`chains_section.dart`) валидатор не вызывается — уже сохранённая цепочка
  предупреждения не покажет, пока её не откроют.
- Узлы WARP с одним ключом на десятки узлов конфликтуют между собой и без
  цепочек (urltest проверяет их пачкой) — отдельная история, здесь не решается.
- Конфликт сессий проверен на WireGuard (дамп #233). Для остальных туннелей
  вывод сделан по устройству протокола, на стенде не воспроизводился.

## Verification

Тесты: `chain_form_validation_test.dart` (туннель на позиции 0 — тишина, на
≥1 — warning, сохранение разрешено), `chain_hop_targets_test.dart` (Направление
→ selector → urltest → wireguard из `endpoints` даёт `tunnelInside`, openvpn и
masque — тоже, группа без туннелей — нет). На конфиге из дампа #233 цепочка
`c-proton` получает находку.
