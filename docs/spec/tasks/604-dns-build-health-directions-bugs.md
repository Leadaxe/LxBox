# §604 — Баги DNS, сборки, проверки узлов и Направлений из аудита 591

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | D (done) |
| Фича | [005-DNS](../features/005-DNS/FEATURE.md), [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md), [003-CONFIG_BUILD](../features/003-CONFIG_BUILD/FEATURE.md), [009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md), [026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md) |
| Дата | 2026-09-30 |
| Связанные | аудит §591 (пункты [bug] 005, 010, 003, 009, 026), §530, §588, §601, §292, §113, §272, §197 |

Восемь пунктов аудита 591 с вердиктом «подтверждён». Пункт про
`pool_tolerance` 65535/15000 сюда не входит (проверяется на эмуляторе).

## 1. 005-DNS — правка SNI в форме теряет остальные поля `tls`

**Проблема.** `DnsServerEditController.onSniChanged`
(`app/lib/screens/dns_server_edit/edit_controller.dart`) при непустом SNI
пишет `_body['tls'] = {enabled, server_name}` — `insecure`, `alpn`,
`certificate`, `utls` и т. п., заданные на JSON-вкладке, пропадают. Пустой
SNI удаляет весь объект `tls`, даже если в нём есть другие поля.

**Решение.** Правка SNI меняет только `tls.server_name` (и ставит
`tls.enabled: true`, если ключа нет). Пустой SNI снимает только
`server_name`; объект `tls` уходит целиком, лишь когда в нём не осталось
ничего, кроме `enabled`.

**Приёмка.** Тест: тело с `tls {enabled, server_name, insecure, alpn}` →
смена SNI сохраняет `insecure`/`alpn`; очистка SNI сохраняет их и убирает
`server_name`; `tls {enabled, server_name}` при очистке уходит целиком.

## 2. 005-DNS — своё правило со ссылкой на отсутствующий сервер

**Проблема.** Своё DNS-правило (`kind: inline`, JSON) эмитится после чистки
`rule_set` без сверки `server` с серверами, попавшими в `dns.servers`
(`app/lib/services/builder/post_steps/dns_rules.dart`). Сервер удалён или
выключен → ядро на каждом запросе отвечает «DNS server not found». srs-правило
с таким сервером — так же. Валидатор ловит висячие ссылки только у
`dns.final` / `default_domain_resolver`.

**Решение.** В `applyCustomDns` правило (inline и srs), чей `server` —
строка, которой нет среди эмитированных тегов, в конфиг не попадает и даёт
`template_fragment_dropped {owner: name правила | dns_options, kind:
dns.rules, reason: server}` — тот же код и та же форма, что у выпадения по
`rule_set` (§588) и у серверного правила пресета (`server/action`).
Серверы, выпавшие из-за висячего detour (§441), в эмитированные входят —
их лечит `healDetourDroppedDnsRefs`, как и раньше. Правила без `server`
(serverless-действия `predefined`/`reject`) не проверяются. Набор srs-правила,
выпавшего по серверу, не считается «живым» для ссылок других правил.

Редактор правила сервер не проверяет — сервер могут удалить после
сохранения правила, поэтому проверка в сборке.

**Приёмка.** Тест: inline-правило на несуществующий сервер отсутствует в
`dns.rules`, код `template_fragment_dropped` с `reason: server`; правило на
живой сервер и serverless-правило эмитятся.

## 3. 005-DNS — srs-правило без `server` выпадает молча (частично)

**Проблема.** Выпадение srs-правила без скачанного `.srs` — норма (§588,
§601) и уже даёт `template_fragment_dropped`. Подтверждена только вторая
часть: srs-правило без `server` пропускается молча (`continue`).

**Решение.** srs-правило без `server` (и со `server` на отсутствующий
сервер, п. 2) выпадает с `template_fragment_dropped`, `reason: server`.
Выпадение без файла не меняется.

**Приёмка.** Тест: srs-правило со скачанным файлом, но без `server` — в
`dns.rules` нет, код с `reason: server` есть.

## 4. 010 — порт прокси не проверяется при чтении из хранилища

**Проблема.** `_getVpnMode` (`app/lib/services/settings_storage/vpn_mode.dart`)
принимает любой `int` в `proxy_port` — порт из бэкапа или руками правленного
файла (0, 80, 70000) доходит до `inbounds` и роняет ядро на reload.
Проверка `VpnModeConfig.isValidPort` (§292) есть только в UI и Debug API.

**Решение.** Чтение: порт вне `isValidPort` → `defaultPort` (как невалидный
`proxy_listen` → loopback). Запись `_setVpnMode`: невалидный порт →
`ArgumentError`, как невалидный `mode`.

