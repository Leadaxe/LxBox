# §488 — Xray `dialerProxy` → freedom с fragment (контракт 1.1.45)

| | |
|---|---|
| Статус | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| Дата | 2026-09-19 |
| Контракт | 1.1.45, TASKS_LXBOX §41; кейс `body/xray/dialer_proxy_freedom_fragment` |
| Связанные | [§404](404-dialer-proxy-signature.md) (цепочка dialerProxy), [§480](../features/480%20registry-driven-mapper/spec.md) (движок Xray) |

## Что было

В Xray-подписках anti-DPI часто встречается схема: основной outbound
(VLESS/Trojan с TLS или REALITY) в `streamSettings.sockopt.dialerProxy`
ссылается на служебный freedom-outbound с `settings.fragment`
(`packets`, `length`, `interval`). Это приём Xray против DPI, а не
релей-сервер.

Разбор трактовал любую цель `dialerProxy` с протоколом `freedom` как
служебный хоп цепочки. Freedom хопом быть не может → владелец
отбраковывался целиком (`dialer_proxy_unusable`). На живой подписке с
15 серверами 9 узлов так и пропадали.

## Что сделано

Норма контракта 1.1.45 (лаунчер, коммит `9e376607`), уточнение владельца:
предупреждение ставится только при реальной потере поведения; механика
фрагментации ядра sing-box (`tls.fragment`) предпочтительнее слепого
переноса `length`/`interval` Xray. Код `xray_fragment_mapped` снят в
контракте 1.1.46 — **не** заводим.

1. Цель `dialerProxy` с `protocol: freedom` и `settings.fragment` — **не
   хоп**: узел прямой, без `chain`/`detour`.
2. При `tls.enabled` на владельце — **молча** `tls.fragment: true`.
   `packets`/`length`/`interval` отбрасываются без кода.
3. Freedom **без** `settings.fragment` — `dialerProxy` молча игнорируется.
4. Узел без TLS — флаг не ставится.
5. `blackhole`/`dns`/`loopback` как цель — отбраковка владельца как
   раньше.
6. Обычный прокси-outbound как цель — цепочка как раньше.

Разбор: цель `freedom` обрабатывается до `_xrayBuildChain` в
`json_parsers.dart` — цепочка релеев не переписывалась.

Фикстура: `app/test/fixtures/xray/dialer_proxy_freedom_fragment.json`.

## Критерии приёмки

- Кейс корпуса `dialer_proxy_freedom_fragment`: один узел, `tls.fragment:
  true`, без цепочки, без предупреждений.
- Freedom без fragment → узел без `tls.fragment`, без кодов.
- `security=none` + dialerProxy=fragment → узел без `tls.fragment`.
- `dialerProxy=block` (blackhole) и `dialerProxy` на `dns` → узел отбракован.
- Регрессия §404: обычная цепочка dialerProxy зелёная.
- `flutter analyze` — без новых issues; затронутые тесты зелёные.
