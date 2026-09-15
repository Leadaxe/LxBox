# 437 — Tailscale: связка узла v2 и импорт из многоузлового конфига

| Поле | Значение |
|------|----------|
| Статус | **Released в v2.24.0** (15.09.2026, ядро `v1.14.0-lx.39`). Done — реализовано 14.09.2026 (device-verify не делался: живого tailnet на стенде нет, ключа нет) |
| Дата старта | 2026-09-14 |
| Триггер | Отчёт пользователя Cultsonfire (Telegram, 14.09): «устройства tailnet видны, связи с ними нет; exit node игнорируется; непонятен формат exit_node». Подтверждённых данных о LxBox в отчёте нет (дамп — 2.23.1 на ядре lx.34, Tailscale там не поддерживается; скриншоты — другой клиент на sing-box 1.15.0-alpha.3). Разбор по исходникам нашёл три реальных пробела §435, которые дают ровно такой симптом |
| Связанные | [§435](../features/435%20node-sections-tailscale/spec.md) (узел Tailscale и секции), контракт `app/contract/docs/NODE_SECTIONS.md` §6, [docs/PROTOCOLS.md](../../PROTOCOLS.md) §9.7 |
| Коммиты | `0b989a15` — код и тесты; `docs(437)` — спеки, PROTOCOLS §9.7, STORAGE «Node sections», CHANGELOG |

## Что нашлось (проверено по исходникам ядра lx.38, tailscale 1.102.1-mod.4 и LxBox, перекрёстно опровергнуть не удалось)

1. **Многоузловой конфиг → узел без связки.** Вставка целого sing-box-конфига,
   где кроме `tailscale`-endpoint'а есть хотя бы один прокси (типичный
   «рабочий конфиг из другого клиента»: endpoint + прокси + `final` на
   прокси), даёт файловую подписку (`_addJsonNodes`, порог §368), а у узлов
   подписки секций не бывает (NODE_SECTIONS §1, `_collectNodeSections`
   пропускает `SubscriptionServers`). Извлечение связки в парсере работает
   только при ровно одном payload-узле (§6). Итог: endpoint в `endpoints[]`
   входит в tailnet (устройство видно в консоли), но маршрута
   `100.64.0.0/10 → узел` и DNS-сервера нет — трафик к 100.x уходит в
   `route.final`. Голое тело `{"type":"tailscale",…}` — то же: секций нет,
   связку создаёт только мастер.
2. **FakeIP.** Правило узла матчит только `ip_cidr`, DNS-правило узла стоит в
   конце `dns.rules` — после catch-all пресета FakeIP (`query_type A/AAAA →
   fakeip`). С включённым FakeIP имя `host.tailnet.ts.net` получает
   фиктивный адрес, `resolve`-action пресет снимает (`@resolve_enabled =
   false`), `ip_cidr` по fqdn-назначению без адресов не матчится
   (`rule_item_cidr.go:90-96`) — соединение уходит в `final`. Нужен матч по
   `domain_suffix .ts.net` (внутри одного правила `domain_suffix` и
   `ip_cidr` — ИЛИ, `rule_abstract.go:126-137`), и для UDP — `resolve` перед
   терминальным правилом: без адресов pre-match ядра отбрасывает UDP-поток к
   endpoint'у («a resolve action is required before routing to
   outbound/tailscale[…]», `route.go:519-535`); TCP проходит через sniff и
   резолвится самим endpoint'ом (`Endpoint.DialContext` → `dnsRouter.Lookup`
   с `allowFakeIP=false`, catch-all FakeIP пропускается, правило `.ts.net`
   в конце достигается).
3. **IPv6 tailnet.** Узлы tailnet получают и `fd7a:115c:a1e0::/48`
   (`tsaddr.TailscaleULARange`); при стратегии `prefer_ipv6`/`ipv6_only`
   маршрут с одним `100.64.0.0/10` промахивается. Под дефолтом LxBox
   (`ipv4_only`) v6 не всплывает.
4. **`exit_node`.** Формат — IP Tailscale или имя машины (base name, FQDN с
   точкой и без, первая метка для shared-in узлов; регистр не важен), пир
   обязан анонсировать exit node (`ipn/prefs.go:884-940`). Применяется по
   достижении `Running` и повторяется при изменении списка пиров; ошибка —
   строка `set exit node: …` уровня error, endpoint работает дальше без exit
   node. В интернет через endpoint без exit node трафик не уходит вовсе
   (gVisor-стек tsnet, ни один пир не несёт `0.0.0.0/0`; TCP умирает по
   таймауту 15 с). В LxBox узел с `exit_node` — кандидат Направлений, и
   интернет через него идёт только когда узел выбран Направлением. Поле
   `exit_node_allow_lan_access` в форке на маршрутизацию не влияет
   (`local.go:6552-6558` вырезает exit/LAN-маршруты; на Android у tsnet нет
   OS-роутера) — в мастер не добавляем.
5. **Omit-теги AAR (11 `ts_omit_*`) и защита сокетов** data-path не трогают:
   magicsock/DERP/netstack не вырезаны, UDP-сокеты биндятся через
   `AutoDetectInterfaceControl` → `VpnService.protect`.

## Что сделано

