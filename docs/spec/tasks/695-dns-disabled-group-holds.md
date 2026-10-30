# 695 — выключенная DNS-группа не держит членов; висячий `domain_resolver` виден в UI

| Поле | Значение |
|------|----------|
| Статус | Done (эмулятор проверен 30.10.2026, оба сценария PASS) |
| Дата начала | 2026-10-30 |
| Источник | issue #182 (@paratroop3r): после 2.25.17 члены Shield нельзя ни выключить, ни удалить, выключение самой группы Shield лок не снимает; решение владельца — выключенная группа никого не держит, лок пикеров (DNS Final / Default Domain Resolver) остаётся как есть, пустую группу включать нельзя, висячий `domain_resolver` показывать в UI |
| Связанные | §680 (локи «used by» по списку, п. 4 «лок не зависит от `enabled` ссылающегося сервера — оставлено» — отменяется этой задачей), §681 (`dns_server_holds.dart`, общий расчёт для вкладки и импорта), §312/§671 (фильтр членов группы в сборке и превью состава), §419 (heal `dns.final` / `default_domain_resolver`), §680 heal `domain_resolver` (`heal_dangling_dns_server_resolver.dart`), §682 (⚠ у Default Domain Resolver — образец подписи) |

## Проблема

Лок «used by Shield DNS» на члене группы (`dnsServerListHolds`,
`app/lib/services/dns/dns_server_holds.dart`) считается по наличию группы в
списке, тумблер группы не учитывается (§680 п. 4). Состав шаблонной группы
`dns_shield` зашит в `wizard_template.json` без vars, убрать из него один
сервер нельзя. Удалить саму группу нельзя, пока DNS Final и Default Domain
Resolver указывают на неё (оба дефолта = `dns_shield`), и это правильно:
то, что выбрано в пикерах, не выключается и не удаляется.

Итог у автора issue: Shield выключен (запись `enabled:false` приехала из
версии до §680, где такого лока не было), все шесть членов заперты, тумблер
Shield заперт во «выкл» только в одну сторону (включить можно). Выход
«переставить пикеры → удалить Shield → удалить члены» есть, но пользователь
его не видит, а удалять Shield он и не хотел.

Сборка при этом выпавших членов терпит: пост-проход §312
(`_filterDnsGroupMembers`, `post_steps/dns_servers.dart`) выкидывает из
группы неизвестные и выключенные теги с предупреждением; группа без членов
даёт фатальный `EmptyDnsGroup` (validator). Висячий `domain_resolver`
снимает heal §680, висячие `dns.final` / `default_domain_resolver` лечит
heal §419 (подставляет дефолт шаблона `dns_shield` и эмитит его
принудительно, даже выключенный). Локи — чисто UI-гигиена.

Вторая дыра: сервер, чей `domain_resolver` указывает на удалённый тег
(`safe_dns_dot` → `google_udp`), в UI выглядит здоровым. В редакторе
выпадашка «Domain resolver» молча дорисовывает пропавший тег как пункт
(`template_var_list.dart:263`), в списке ничего не видно; что сборка снимет
ключ и ядро пойдёт через Default Domain Resolver, пользователь не узнаёт.

## Решение

### 1. Выключенная запись никого не держит (вкладка DNS)

`dnsServerListHolds` получает `enabled` у каждой записи. Ссылки
`group:<tag>` и `server:<tag>` (`domain_resolver`) считаются только от
**включённых** записей списка. `dnsFinal` / `defaultResolver` — без
изменений: держат всегда. Запись с `forceIncluded` (пресет / правило с
DNS-опцией) считается включённой — сборка её эмитит.

Следствия для `ResolvedServer.locked` и всего, что на нём висит (тумблер
тайла, тумблер Params, `canDeleteDnsServer`, пункт Delete в long-press):

- Shield выключен → у `google_doh` и остальных членов лока нет: тумблер
  свободен, Delete доступен.
- Shield включён → как сейчас: члены залочены, подпись «used by Shield DNS».
- Shield с пикерами на нём, выключенный (состояние автора issue): включить
  можно (как сейчас), после этого члены залочены — приведение к
  консистентному состоянию, по слову владельца.
- `safe_dns_dot` выключен → `google_udp` свободен; включённый — держит,
  как сейчас.

