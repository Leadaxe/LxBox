# 586 — Типы endpoint из реестра; `openvpn-client` — известный тип без описания полей

| Поле | Значение |
|------|----------|
| Статус | Implemented |
| Дата старта | 2026-09-28 |
| Дата завершения | 2026-09-28 |
| Коммиты | b14d57cf (синк контракта 1.1.99), см. «Реализация» |
| Контракт | 1.1.99 (лаунчер 6d53d58a, SPEC 149 лаунчера) |
| Связанные spec'ы | tasks/585 (незнакомый тип), tasks/576, tasks/577 |

## Проблема

Задача 585 завела в коде перечень `kCoreEndpointTypes` (`wireguard`,
`tailscale`, `openvpn-client`, `openconnect`): по нему узел незнакомого типа
пишется в `endpoints[]`, а не в `outbounds[]`. Знание «этот тип ядро считает
endpoint» в итоге жило в двух местах двух систем: в коде LxBox и в реестре
контракта (поле `kind` записи протокола, которым лаунчер пользуется с SPEC 142
A9). Перечни расходятся без предупреждения: новый endpoint-тип ядра до правки
кода уходит в `outbounds[]`, и ядро отвергает конфиг.

`openvpn-client` при этом оставался «незнакомым»: из подписки отбрасывался,
у своей записи висело предупреждение «Unknown node type».

## Решение владельца (28.09.2026)

«Делай в реестр, попроще, без правил, без проверок».

1. Знание «тип — endpoint» — только в реестре контракта; перечни в коде обеих
   систем убираются.
2. `openvpn-client` вносится в реестр как известный тип: раздел
   `endpoints[]`, тег сборки ядра `with_openvpn`. Правил для полей и проверок
   значений нет: тело уходит в ядро как написано.
3. Полного импорта OpenVPN нет: ни формы в мастере, ни разбора `.ovpn`, ни
   ссылок, ни модели полей.
4. Тип, которого нет в реестре, при вставке своего узла принимается с
   предупреждением «Unknown node type» (задача 585) и пишется в `outbounds[]`.
5. Новых правил реестра для полей и признаков `core_rejects` нет.

## Диагностика

Ядро sing-box-lx 1.14.2-lx.6 регистрирует endpoint (`endpoint.Register`,
`protocol/*/endpoint.go`, `include/*_stub.go`) для `wireguard`, `tailscale`,
`openvpn-client`, `openvpn-server`, `openconnect`. Записи реестра после
контракта 1.1.99 есть у `wireguard`, `tailscale`, `openvpn-client`;
`openvpn-server` (серверная роль) и `openconnect` в реестр не вносились —
решение касалось только `openvpn-client`. Такие узлы по пункту 4 идут в
`outbounds[]`.

Контракт 1.1.99: запись `protocols/openvpn-client.json` — `kind: endpoint`,
источник `singbox`, `body.fields_unchecked: true` (`order`/`fields` пустые),
`build_tag: with_openvpn`, `min_core: 1.14.0-lx.10`,
`on_core_unsupported: drop_node` с кодом `openvpn_core_unsupported`. У маппера
нет `unknown_key`.

## Решение

Условия, при которых узел — «известный тип без своей модели»
(`UnknownTypeSpec` без предупреждения):

1. вход — sing-box JSON (голое тело, документ с `outbounds`/`endpoints`,
   массив тел), источник любой: своя запись, член папки, редактор узла,
   подписка;
2. `type` — строка, не пустая, не служебный тип и не группа;
3. у типа нет своей модели в приложении (`kAppSingboxNodeTypes`);
4. у записи реестра с этим `singbox_type` тело помечено `fields_unchecked`
   (`ContractRegistry.isUncheckedType`).

Для такого узла:

- модель та же, что у задачи 585 (`UnknownTypeSpec`, тело целиком); список
  предупреждений пуст;
- санитайзер (`RegistrySanitizer.sanitize`) отдаёт тело без изменений и без
  кодов: `unknown_key` на нём не выдаётся; проходы реестра по узлу пропускают
  `UnknownTypeSpec`, как и в 585;
- раздел конфига — по `kind` записи реестра
  (`ContractRegistry.isEndpointType`): `endpoints[]`;
- узловой гейт ядра — общий (`nodeCoreRefusal`): ядро без `with_openvpn`
  снимает узел кодом `openvpn_core_unsupported`. Пин AAR `with_openvpn` несёт
  (`kCoreBuildTags`).

Тип вне реестра — как в задаче 585: только своя запись, предупреждение,
`outbounds[]` (у типа нет `kind`).

## Риски и edge cases

- Узел `openvpn-server` или `openconnect` в своей записи уйдёт в
  `outbounds[]`, и ядро отвергнет конфиг на Save (`CheckConfig`). Лечится
  записью в реестре контракта, а не кодом.
- Поля `openvpn-client` не проверяются вовсе: ошибку в теле найдёт только
  ядро (`CheckConfig` на Save, старт).
- `fieldAllowedOn` для такой схемы отвечает «нет» на любой путь: сборочные
  трансформы полей телу не дописывают — тело как написано.

## Верификация

- `test/subscription/endpoint_types_from_registry_test.dart`: `kind` реестра
  задаёт раздел (`openvpn-client`, `wireguard`, `tailscale` — endpoint;
  `vless` и тип вне реестра — нет); своя запись — узел без предупреждений,
  `Endpoint`, тело как написано; документ со смесью типов — оба узла; подписка
  — узел создаётся, `dropped[]` пуст; санитайзер сборки тело не трогает;
  гейт ядра без `with_openvpn` снимает узел кодом, с тегом — нет; тип вне
  реестра — предупреждение и `Outbound`.
- `test/subscription/unknown_node_type_test.dart` (незнакомый тип теперь
  `future-proto`), `test/contract/body_contract_test.dart` (в т. ч. кейс
  корпуса `singbox/openvpn_client_endpoint`), `test/models/node_spec_test.dart`,
  `test/contract/node_core_gate_test.dart`,
  `test/contract/registry_invariant_test.dart` — зелёные.

## Реализация

- `services/contract/registry.dart` — `BodySchema.fieldsUnchecked`,
  `ContractRegistry.isEndpointType`, `isUncheckedType`.
- `services/contract/body_sanitizer.dart` — `sanitize` отдаёт тело схемы с
  `fields_unchecked` как есть.
- `models/node_spec.dart` — `kCoreEndpointTypes` удалён, `emitRaw` берёт
  раздел из реестра.
- `services/parser/singbox_config.dart` — `_ownUnknownTypeNode`: тип реестра
  без описания полей принимается из любого источника без предупреждения.

## Нерешённое / follow-up

- `openvpn-server` и `openconnect` в реестре нет — по решению владельца.
