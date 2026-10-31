# 701 — Раннер корпуса контракта `dns`; шаблонный DNS-сервер с `required` в сборке

| Поле | Значение |
|------|----------|
| Статус | Done (корпус dns: 9 пройдено, 1 пропущен по решению §312; эмулятор не нужен — UI не менялся) |
| Дата начала | 2026-10-31 |
| Источник | лаунчер, `contract/TASKS_LXBOX.md` §140 (1.1.144): прогнать кейсы `group_prunes_hosts` и `group_hosts_all_dropped` своим раннером. Раннера `corpus/dns` у нас не было, хотя README каталога говорит обратное |
| Связанные | §699 (ключ `hosts` у DNS-группы), §312 (фильтр членов групп, пустая группа), §443 (группа, опустевшая от висячего detour), §695 (правило 5 «ссылка держит»), §681 (бэкап: `used_by: required`), §117 (обёртка шаблонного сервера) |

## Проблема

1. Каталог `app/contract/corpus/dns/` (9 кейсов) никто у нас не гонял:
   раннеры есть у `rule_dns`, `direction`, `backup` и др., у `dns` — нет.
2. Норма контракта: шаблонный сервер с `required: true` эмитится и при
   `enabled: false` в состоянии (кейс `required_ignores_state`; BACKUP.md
   §9 п. 5: «такой сервер сборка эмитит всегда»). Наша сборка флаг не
   читала — `dnsServerRefEmitted` знал только `enabled` и force-include
   пресетов/правил. В шаблоне LxBox `required`-серверов нет, так что дыра
   скрытая, но импорт бэкапа (§681) уже держит такую запись с
   `used_by: required`, полагаясь на эту норму.

## Диагностика

Раннер `app/test/contract/dns_corpus_test.dart` (образец —
`rule_dns_corpus_test.dart`, эталон лаунчера —
`core/build/contract_dns_test.go`):

- запись шаблона → обёртка §117; плоскую форму раннер заворачивает сам
  (служебные `description`/`enabled`/`required`/`vars` наверх, остальное в
  `server`): шаблон LxBox пишет только вложенную, плоскую сервером не читает;
- ref-список — как после посева каталога (§680): записи шаблона в его порядке
  (порядок каталога — как у лаунчера, `resolve_dns.go`), `enabled` из
  шаблона, `state[]` перекрывает `enabled` и `vars`;
- шаг материализации `resolveDnsServersBodies` с `coreVersion` =
  `kDnsGroupHostsMinCoreVersion` (lx.26). Загрузка состояния
  (`resolveDnsServersList`) в раннер не входит: там §695 правило 5 включает
  выключенный член группы, и кейсы чистки состава проверяли бы модель
  состояния, а не сборку.

Первый прогон: 7 из 9 зелёные, включая оба кейса `hosts` (§140). Упали:

- `required_ignores_state` — получено `[]`, ожидался `local_dns_resolver`.
  Дефект сборки (п. 2 «Проблемы»).
- `group_empty_after_prune_dropped` — получено
  `[{"type":"group","tag":"shield","servers":[],"mode":"fastest"}]`,
  ожидалось `[]`. Не дефект: по решению владельца §312 №3 группа, опустевшая
  от выключенных или неизвестных членов, эмитится пустой, и валидатор
  (`EmptyDnsGroup`, fatal) блокирует сборку до решения пользователя, а не
  деградирует втихую; сама выпадает только от висячего `detour` членов
  (§443). В живом состоянии выключенный член группы до сборки не доходит —
  его включает загрузка (§695 правило 5).

## Решение

1. `dnsServerRefEmitted(required:)` (`post_steps/dns_servers.dart`):
   `resolveDnsServersBodies` передаёт `true` для `DnsServerTemplate`, у
   обёртки которого в шаблоне `required: true` — как у лаунчера
   (`resolve_dns.go`: `required` → `enabled = true` для записи каталога).
   Превью вкладки DNS не трогали: в нашем шаблоне таких серверов нет.
2. Раннер `dns_corpus_test.dart`, файл — в `kKnownCorpusGatedSuites`
   (`test/contract_paths.dart`). `group_empty_after_prune_dropped` — в
   `_pendingCases` с причиной; расхождение передано лаунчеру.

## Файлы

- `app/lib/services/builder/post_steps/dns_servers.dart` — п. 1.
- `app/test/contract/dns_corpus_test.dart`, `app/test/contract_paths.dart` — п. 2.

## Проверка

`flutter test test/contract/dns_corpus_test.dart`: до правки п. 1 —
8 пройдено, 1 упало (`required_ignores_state`), 1 пропущен; после — 9
пройдено, 1 пропущен. Без пропуска `group_empty_after_prune_dropped` падает
с телом пустой группы (см. «Диагностика»). `flutter analyze` — без замечаний.

## Итог

31.10.2026: раннер `corpus/dns` гоняет весь каталог; `group_prunes_hosts` и
`group_hosts_all_dropped` проходят без правок кода (модель чистки `hosts`
сторон совпала, §140). `required` шаблонного сервера сборка теперь
эмитит. Расхождение по пустой группе оставлено (решение §312), лаунчеру
сообщено.