Исключение — **последний член**. Группу с пикерами на ней сборка эмитит
принудительно (heal §419) даже выключенную, а пустая группа = фатальный
`EmptyDnsGroup`. Поэтому у выключенной группы, на которую ссылаются
`dnsFinal` / `defaultResolver`, последний член, который есть в списке и
включён (или `forceIncluded`), держится с подписью «used by Shield DNS
(last member)»: тумблер заперт во
«вкл», Delete недоступен. Выключенная группа без ссылок из пикеров членов
не держит вовсе (сборка её не эмитит, пустая не страшна).

`dnsServerFirstHolds` (импорт LX-бэкапа, §681, контракт 1.1.135) **не
меняется**: там `group:<tag>` держится по наличию в списке файла, это
норма контракта, лаунчер считает так же. В doc-комменте `dnsServerListHolds`
зафиксировать расхождение явно.

### 2. Включить пустую группу нельзя

Тумблер группы (тайл `merged_server_tile.dart`, Params редактора
`params_tab.dart`): группа выключена, и среди её `servers[]` нет ни одного
тега, который есть в списке и при этом включён или `forceIncluded`
(выключенных членов §312 из группы выкидывает) → тап по тумблеру даёт
SnackBar «No members left in the list. Enable or add a member first.»
вместо переключения. Образец — SnackBar «Locked: used by …». Групп это
касается любых (template и inline).

Счётчик в подтитуле тайла группы «dns_shield · group · fastest · 6»
(`merged_server_tile.dart`, `groupInfo`) считает членов, которые реально
есть в списке (по тегам записей, независимо от `enabled`), а не длину
`servers[]` из тела: у шаблонной группы тело всегда показывает 6.

### 3. Висячий `domain_resolver` виден

Расчёт один, рядом с `dnsServerListRefs` (`dns_server_resolver.dart`):
для каждой записи цель `domain_resolver` (строка или `{server}`, у template
после подстановки vars, как в `dnsServerListHolds`) сравнивается с тегами
списка; тега нет → у записи поле `danglingResolver: String` (тег).
`ResolvedServer` получает это поле.

- **Тайл** (`merged_server_tile.dart`): под подтитулом строка с ⚠
  «Domain resolver "google_udp" is not in the list — Default Domain
  Resolver will be used», стиль как у подписи 🔒 и у ⚠ §682.
- **Редактор, Params** (`template_var_list.dart`, `case 'dns_servers'`):
  пункт-призрак остаётся выбранным (dropdown без совпавшего значения
  падает), но подписан «google_udp (not in list)»; под полем ⚠ «This
  server is not in the list — Default Domain Resolver will be used. Pick
  another server to resolve the hostname directly.» Выбор другого пункта
  снимает и пометку, и ⚠. Inline-сервер с `domain_resolver` в JSON — та же
  строка ⚠ в тайле; в редакторе JSON-вкладка без подсказки (тело
  редактируется руками).

Сборка не меняется: heal §680 снимает ключ как сейчас.

### Макеты (стиль §680)

Shield выключен, `google_udp` удалён, `safe_dns_dot` включён:

```
DNS Servers                                          [+]
┌──────────────────────────────────────────────────────┐
│ [on ] Google DoH                          [Template] │
│       google_doh · https · 8.8.8.8                   │   ← Shield выключен: лока нет,
├──────────────────────────────────────────────────────┤     тумблер свободен, long-press → Delete
│ [on ] Safe DNS (DoT)                      [Template] │
│       safe_dns_dot · tls · dns.adguard-dns.com       │
│       ⚠ Domain resolver "google_udp" is not in the   │   ← п. 3
│         list — Default Domain Resolver will be used  │
├──────────────────────────────────────────────────────┤
│ [off] Shield DNS (multi-provider group)   [Template] │   ← выключен до 2.25.17
│       dns_shield · group · fastest · 5               │   ← счётчик по списку (было 6)
│       🔒 used by DNS Final, Default Domain Resolver  │   ← лок пикеров как есть; включить можно
└──────────────────────────────────────────────────────┘
```

Остался один член, Shield выключен, пикеры на нём:

```
┌──────────────────────────────────────────────────────┐
│ [on ] Google DoH                          [Template] │
│       google_doh · https · 8.8.8.8                   │
│       🔒 used by Shield DNS (last member)            │   ← п. 1, исключение
├──────────────────────────────────────────────────────┤
│ [off] Shield DNS (multi-provider group)   [Template] │
│       dns_shield · group · fastest · 1               │
│       🔒 used by DNS Final, Default Domain Resolver  │
└──────────────────────────────────────────────────────┘
```

Пустая группа (без ссылок из пикеров, inline или Shield после переставленных
пикеров), тап по тумблеру:

```
┌──────────────────────────────────────────────────────┐
│ [off] My group                                [User] │
│       my_group · group · fastest · 0                 │
└──────────────────────────────────────────────────────┘
 ╭────────────────────────────────────────────────────╮
 │ No members left in the list. Enable or add a       │   ← SnackBar вместо переключения
 │ member first.                                      │
 ╰────────────────────────────────────────────────────╯
```

Редактор `safe_dns_dot`, Params:

```
←  Edit DNS Server                        ↺   🗑   💾
   [ Params ] [ JSON ]
──────────────────────────────────────────────────────
  Description        Safe DNS (DoT)
  Enabled            [on ]

  Safe profile       dns.adguard-dns.com            ▾
  Domain resolver    google_udp (not in list)       ▾
  ⚠ This server is not in the list — Default Domain
    Resolver will be used. Pick another server to
    resolve the hostname directly.
  Outbound           direct                         ▾
```

### Файлы

- `app/lib/services/dns/dns_server_holds.dart` — `enabled` в записи,
  фильтр по включённым, исключение «last member», doc-коммент про импорт.
- `app/lib/screens/dns_settings_screen/dns_server_resolver.dart` —
  `dnsServerListRefs` передаёт `enabled`/`forceIncluded`, подпись «(last
  member)», расчёт `danglingResolver`.
- `app/lib/screens/dns_settings_screen/resolved_server.dart` — поле
  `danglingResolver`.
- `app/lib/screens/dns_settings_screen/widgets/merged_server_tile.dart` —
  счётчик членов по списку, SnackBar пустой группы, строка ⚠.
- `app/lib/screens/dns_server_edit/tabs/params_tab.dart` — SnackBar
  пустой группы у тумблера Enabled.
- `app/lib/widgets/template_var_list.dart` — пометка «(not in list)» и ⚠
  у `dns_servers`.
- `app/assets/l10n/ru/ui.json`, `zh/ui.json` — новые строки (ключ =
  английский текст, `docs/l10n.md`).
- `docs/spec/tasks/680-*.md` — п. 4 раздела «Локи»: пометка «отменено §695».
- `CHANGELOG.md` Unreleased: Fixed, со ссылкой на #182.

## Риски и граничные случаи

- Группа выключена, член удалён, группу включили: сборка §312 ужмёт состав
  с предупреждением, ядро стартует. Удалены все члены → включить нельзя
  (п. 2); у группы под пикерами последний член не удаляется (п. 1).
- Вложенные группы: член-группа считается как любой член; «последний член»
  — последний тег `servers[]`, присутствующий в списке и включённый.
- `forceIncluded` член (сервер пресета под тем же тегом) считается
  включённым и держит/считается всегда.
- Импорт бэкапа (§681) по-прежнему держит члены по наличию группы в файле
  — расхождение с вкладкой осознанное, контракт не трогаем.
- `resolverDetourTag` (`dns_server_resolver.dart:340`, ⚠ §682 у Default
  Domain Resolver) уже учитывает `enabled` членов — не трогать.

## Проверка

Тесты — только затронутые файлы, по одному, в Sonnet-субагенте:

- `app/test/screens/dns_settings_screen/resolved_server_locks_test.dart`
  (или новый `disabled_group_holds_test.dart`): выключенная группа не
  держит; включённая держит; последний член под пикерами держится с
  подписью; выключенный `safe_dns_dot` не держит `google_udp`.
- `app/test/screens/dns_settings_screen/locked_switch_test.dart`: SnackBar
  пустой группы; счётчик членов по списку; строка ⚠ у `danglingResolver`.
- Тест `dnsServerFirstHolds` (§681, `app/test/…backup…`) — не меняется и
  зелёный.