| Слой | Было | Стало |
|---|---|---|
| Связка мастера `lib/models/tailscale_bundle.dart` (переехала из `screens/add_server_wizard/`) | правило `ip_cidr: [100.64.0.0/10] → @self` | правило `@{self} network`: `domain_suffix: [.ts.net]` + `ip_cidr: [100.64.0.0/10, fd7a:115c:a1e0::/48] → @self`, метаданные LxBox `resolve: {serverTag: @{self}-dns}` (нетерминальное `action: resolve` через DNS-сервер узла перед маршрутом — закрывает FakeIP, включая UDP). DNS-сервер и DNS-правило прежние. Записей по-прежнему три |
| Парсер `singbox_config.dart` | извлечение связки только при одном payload-узле | плюс: в многоузловом конфиге `tailscale`-узлы получают записи по явной ссылке на свой тег (`extractNodeSections(config, rawTag)` — те же критерии §6); остальные узлы — как раньше |
| Контроллер `_addJsonNodes` | >1 узла → файловая подписка целиком | `tailscale`-узлы многоузловой вставки выделяются в свои `UserServer` (тело `toUri()`, секции — извлечённые или каноническая связка); остаток (текст без `tailscale`-записей в `endpoints[]`/`outbounds[]`) идёт прежним путём — один узел → `UserServer`, несколько → файловая подписка, чей кэш уже без tailscale (иначе узел вернулся бы при старте из `_rehydrateFromCache`) |
| Контроллер, новые свободные узлы | секции = только извлечённые | `sectionsForNewNode(n)`: извлечённые, иначе для `TailscaleSpec` — каноническая связка (`_addJsonNodes` одиночный, `addMembersToFolder`, `addUrlSnapshotToFolder`). Редактор узла (`updateConnectionAt`/`updateMemberAt`) не тронут: голое тело секции не меняет |
| Подписка `sources.dart` | info-лог E1 только при извлечённых секциях | `tailscale`-узел подписки всегда получает info-строку: связка живёт только у свободных узлов, добавьте узел как сервер |
| Мастер, поле Exit node | подсказка «Leave empty…» | подсказка о формате (IP или имя машины-пира с exit node) и о том, что интернет через него идёт при выборе узла Направлением |

Инвариант §3 NODE_SECTIONS (состояние без секций → байт-в-байт прежний
конфиг) не тронут: меняются только содержимое связки и правила её появления.

Отклонения от плана: остаток многоузловой вставки собирается новым хелпером
`lib/services/parser/tailscale_split.dart` (`textWithoutTailscale`) — текстом,
а не отфильтрованным списком узлов, иначе кэш файловой подписки вернул бы узел
дублем на старте; поиск сырого тега узла в `singbox_config.dart` вынесен в
`_extractInto`, общий для одиночной и многоузловой ветки. `addUrlSnapshotToFolder`
получил `sectionsForNewNode` наравне с `addMembersToFolder` (в плане был только
второй). Проверки: `flutter analyze` — 0, `flutter test` — 4368 passed, все
пять чекеров (`ui_check`, `hardcoded_check`, `template_check`, `kotlin_check`,
`parity_check`) в `--strict` — 0 failures.

## Норма для лаунчера (отправлена 14.09, ждём ответа)

1. Каноническая связка: правило с `domain_suffix` + оба CIDR (v4/v6);
   `resolve{}` — расширение LxBox, вторая сторона игнорирует (ONE_NAMESPACE).
2. Многоузловой конфиг: `tailscale`-узлы получают записи по явной ссылке на
   тег (однозначно, без риска утащить чужие правила); прочие узлы — норма §6.
3. `tailscale`-узел, созданный без записей (голое тело, конфиг без ссылок) →
   каноническая связка по умолчанию; пользователь снимает через Clear sections.
4. `tailscale`-узел в подписке — info-строка стороны (связка только у
   свободных узлов).

## Известные ограничения

- Узел Tailscale внутри URL-подписки маршрута в tailnet не получает (секции
  только у свободных узлов) — лог + подсказка; лечится «добавить как сервер».
- Подсети за пирами (`accept_routes`) в связку не входят — правило на них
  пользователь добавляет сам в секциях узла.
- MagicDNS отвечает только на FQDN `*.ts.net`; короткие имена (search domain)
  — нет (`accept_search_domain` в форму не вынесен).
- На стенде живого tailnet нет (ключа нет): вход в tailnet и связь с пирами
  не проверены; проверено — сборка конфига, порядок и состав правил.

## Тесты

- `test/models/tailscale_bundle_test.dart` — связка v2 (domain_suffix, два
  CIDR, `resolve.serverTag`, подстановка тега во все ссылки).
- `test/parser/tailscale_sections_test.dart` — многоузловой конфиг:
  `tailscale` получает свои записи, прокси — нет.
- `test/subscription/singbox_config_import_test.dart` — вставка endpoint +
  прокси → `UserServer` (ts, секции) + `UserServer` (прокси); endpoint + два
  прокси → `UserServer` (ts) + файловая подписка без `tailscale` в кэше;
  голое тело → каноническая связка; конфиг с одним ts без ссылок →
  каноническая; папка: голое тело членом → каноническая.
- `test/builder/node_sections_build_test.dart` — связка v2 при сборке: два
  правила (resolve через `<тег>-dns`, затем маршрут) на один headless-набор с
  `domain_suffix` и обоими `ip_cidr`.
