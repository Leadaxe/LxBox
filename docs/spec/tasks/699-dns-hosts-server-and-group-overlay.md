# 699 — DNS: сервер `hosts` в форме и слой `hosts` у группы (issue #185)

| Поле | Значение |
|------|----------|
| Статус | Draft — на согласовании у владельца |
| Дата начала | 2026-10-31 |
| Источник | issue #185 (@paratroop3r): свой WireGuard-сервер и WARP с адресами IPv4 + IPv6 под одним локальным именем, семейство выбирает `strategy`. Решение владельца 31.10.2026: «нужен интерфейс под hosts и возможность встраивать его в группы» |
| Ядро | sing-box-lx SPEC 143 (issue Leadaxe/sing-box-lx#60): ключ `hosts` у DNS-группы. Код b3cdb00dd на локальной `lx`, тега нет; рабочее имя релиза v1.14.4-lx.26 |
| Связанные | §312 (форма состава группы), §680 (каталог, локи «used by»), §683 (Fixed IP в правиле — до адресов серверов не доходит), §684, §695 (ссылка держит, выбрать можно только включённое, override шаблонных записей), §384 (`hosts`/`fakeip` не резолвер по умолчанию) |

## Проблема

Адрес сервера узла ядро резолвит через `domain_resolver` (узла или
`route.default_domain_resolver`). Этот путь идёт в DNS-сервер напрямую и
DNS-правила не проходит (`Router.Lookup`, ветка `options.Transport != nil`).
Поэтому Fixed IP из §683 (`action: predefined` в правиле) на адреса серверов
не действует.

Сервер `hosts` сам резолвером по умолчанию быть не может: на любое имя не из
списка он отвечает NXDOMAIN, и остальные узлы перестают резолвиться (§384,
ядро тоже запрещает). Завести `hosts` у нас можно только через вкладку JSON
редактора DNS-сервера; в форме такого типа нет.

## Ядро (SPEC 143, что приходит)

- У группы новый необязательный ключ `hosts`: список тегов серверов типа
  `hosts`. Это **не** элемент `servers`. Пустой `[]` = ключа нет.
- Группа сначала спрашивает серверы из `hosts` по порядку ключа. Имя есть в
  списке — ответ отдаётся сразу (запись только с IPv4 на запрос AAAA даёт
  пустой ответ, в сеть запрос не уходит). Имени нет или тип запроса не A/AAAA —
  запрос идёт членам `servers` по режиму группы, как раньше.
- `servers` обязателен и непуст. `hosts`/`fakeip` внутри `servers` — по-прежнему
  ошибка старта.
- В `hosts` только теги серверов типа `hosts`, без дубликатов, не тег самой
  группы и не тег из её `servers`. Иначе ошибка старта.
- Порядок в `hosts` значим: отвечает первый, кто знает имя.
- На ядре lx.25 и старше ключ `hosts` = `unknown field` на старте.

Итоговая схема для автора issue: сервер `hosts` с именами `wg.home` и
`warp.lan` → поставить его в Hosts группы, которая стоит в Default Domain
Resolver (например, override Shield §695) → в узле адрес `wg.home`.

## Модель

1. **Тип `hosts` в форме DNS-сервера.** Режим `hosts` в выборе Mode (рядом с
   `group`, `tailscale`). Режим безадресный: нет address/port/path/SNI,
   `domain_resolver`, detour. При входе в режим из тела снимаются ключи
   транспорта (как при входе в `group`), ставится `predefined: {}`; при выходе
   снимаются `predefined` и `path`.
2. **Записи `hosts` — список строк + диалог.** Каждая строка: имя, под ним
   адреса через запятую, ✕ справа — удалить. Тап по строке и «+ Add host» —
   диалог: Name и Addresses (по адресу в строке, как поле Fixed IP §683).
   Проверки диалога: имя непустое, без пробелов, `://`, `/` и `:`; имени ещё
   нет в списке; каждая строка адресов — IPv4 или IPv6 (`RuleDns.ipRecordType`,
   тексты ошибок Fixed IP: «Line %d: not an IPv4 or IPv6 address», «Enter an
   IP address»). Тело: `predefined: {имя: [адреса]}`; читается и строка, и
   список (у ядра Listable). Имена приводятся к нижнему регистру.
3. **`path` формой не редактируется.** Есть в теле — под списком строка
   «Also reads: <пути>» (правка на вкладке JSON). Без `path` ядро читает
   системный `/etc/hosts` (на Android — `localhost`, `ip6-localhost`); это
   поведение ядра, не меняем.
4. **Save сервера `hosts`** заблокирован, пока нет ни одной записи и нет
   `path`: «Add at least one host» (как «группа без членов не сохраняется» §695).
5. **Hosts в форме группы.** Под Members — блок **Hosts**: `CheckboxListTile`
   по каждому включённому серверу типа `hosts` из списка (вид — как Members
   §695: имя, тег справа). Выключенные не предлагаются (правило 2 §695).
   Отмеченные пишутся в ключ `hosts` **в порядке списка DNS-серверов**.
   Подпись под блоком: «Names these servers know are answered first; other
   names go to the members.» Серверов `hosts` в списке нет — вместо галок
   строка «No hosts servers in the list.» Members по-прежнему без `hosts`/`fakeip`.
   При выходе из режима `group` снимается и `hosts`.
6. **Ссылка держит.** `hosts` группы — ссылка по правилу 3 §695: сервер нельзя
   выключить и удалить, в тайле «used by <группа>»; нормализация старого
   состояния (правило 5 §695) включает его. В бэкапе `used_by` = `group:<tag>`,
   как у члена (словарь контракта не расширяется).
7. **Переименование тега** переписывает ссылки в `hosts` групп. Попутно —
   и в `servers` групп: сейчас переименованный член молча выпадает из группы
   при сборке с предупреждением «unknown» (дефект той же ветки кода).
8. **Сборка.** Ключ `hosts` группы чистится так же, как `servers` (§312):
   остаются теги, которые эмитированы, включены, имеют тип `hosts`, без
   дубликатов, не сама группа и не член её `servers`; выпавшие — предупреждение
   на каждый. Пустой список — ключ снимается. `detour` у сервера `hosts`
   снимается (`normalizeDnsDetour`, как у `group`/`tailscale`): у ядра у `hosts`
   нет dial-полей, и `detour` из JSON сейчас роняет старт.
9. **Гейт ядра.** Ядро ниже `1.14.4-lx.26-rc.1` — ключ `hosts` у групп
   снимается целиком с предупреждением «DNS group "X": hosts need core
   1.14.4-lx.26 or newer». Версия неизвестна — эмитится (как гейт цепочек
   `coreSupportsChain`). Гейт остаётся и после бампа пина.
10. **Валидатор** повторяет правила ядра для `hosts` группы (после чистки
    сборки они не срабатывают; ловят сырой конфиг): тег не найден, тип не
    `hosts`, дубликат, тег группы, тег из `servers`. Существующие
    `BadDnsGroupMember` (hosts в `servers`) и `EmptyDnsGroup` не меняются.
11. **Пикеры DNS Final / Default Domain Resolver / `domain_resolver`** — без
    изменений: серверов `hosts` в них нет (§384), группа с ключом `hosts`
    там есть (это `group`).
12. **Тайлы списка.** Сервер `hosts`: `tag · hosts · N names` (`1 name`).
    Группа с непустым `hosts`: к подписи добавляется `· +hosts`.
13. **Бамп ядра** — отдельным коммитом этой задачи, когда выйдет тег:
    `libbox.version`, `kCoreBuildTagsPin`, `docs/KERNEL.md` (регламент бампа,
    javap списком). До тега фича в develop безопасна за гейтом п. 9.

## Макеты

Редактор, Mode = hosts:

```
←  Edit DNS Server                                 ⋮   🗑   💾
   [ Params ] [ JSON ]
──────────────────────────────────────────────────────────
  Description        Home names
  Tag                local_hosts
  Enabled            [on ]
  ───────────────────────────────────────────────────────
  Mode               hosts                              ▾
  HOSTS
    wg.home                                             ✕
    203.0.113.10, 2001:db8::10
    warp.lan                                            ✕
    162.159.192.1, 2606:4700:d0::a29f:c001
    + Add host
  Answers only these names. Put it under Hosts of a DNS
  group so that other names go to the group's servers.
```

Диалог строки:

```
 ╭ Host ──────────────────────────────────────╮
 │ Name        wg.home                        │
 │ Addresses   203.0.113.10                   │
 │             2001:db8::10                   │
 │             One IPv4 or IPv6 address per   │
 │             line                           │
 │                          Cancel      OK    │
 ╰────────────────────────────────────────────╯
```

Редактор группы (override Shield §695):

```
  GROUP
  Mode               fastest                            ▾
  Members
    [✓] Google DoH            google_doh
    [✓] Cloudflare DoT        cloudflare_dot
    …
  Hosts
    [✓] Home names            local_hosts
  Names these servers know are answered first; other
  names go to the members.
```

Вкладка DNS:

```
│ [on ] Shield DNS (multi-provider group) [Overridden] │
│       dns_shield · group · fastest · 5 · +hosts      │
│       🔒 used by DNS Final, Default Domain Resolver  │
├──────────────────────────────────────────────────────┤
│ [on ] Home names                                     │
│       local_hosts · hosts · 2 names                  │
│       🔒 used by Shield DNS                          │
```

## Файлы

- `app/lib/screens/dns_server_edit/edit_controller.dart` — режим `hosts`
  (`kDnsServerModes`, `kDnsAddresslessModes`, `setServerMode`), записи
  (геттер, add/edit/remove), `hosts` группы (геттер + toggle по порядку
  списка), гейт Save `hostsHasNoEntries`.
- `app/lib/screens/dns_server_edit/sections/server_form_section.dart` —
  Dropdown/SegmentedButton, секция HOSTS с диалогом, блок Hosts у группы.
- `app/lib/screens/dns_server_edit/tabs/params_tab.dart` — detour-пикер
  скрыт для `hosts`.
- `app/lib/screens/dns_server_edit_screen.dart` — параметр опций Hosts в
  `openDnsServerEditor`, гейт Save.
- `app/lib/screens/dns_settings_tab.dart` — опции Hosts (`_dnsHostsOptions`).
- `app/lib/screens/dns_settings_screen/widgets/merged_server_tile.dart` —
  подписи п. 12.
- `app/lib/screens/dns_settings_screen/dns_server_resolver.dart` —
  `renameDnsServerTagRefs`: `servers` и `hosts` групп.
- `app/lib/services/dns/dns_server_holds.dart` — `hosts` групп в
  `dnsServerListHolds` и `dnsServerFirstHolds` (вид `group`).
- `app/lib/services/builder/post_steps/dns_servers.dart` — чистка `hosts`
  групп, гейт ядра.
- `app/lib/services/builder/preset_expand.dart` — `normalizeDnsDetour`:
  `hosts`.
- `app/lib/services/builder/core_chain_capability.dart` —
  `kDnsGroupHostsMinCoreVersion`, `coreSupportsDnsGroupHosts`.
- `app/lib/services/builder/validator.dart`, `app/lib/models/validation.dart`
  — `BadDnsGroupHosts`.
- `app/assets/l10n/ru/ui.json`, `zh/ui.json` — новые строки.
- Тесты: `test/screens/dns_server_edit/edit_controller_test.dart`,
  `test/builder/dns_group_test.dart`, `test/builder/validator_test.dart`,
  `test/screens/dns_settings_screen/rename_refs_test.dart`,
  `test/screens/dns_settings_screen/resolved_server_locks_test.dart`.
- Доки: `docs/GUARDS.md` (чистка `hosts`, `detour` у `hosts`, гейт ядра),
  `CHANGELOG.md` Unreleased → Added.
- Контракт: запрос лаунчеру — корпус-кейс `corpus/dns/group_prunes_hosts`
  (чистка ключа `hosts` по п. 8), чтобы сборки сторон совпадали.

## Риски и граничные случаи

- **Без `path`** сервер `hosts` отвечает и на имена из системного `/etc/hosts`
  (`localhost`). Безвредно; в подписи не упоминаем.
- **A-only запись + `strategy: ipv6_only`** — пустой ответ и отказ подключения,
  как `/etc/hosts` ОС (SPEC 143 §2.1 п. 2). Не чиним.
- **Override шаблонной группы** (§695) несёт `hosts` в своём теле; «Reset to
  template» его снимает вместе с остальными правками.
- **Импорт бэкапа** на сторону с ядром без ключа — гейт п. 9 снимает ключ при
  сборке, старт не падает.
- **Пресеты** серверов `hosts` и ключа `hosts` не несут; `preset_expand`
  (`mapRef` только по `servers`) не трогаем.

## Проверка

- Юниты: режим `hosts` (вход/выход, ключи тела), диалог (имя, адреса, дубль),
  `hosts` группы по порядку списка; чистка `hosts` (выключен, не найден, не
  `hosts`, дубль, член `servers`, пустой → ключ снят); гейт ядра (lx.25 —
  снят, lx.26-rc.1 — есть, неизвестная версия — есть); валидатор;
  переименование (`servers` и `hosts`); лок «used by».
- Эмулятор (после бампа ядра): сервер `hosts` с `wg.home` → v4 + v6, группа
  `hosts` + DoH в Default Domain Resolver, ручной узел с адресом `wg.home`
  подключается; Diagnostics → URL Check показывает ответ `hosts` (стадия
  `dns_member` типа `hosts`); имя не из списка резолвится членами.

## Открытые вопросы (рекомендации)

1. Записи `hosts`: строки + диалог (рекомендую) или одно текстовое поле в
   формате hosts-файла (`IP имя` в строке).
2. Порядок ключа `hosts`: по порядку списка DNS-серверов (рекомендую) или
   ручная сортировка в редакторе группы.
3. Попутная правка переименования для `servers` групп (п. 7): делать
   (рекомендую) или отдельной задачей.