**Приёмка.** Тест: в файле `proxy_port: 80` / `70000` → `getVpnMode` даёт
2080; `setVpnMode` с портом 80 бросает `ArgumentError`.

## 5. 003-CONFIG_BUILD — «конфиг устарел» только для 16 переменных

**Проблема.** `_setVar` поднимает `configDirty` только для
`SettingsStorage._configVarKeys` (16 имён). Шаблон объявляет 34 переменные;
18 из них (`tls_fragment*`, `tls_mixed_case_sni`, `tls_record_fragment`,
`urltest_*`, `certificate_store`, `ipv6_enabled`, `route_address_enable`,
`resolve_enabled`, `vpn_mode`, `proxy_*`) плашку не зажигают при записи через
Debug API `PUT /settings/vars` и `on_change` пресета.

**Решение.** Список дополняется всеми переменными, объявленными в
`wizard_template.json` (`sections[].vars[].name`). Тест-гард сверяет список
с шаблоном: новая переменная шаблона без записи в список — красный тест.

**Приёмка.** Тест: каждая переменная секций шаблона ∈ списка; `setVar
('tls_fragment', …)` поднимает `configDirty`; `setVar('node_list_two_columns',
…)` — нет.

## 6. 009-NODE_HEALTH — пустой глобальный URL в проверке списков

**Проблема.** `ProbeController.resolvePingOptions`
(`app/lib/services/probe/probe_controller.dart`) без глобального URL в
`ping_options` отдаёт пустую строку — проверка подписки/папки уходит на
умолчание ядра, а не на `ping_options.url` шаблона, как главный пинг
(`pingUrl` в `ping_orchestration.dart`: storage → шаблон). Рядом та же
ошибка в редакторе Направления: пустое поле Test URL сохраняется как `url:
""` и эмитится в urltest-двойник дословно, хотя пустые Interval/Idle
подставляют умолчание формы.

**Решение.** `resolvePingOptions`: пустой override и пустой глобальный URL →
`ping_options.url` шаблона (`TemplateLoader.load().pingOptionsModel.defaultUrl`).
Редактор Направления: пустой Test URL → `DirectionAuto.defaultUrl`.

**Приёмка.** Тест: хранилище без `ping_options.url` → `resolvePingOptions()`
отдаёт URL шаблона; override папки выигрывает; глобальный — выигрывает у
шаблона.

## 7. 026-DIRECTIONS — `interval` 15m в конструкторе, 5m при чтении

**Проблема.** `DirectionAuto()` даёт `interval: '15m'` (§272), а
`DirectionAuto.fromJson` без ключа — `'5m'`; пустое поле Interval в редакторе
Направления сохраняется как `'5m'`. Шаблон (`urltest_interval`) — `15m`.

**Решение.** Константы `DirectionAuto.defaultInterval = '15m'` и
`DirectionAuto.defaultUrl`; конструктор, `fromJson` и редактор берут их.
Записи с ключом `interval` не меняются.

**Приёмка.** Тест: `DirectionAuto.fromJson({})` → `interval == '15m'`, равно
`const DirectionAuto().interval`.

## 8. 026-DIRECTIONS — счётчик узлов игнорирует «Exclude matching»

**Проблема.** `_nodeCountFor` (`app/lib/screens/routing_screen.dart`) считает
`all.where(re.hasMatch)` без `nodeFilterInvert` — при «Exclude matching»
подпись показывает число исключённых узлов. Сборка инверсию учитывает
(`build_config.dart`, `nodesFor`).

**Решение.** Один фильтр на модели: `Direction.filterNodeTags(tags)`
(регистронезависимо, `tryCompileRegex`, битый/пустой regex → все узлы,
инверсия §197). Им пользуются и сборка, и экран.

**Приёмка.** Тест: теги `[a-de, b-nl, c-de]`, фильтр `de`: без инверсии 2,
с инверсией 1; пустой и битый фильтр → 3.

## Проверка

Юнит-тесты по пункту, файлы по одному; `flutter analyze` чисто.

## Коммиты

- `c672b14a` спека
- `a4cd8568` + `f50c1614` п. 1 — SNI (задача 530 закрыта этим пунктом)
- `078d5c05` п. 2–3 — DNS-правила на отсутствующий сервер / без `server`
- `a500e64e` п. 4 — порт прокси при чтении
- `57d1d0fe` п. 5 — «конфиг устарел» для всех переменных шаблона
- `68200a43` п. 6 (редактор), 7, 8 — умолчания `DirectionAuto`, счётчик узлов
- `bd81720f` п. 6 — URL проверки списков из шаблона
