[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Ядро и контракт — пин ядра sing-box-lx и общий контракт с лаунчером

У LxBox нет собственного VPN-движка: любой туннель, от VLESS и WireGuard до AmneziaWG и WARP по MASQUE,
исполняет ядро sing-box-lx — форк sing-box. То, как приложение читает ссылки и тела узлов, определяет
контракт, общий с десктопным лаунчером. Фича следит, чтобы обе границы двигались **явно**: ядро поднимается
по ритуалу, контракт приезжает синхронизацией, а расхождения ловит тест, а не пользователь. Она написана
для тех, кто поднимает версию ядра или синхронизирует контракт.

| Поле | Значение |
|------|----------|
| Фича | 021-CORE_CONTRACT |
| Тип | Процессная фича (постоянная работа на границе с ядром и лаунчером) |
| Поглотила | `§121F` (+ `§122F` как объяснение удаления Clash API) |
| Ядро | [Leadaxe/sing-box-lx](https://github.com/Leadaxe/sing-box-lx), ветка `lx`; пин **`v1.14.2-lx.8`** (база — sing-box `1.14.2` + 15 коммитов `stable`) |
| Контракт | реестр контракта с лаунчером **`1.1.99`** — сам реестр описан в [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.ru.md) |
| Состояние | ✅ написана по коду, 2026-09-29 · живой watchlist |

## Какие принципы защищает

1. **Одна версия ядра на всех.** Пин ядра — один файл, его читают и локальная
   сборка, и CI, и F-Droid. Смоук на другой версии, чем пин, не считается.
2. **Ядро строже клиента, клиент видимее ядра.** Ядро разбирает конфиг строго:
   одно неизвестное поле роняет **весь** конфиг, а не один узел. Поэтому
   клиент не выпускает в ядро то, чего ядро не знает, и показывает ⚠️, а ядро
   — страховка на случай, если клиент что-то пропустит (defence in depth).
3. **Контракт — до кода.** Всё, что видят и LxBox, и лаунчер (словари
   протоколов, allowlist'ы, коды предупреждений, лимиты, переменные шаблона),
   описывается в контракте **до** реализации. Код подгоняется под фикстуры
   корпуса, а не фикстуры под код. Намеренное отличие — per-app override со
   ссылкой на решение; override-сирота — ошибка.
4. **Ядро не правится из приложения.** Баг ядра — фидбэк команде ядра, а не
   патч в клиенте; локальный обход в клиенте допустим только как видимая
   защита (снятие поля с кодом), не как молчаливое «починили за ядро».

## Реестр: версии и где они живут

| Что | Значение | Где |
|-----|----------|-----|
| Пин ядра | `v1.14.2-lx.8` | `app/android/libbox.version` — единственный источник |
| Поставка AAR | GitHub Releases форка: `libbox-<ver>.aar` + `SHA256SUMS`, проверка хеша; AAR в git не лежит | `scripts/fetch-libbox.sh`; CI — шаг «Fetch sing-box-lx core» в job `android` |
| Теги сборки AAR | `with_gvisor, with_quic, with_wireguard, with_utls, with_naive_outbound, with_xhttp, with_awg, with_lx_command, with_lx_idle_suspend, with_lx_chain, with_openvpn, with_openconnect, with_tailscale` + `ts_omit_*`; **без** `with_clash_api` | зашиты в ядре; libbox их не отдаёт, приложение держит зеркало набора со своим пином — юнит «пин тегов ядра совпадает с `libbox.version`» краснеет до сверки |
| Управление ядром | libbox CommandClient (push-потоки + unary RPC) | Clash HTTP API удалён (§122) |

Реестр контракта — его версия, копия, lock, зеркала, синк и стражи — это
[025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.ru.md).

## Реестр: что приложение отдаёт ядру сверх апстрима

Ключи и RPC, которых нет в стоковом sing-box, — контракт с форком. Поведение
описано в соседних фичах; здесь — свод, чтобы бамп ядра знал, что проверить.

| Ключ / RPC | Что | Фича | Условие со стороны ядра |
|------------|-----|------|-------------------------|
| `lx.wg.idle_suspend`, `lx.wg.idle_suspend_reachable` | сон WG/AWG-туннелей | [010 · P17](../010-VPN_SERVICE/FEATURE.ru.md#обещания) | ядро ≥ `v1.14.2-lx.1` (раньше — `route.lx_idle_*`); тег `with_lx_idle_suspend`, без него любой `lx.wg.*` роняет старт |
| `lx.wg.lazy_build: true`, `lx.wg.build_max` | ленивая сборка и бюджет WG/AWG | [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.ru.md) | пишутся только вместе с `idle_suspend` |
| не пишутся: `lx.wg.build_overflow`, `lx.masque.idle_timeout`; `lx.naive` | дефолт ядра `wait` устраивает; у WARP MASQUE-узлов свой `idle_timeout`; `lx.naive` зарезервирован и отвергается | — | — |
| AWG `jc`, `jmin`, `jmax`, `s1`, `s2`, `h1`–`h4`, `ip`, `id`, `ib` | обфускация WireGuard | [015-WARP](../015-WARP/FEATURE.ru.md), [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.ru.md) | диапазон `"lo-hi"` в `h*` — ядро ≥ `1.14.0-lx.32` (`min_core` реестра) |
| outbound `masque` | WARP по MASQUE | [015-WARP](../015-WARP/FEATURE.ru.md) | — |
| `transport.type: xhttp`, `xmux{}` | XHTTP | [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.ru.md) | без `xmux` ядро с `lx.6` берёт `max_connections 3` |
| VLESS `encryption`, `tls.reality.key_share` | PQ-слой VLESS, гибридный обмен REALITY | [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.ru.md) | имя метода `encryption` проверяется правилом реестра |
| DNS-сервер `type: group` (`servers`, `mode`, `error_ttl`, `win_ttl`) | группы DNS | [005-DNS](../005-DNS/FEATURE.ru.md) | — |
| `balancer{}` у `urltest`, тип `chain` | балансировщик, цепочки | [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.ru.md) | цепочки — ядро ≥ `1.14.0-lx.27-rc.5` |
| endpoint `tailscale`, `openvpn-client` | узлы-эндпоинты | [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.ru.md) | `tailscale` — тег `with_tailscale` (с `lx.38`); иначе узел не попадает в конфиг |
| `urlTestOutbound`, `urlTestGroup`, `setEndpointEnabled`, `endpointState` | замер, вкл/выкл WG/AWG на лету, состояние эндпоинта | [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.ru.md) | `setEndpointEnabled` — ядро ≥ `v1.14.2-lx.4` |
| подписки `CommandStatus`, `CommandGroup`, `CommandOutbounds`, `CommandConnections`, `CommandDNS`; `GetRunningConfig`, `SubscribeTailscaleStatus` | живое состояние | [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.ru.md) | — |

Гейт реестра на сборке: узел, которому нужен тег сборки или `min_core`,
которых у текущего ядра нет, в конфиг не попадает — см.
[025-CONTRACT_REGISTRY · P8](../025-CONTRACT_REGISTRY/FEATURE.ru.md#обещания).

## Ритуал приёма новой версии ядра

1. **Ядро выпущено как GitHub Release форка.** До релиза (цепочка rc) AAR
   берётся из артефакта CI-прогона форка и кладётся руками; пин **не
   коммитится** — пин на несуществующий релиз ломает fetch всем и CI.
2. **Дельта поверхности.** `javap` по `classes.jar` старого и нового AAR;
   дифф `option/*.go` — новые поля тел сначала попадают в реестр у лаунчера,
   потом приезжают синком (`sync_contract.sh --to <sha>`). Без этого санитайзер
   снимает новые поля как `unknown_key`: узел работает, но тихо без них.
3. **Теги сборки.** Сверить набор тегов AAR, передвинуть пин зеркала тегов.
4. **Грабли бампа** (подробно — [KERNEL.md](../../../KERNEL.md)):
   `with_lx_idle_suspend` и `lx.wg.*`; неизвестное поле убивает весь конфиг;
   порядок архивации отчёта о падении и усечения файла (на нём стоит
   обнаружение прошлого падения); имя метода VLESS `encryption` в правиле реестра.
5. **Поднять пин → fetch → смоук на устройстве**: старт/стоп, потоки
   CommandClient, AWG/XHTTP/MASQUE-узлы. Версию ядра проверять только по
   `core_version` из Debug API `/device` или дампа — gomobile-бинарь её
   через `strings` не показывает.
6. **CHANGELOG + история версий в KERNEL.md.** Откат ниже `v1.14.2-lx.1`
   требует сначала вернуть эмит `route.lx_idle_*`.

В продакшене — **только официальный релизный AAR**: локальная сборка
gomobile не воспроизводится побайтно, хеш из `SHA256SUMS` с ней не сойдётся.

## Обратная связь ядру

Проблема ядра оформляется фидбэк-задачей: симптом, что подтверждено на
стороне клиента (биндинг есть, вызов штатный), версия ядра и устройство,
logcat/дамп. Клиент при этом не патчит поведение ядра.

| Фидбэк | Суть | Итог |
|--------|------|------|
| [180-FEEDBACK](../../tasks/180-FEEDBACK-kernel-dns-unimplemented.md) | `SubscribeDNSQueries` → `Unimplemented` на rc.7 | починено в rc.8 (ключ service-registry) |
| [180-FEEDBACK-2](../../tasks/180-FEEDBACK-2-kernel-dns-processinfo-empty.md) | `DnsQuery.ProcessInfo` пуст у всех событий | принято, фикс в rc.9 (поиск процесса до fast-path) |
| [376-FEEDBACK](../../tasks/376-FEEDBACK-kernel-urltest-goroutines-survive-restart.md) | URLTest-прогон переживает перезапуск ядра, течёт горутинами | — |
| [120](../../tasks/120-upstream-bugreport-default-network-vpn.md) | seed `defaultNetwork` может быть нашим же VPN (апстрим-клиент) | PR в SagerNet/sing-box-for-android#61; у себя — §119 |

Встречный канал — лаунчеру: недостающие ожидания корпуса и расхождения
реестра (например, [529](../../tasks/529-contract-corpus-local-reds-triage.md)).

## Запрещено

- Править ядро «из приложения» и держать его локальные сборки в релизе.
- Возвращать Clash API: `experimental.clash_api` в конфиге — фатальная ошибка
  старта, `with_clash_api` в AAR нет намеренно (§122: контракт данных
  перешёл с pull-снапшотов на push-дельты CommandClient с единой отменой).
- Коммитить пин на версию, которой нет в Releases форка.

## Задачи-ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [060](../../tasks/060-libbox-1-13-migration/spec.md) | Done | libbox 1.12 → 1.13.11, обвязка под single-CommandServer |
| 2 | [104](../../tasks/104-libbox-fork-ci-fetch.md) | DONE | постоянная схема поставки AAR форка: пин-файл + fetch с хешем, локально и в CI |
| 3 | [121F](../../tasks/121F-libbox-1.14-adoption/spec.md) | Реализовано | переход на 1.14: ломающих правок в клиенте нет, gate — device-смоук |
| 4 | [122F](../../tasks/122F-commandclient-migration/spec.md) | Реализовано | CommandClient вместо Clash API, смена контракта данных |
| 5 | [191](../../tasks/191-remove-clash-api-from-core.md) | ✅ | Clash API убран из настроек ядра и шаблона |
| 6 | [205](../../tasks/205-libbox-rc12-cold-urltest.md) · [210](../../tasks/210-libbox-rc15-sticky-none.md) · [214](../../tasks/214-libbox-rc16-xhttp-fields.md) · [215](../../tasks/215-libbox-rc18-idle-suspend.md) | — | бампы rc 1.14.0: urltest, sticky, поля XHTTP, idle-suspend |
| 7 | [213](../../tasks/213-debug-device-core-version.md) · [378](../../tasks/378-dump-app-and-core-version.md) | — · Done | реальная версия ядра в `/device` и в дампе |
| 8 | [457](../../tasks/457-kernel-lx4-reality-key-share.md) · [461](../../tasks/461-kernel-lx5-short-id-hotfix.md) · [462](../../tasks/462-kernel-lx7-validation-error-tags.md) · [468](../../tasks/468-kernel-lx8-grpc-service-name-verbatim.md) | Released | ядро 1.14.1-lx.4…lx.8 |
| 9 | [522](../../tasks/522-kernel-lx9-xmux-local-cancel.md) · [526](../../tasks/526-kernel-lx10-upstream-sync-naive-addr.md) | Released v2.25.3 | 1.14.1-lx.9, lx.10 |
| 10 | [535](../../tasks/535-kernel-1-14-2-lx1-pin-lx-wg-keys-endpoint-state.md) | Реализовано | 1.14.2-lx.1: блок `lx`, `endpointState` |
| 11 | [557](../../tasks/557-kernel-lx4-wg-endpoint-toggle.md) | Реализовано | 1.14.2-lx.4: вкл/выкл WG/AWG на лету |

Ревизии реестра (460F, синки контракта, 486, 491, 529) перенесены в
[025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.ru.md).

## Следить за

- **Бампы `v1.14.2-lx.5…lx.8` без своей задачи.** Они есть в KERNEL.md и
  CHANGELOG, но не в `tasks/` — ревизии этой фичи для них нет.
- **Зеркало тегов сборки** в приложении — ручная копия; страж сверяет только
  пин версии, а не сам набор.
- **Противоречивые списки тегов в KERNEL.md:** `with_openvpn`/`with_openconnect`
  есть в списке тегов AAR и одновременно названы «намеренно исключёнными».
- **Апстримные изменения строгости** (как `format` в inline rule_set на 1.14):
  каждое «ядро стало строже» — кандидат на санитайзер при импорте.

## Связанные фичи

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.ru.md) — разбирает узлы без
  ядра; `min_core` при разборе выключен.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.ru.md) — исполняет гейт реестра против запиненного
  ядра стадией 5 сборки.
- [005-DNS](../005-DNS/FEATURE.ru.md) — DNS-группы форка.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.ru.md) — балансировщик и цепочки, минимальная версия ядра.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.ru.md) — RPC замера и вкл/выкл
  эндпоинта; автоотключение отвергнутых ядром.
- [010-VPN_SERVICE · P17](../010-VPN_SERVICE/FEATURE.ru.md#обещания) — ключи `lx.wg.*`.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.ru.md) — подписки CommandClient.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.ru.md) — версия ядра в дампе, отчёты о падении ядра.
- [015-WARP](../015-WARP/FEATURE.ru.md),
  [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.ru.md) — поля AWG, MASQUE,
  XHTTP, VLESS encryption.
- [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.ru.md) — fetch ядра в CI, проверка версии ядра в релизном APK.
- [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.ru.md) — реестр контракта: схемы,
  санитайзер, гейт сборки, коды предупреждений, синк и стражи.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.ru.md) — версия ядра в `/device`.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.ru.md) — endpoint `tailscale`, тег сборки `with_tailscale`
  и поток `SubscribeTailscaleStatus` в работе.

## Особенности сопровождения

- Полный справочник ядра — [KERNEL.md](../../../KERNEL.md); процесс контракта —
  [CONTRACT.md](../../../CONTRACT.md). Фича — свод правил, не копия этих доков.
- Спеки ядра (SPEC NNN) живут в репозитории форка; SPEC 103 контракта — в
  репозитории лаунчера (одноимённая `tasks/103-…` здесь — другая задача).
- Свежий worktree не содержит AAR и копии контракта — см.
  [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.ru.md).