- Эмулятор, сценарий автора: установка с выключенным Shield и пикерами
  на нём → члены свободны → удалить пять → шестой залочен «(last member)»
  → включить Shield → лок на всех → Start, ядро стартует. Второй: удалить
  `google_udp` при выключенном `safe_dns_dot` → включить `safe_dns_dot` → ⚠
  в тайле и редакторе → Start, конфиг без `domain_resolver`, предупреждение
  сборки.

## Итог

Сделано (не закоммичено, эмулятор не гоняли):

- `dns_server_holds.dart`: запись `dnsServerListHolds` несёт `enabled`;
  `group:` и `server:` (`domain_resolver`) — только от включённых;
  `DnsServerHold.lastMember` (на `usedBy` не влияет) у последнего живого
  члена выключенной группы под `dnsFinal` / `defaultResolver`.
  `dnsServerFirstHolds` передаёт все записи с `enabled: true` — семантика
  импорта прежняя, расхождение записано в doc-комменте.
- `dns_server_resolver.dart`: `dnsServerListRefs` передаёт
  `enabled || forceIncluded`, подпись «%s (last member)» (параметр
  `lastMemberLabel`, вкладка передаёт локализованную); `dnsDanglingResolver`
  и счётчики членов групп по списку в `resolveDisplayedServers`.
- `ResolvedServer`: `danglingResolver`, `groupMembersInList`,
  `groupLiveMembers`, `isGroup`, `enableBlockedEmptyGroup`;
  `withUsedByList` заменён на `withListState`.
- Тайл: счётчик членов по списку, SnackBar пустой группы, строка ⚠.
  Params: SnackBar пустой группы у Enabled; `TemplateVarListView` получил
  `notInListDnsTags` — призрак «%s (not in list)» и ⚠ под полем.
- Строки ru/zh; §680 «Решения владельца» п. 4 помечен «отменено §695»;
  CHANGELOG Unreleased → Fixed.
- Тесты: `resolved_server_locks_test.dart` (16 зелёных; старый кейс
  «выключенный safe_dns_dot держит google_udp» переписан под новую
  семантику), `locked_switch_test.dart` (7), `dns_backup_merge_test.dart`
  (§681, 29, без правок), `edit_controller_test.dart`,
  `template_var_list_test.dart` — зелёные. `hardcoded_check`, `ui_check`
  — 0/0.

Отклонения и толкования:

- «Последний член» = единственный живой (в списке и включён или
  `forceIncluded`) член выключенной группы под пикером; при двух и более
  живых членах все свободны. Так у автора issue «члены свободны → удалить
  пять → шестой залочен».
- Пункт 4 «Локи» из §680 найден в разделе «Решения владельца» (п. 4) —
  пометка поставлена там.
- Проверка пустой группы в Params идёт по сохранённому состоянию
  (`resolved`), правка `servers[]` в редакторе до сохранения не учитывается.


Эмулятор (30.10.2026, APK 2.25.18-dev.5 из afc8ba16, оба сценария PASS;
скриншоты в scratchpad сессии):

- **Посылка спеки про heal §419 неверна.** Выключенная template-группа в
  конфиг не попадает (§680), поэтому heal §419 не «эмитит `dns_shield`
  принудительно», а переставляет `dns.final` / `default_domain_resolver` на
  первый пригодный эмитированный сервер (на стенде `ru-direct:dns_ru`) и
  персистит var: лог «route.default_domain_resolver reset to
  "ru-direct:dns_ru": DNS server "dns_shield" is gone». Для состояния
  автора это значит: при первом же старте после обновления пикеры сами
  уходят с выключенного Shield, лок пикеров с него снимается, члены
  свободны. Исключение «(last member)» живёт только в окне до пересборки
  (на стенде воспроизведено через `PUT /settings/config_locked`); оставлено
  как страховка, код не меняли. Ядро с группой из одного члена стартует.
- Подпись лока — description группы целиком: «used by Shield DNS
  (multi-provider group) (last member)», как и у прочих локов по списку.
- Сценарий 2: `domain_resolver` у `safe_dns_dot` по умолчанию `google_doh`
  (§684), не `google_udp`; висячим на стенде стал `google_doh`. Строка ⚠
  видна и у выключенного `safe_dns_dot`. Конфиг без ключа, предупреждение
  сборки «DNS server 'safe_dns_dot': domain_resolver 'google_doh' dropped
  (not in list)», ядро стартует.
