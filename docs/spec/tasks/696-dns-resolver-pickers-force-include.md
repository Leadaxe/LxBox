# 696 — сервер, выбранный в DNS Final / Default Domain Resolver, эмитится всегда

| Поле | Значение |
|------|----------|
| Статус | Done (эмулятор не проверен) |
| Дата начала | 2026-10-30 |
| Источник | находка эмулятора §695 (issue #182): выключенный Shield под пикерами при сборке не эмитится, heal §419 молча переставляет оба пикера на первый пригодный сервер конфига (на стенде `ru-direct:dns_ru`) и сохраняет это в хранилище; решение владельца — сервер из пикеров попадает в конфиг всегда, как серверы пресетов и правил |
| Связанные | §117 №7 (force-include: пресет, правило с DNS-опцией, `dnsServerRefEmitted`), §419 (heal битых `dns.final` / `default_domain_resolver`), §680 (выключенные записи не эмитятся; лок пикеров в UI), §695 (выключенная группа не держит членов; исключение «(last member)» — снимается этой задачей), §312/§443 (фильтр членов группы, `EmptyDnsGroup`) |

## Проблема

Лок пикеров DNS Final / Default Domain Resolver существует только в UI
(§680): выбранный сервер нельзя выключить и удалить. Сборка этот лок не
знает: `dnsServerRefEmitted` (`post_steps/dns_servers.dart:300`) эмитит
выключенную запись только по ссылке пресета или правила. Состояние
«выбран в пикере, но выключен» получить в новом UI нельзя, но оно приезжает
из версий до 2.25.17 (запись `dns_shield` с `enabled:false`, пикеры на
нём — автор #182).

Тогда при сборке `dns_shield` в `dns.servers` нет, heal §419
(`heal_dangling_dns_resolvers.dart`) подставляет дефолт шаблона — тот же
`dns_shield`, которого тоже нет, — и берёт первый пригодный сервер
собранного списка (`_DnsResolverPool.replacement`), а `build_config.dart:984`
персистит результат в vars. Пользователь получает в пикерах случайный
сервер (на стенде — группа Яндекса из пресета ru-direct, который при
выключении пресета уйдёт и heal сработает снова), предупреждение сборки
говорит про «пресет выключен или удалён». Первым пригодным может оказаться
и `local_dns_resolver` (системный DNS мимо VPN), и UDP через туннель, не
способный ответить до подъёма туннеля.

## Решение

### Сборка

Теги, выбранные в `dns_final` и `dns_default_domain_resolver` (значения
vars после подстановки, строка или `{server}` у resolver), — третий источник
force-include наравне с пресетом и правилом:

- `dnsServerRefEmitted` получает `resolverReferenced: bool`; эмитится при
  любом из трёх.
- Если выбранный сервер — группа (`type: group`, тело из шаблона / inline
  после подстановки vars), force-include распространяется на её
  `servers[]`, рекурсивно для вложенных групп (как у пресета: его группа
  приходит вместе с членами через `presetServersByTag`). Иначе forced-группа
  с выключенными членами опустела бы после §312 и дала фатальный
  `EmptyDnsGroup`.
- Множество считается в `applyCustomDns` рядом с `ruleReferencedTags` из
  уже известных vars (`resolverDefaults` рядом в `build_config.dart:918`
  показывает, где взять имена var); передаётся в `resolveDnsServersBodies`
  отдельным параметром `resolverReferencedTags`, не подмешивается в
  `ruleReferencedTags` (у них разные подписи в UI).
- Heal §419 не меняется: он остаётся для настоящего случая — тег пикера
  указывает на сервер, которого в списке нет вовсе (сервер ушедшего
  пресета, удалённая запись). Текст предупреждения уточнить: «DNS server
  "X" is not in the list» вместо «its preset was disabled or removed» — у
  записи списка пресета может и не быть.

### UI

- `ResolvedServer.forceIncluded` = пресет ∨ правило ∨ **пикер** (новое поле
  `usedByResolver: bool`; `lockedBySources` уже перечисляет
  `dnsFinalLabel` / `defaultResolverLabel` через `usedByList`, подписи не
  меняются). Тайл и Params показывают такой сервер включённым и залоченным
  (`switchOn = enabled || forceIncluded` — уже так), SnackBar «Locked: used
  by DNS Final, Default Domain Resolver» — уже так.
- Члены forced-группы: `dnsServerListRefs` передаёт в `dnsServerListHolds`
  `enabled || forceIncluded` (§695) → группа под пикером считается
  включённой → члены держатся с «used by Shield DNS (multi-provider
  group)». Сами члены forced-группы тоже `forceIncluded` (сборка их эмитит)
  → показываются ON и залоченными.
- Исключение «(last member)» §695 **снимается**: `DnsServerHold.lastMember`,
  ветка в `dnsServerListHolds`, параметр `lastMemberLabel`, строка
  «%s (last member)» в ru/zh и её тесты — удалить. Выключенная группа без
  ссылок из пикеров членов по-прежнему не держит; под пикерами она теперь
  forced и держит всех.
- Пикер членов группы на вкладке DNS (`dns_settings_tab.dart:350`,
  `_dnsMemberOptions`) — `dnsServerRefEmitted` с новым флагом.
- Импорт бэкапа (§681, `dnsForcedTags` в `dns_backup.dart:311`) —
  **не менять**: расчёт `available` там по контракту 1.1.135; ссылки
  пикеров в нём уже учтены как `final` / `default_domain_resolver`.

### Состояние автора #182 после этой задачи

Shield выключен в хранилище, пикеры на нём → в конфиге Shield и все шесть
членов; на вкладке DNS Shield ON + 🔒 «used by DNS Final, Default Domain
Resolver», члены ON + 🔒 «used by Shield DNS (multi-provider group)»; тап по
любому тумблеру объясняет лок. Путь пользователя: переставить пикеры →
Shield свободен → выключить/удалить его и членов. Ничего молча не меняется,
хранилище не трогается (`enabled:false` остаётся, как у серверов пресетов).

### Файлы

- `app/lib/services/builder/post_steps/dns_servers.dart` —
  `dnsServerRefEmitted(resolverReferenced:)`, параметр
  `resolverReferencedTags` в `resolveDnsServersBodies`, расчёт множества с
  раскрытием групп (где именно — там, где известны тела: после resolve
  шаблонных тел, см. как считается `presetServersByTag`), `applyCustomDns`.
- `app/lib/services/builder/build_config.dart` — передача тегов пикеров
  (из vars), текст предупреждения §419.
- `app/lib/screens/dns_settings_screen/resolved_server.dart`,
  `dns_server_resolver.dart`, `dns_settings_tab.dart` — `usedByResolver`,
  forced-члены, снятие «(last member)».
- `app/lib/services/dns/dns_server_holds.dart` — снять `lastMember`.
- `app/assets/l10n/ru/ui.json`, `zh/ui.json` — снять «%s (last member)».
- `docs/spec/tasks/695-*.md` — пометка «исключение (last member) снято
  §696»; `CHANGELOG.md` Unreleased → запись §695 дополнить одной фразой
  про пикеры (отдельную не заводить, релиза между ними нет).

## Риски и граничные случаи

- Пикер на группе пресета (`ru-direct:dns_ru`) — уже forced через пресет,
  ничего не меняется. Пикер на сервере выключенного пресета — записи в
  списке нет, heal §419 как раньше.
- Пикер на `fakeip`/`hosts` — валидатор `BadResolverServerType` как раньше;
  force-include его не обходит.
- Вложенные группы — рекурсия с защитой от цикла (цикл ловит
  `_findDnsGroupCycles`, здесь просто `seen`).
- Forced-сервер с висячим `detour` (§441) — выпадает второй линией как
  сейчас, его ссылку лечит `healDetourDroppedDnsRefs`; не трогать.

## Проверка

Тесты — только затронутые файлы по одному, Sonnet-субагентом:

- `app/test/builder/` — тест `resolveDnsServersBodies`/`applyCustomDns`
  (найти существующий по `ruleReferencedTags`): выключенный сервер под
  пикером эмитится; выключенная группа под пикером эмитится с выключенными
  членами; без пикера — не эмитится.
- `app/test/builder/heal_dangling_dns_resolvers_test.dart` — текст
  предупреждения, поведение без изменений.
- `app/test/screens/dns_settings_screen/resolved_server_locks_test.dart`,
  `locked_switch_test.dart` — кейсы «(last member)» снять, добавить
  «группа под пикером: члены forced и залочены».
- Эмулятор, состояние автора (хранилище: `dns_shield` `enabled:false`,
  пикеры на нём): после старта пикеры НЕ переставлены (`/state/storage`),
  в `/config` группа `dns_shield` с шестью членами, вкладка DNS — Shield и
  члены ON + 🔒, тумблеры дают SnackBar; переставить пикеры на
  `cloudflare_dot` → Shield и члены свободны. Start → connected.

## Итог

Сделано (не закоммичено; эмулятор не гоняли):

- Сборка: `dnsServerRefEmitted(resolverReferenced:)`; новая pure-функция
  `dnsResolverForcedTags(seeds, bodyOf)` в `post_steps/dns_servers.dart` —
  теги пикеров + рекурсивно `servers[]` групп (`seen` от цикла), общая для
  сборки и вкладки. `resolveDnsServersBodies(resolverReferencedTags:)`
  раскрывает группы по телам записей после подстановки vars (тот же
  `bodyOf`, что у основного прохода). `applyCustomDns` берёт теги из уже
  подставленного конфига: `dns.final` и `domainResolverServer(route.
  default_domain_resolver)` (строка или `{server}`).
- Heal §419 не тронут; текст предупреждения в `build_config.dart` →
  «DNS server "X" is not in the list.».
- UI: `ResolvedServer.usedByResolver` (в `withListState`), `forceIncluded`
  = пресет ∨ правило ∨ пикер; `resolveDisplayedServers` помечает пикеры и
  членов их групп тем же `dnsResolverForcedTags` до расчёта `usedByList`.
  `_dnsMemberOptions` передаёт `resolverReferenced`.
- Снято: `DnsServerHold.lastMember`, ветка в `dnsServerListHolds`,
  параметр `lastMemberLabel` (оба уровня), строка «%s (last member)» в
  ru/zh. `dnsServerFirstHolds` / `dnsForcedTags` / импорт бэкапа не
  тронуты.
- Доки: пометка в спеке 695 (п. 1 и «Итог»), CHANGELOG Unreleased → Fixed,
  запись §695: фраза про исключение «(last member)» заменена фразой про
  пикеры (EN + RU).

Отклонения:

- Теги пикеров берутся в `applyCustomDns` из конфига (vars уже
  подставлены), а не передаются из `build_config.dart` отдельным
  аргументом — тот же источник, без нового параметра.
- `heal_dangling_dns_resolvers_test.dart` не расширен: текст
  предупреждения собирается в `build_config.dart`, сам heal его не знает;
  тест прогнан без правок.

Тесты (по одному файлу): `test/builder/dns_group_test.dart` 25/25 (новые:
выключенный сервер под пикером эмитится / без пикера нет; выключенная
группа под пикером с выключенными членами и вложенной группой; цикл
групп), `heal_dangling_dns_resolvers_test.dart` 5/5,
`resolved_server_locks_test.dart` 16/16 (кейс «(last member)» заменён на
«группа под пикером forced, члены forced и залочены» + «пикеры
переставлены — свободны»), `locked_switch_test.dart` 8/8 (+ forced член:
свитч ON, SnackBar), `dns_backup_merge_test.dart` 29/29 без правок,
`dns_servers_resolver_test.dart` 28/28; `flutter analyze` по затронутым
путям — 0; `hardcoded_check` — 0/0.

Не проверено: сценарий эмулятора из «Проверки».
