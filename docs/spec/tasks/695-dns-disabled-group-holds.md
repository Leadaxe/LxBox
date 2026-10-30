# 695 — DNS-серверы: шаблонные записи редактируемы, ссылки только на включённое, ссылка держит (issue #182)

| Поле | Значение |
|------|----------|
| Статус | In progress (итерация 3; итерации 1–2 ниже в «Истории» откатываются этой же задачей) |
| Дата начала | 2026-10-30 |
| Источник | issue #182 (@paratroop3r): после 2.25.17 из Shield DNS нельзя убрать лишний сервер, его члены нельзя выключить и удалить, выключение Shield ничего не меняет. Решения владельца 30.10.2026 — модель из шести правил ниже |
| Связанные | §680 (каталог, локи «used by» по списку — остаются как были), §117 (override: inline-запись с тегом шаблона; force-include серверов пресетов и правил — не трогаем), §312 (форма состава inline-группы, фильтр членов в сборке), §419 (heal битых пикеров — остаётся для настоящего dangling), §681 (бэкап: `used_by`, template_catalog), §682 (⚠ резолвер через туннель, Duplicate), §684 (`safe_dns_dot.dom_resolver` = `google_doh`) |

## Проблема

Состав шаблонной группы `dns_shield` зашит в `wizard_template.json`, в
редакторе шаблонной записи редактируются только vars, тело read-only. Член
группы залочен, пока он в составе (§680). Удалить Shield нельзя, пока на
него указывают DNS Final / Default Domain Resolver (и это правильно). Итог:
пользователь не может убрать из Shield ни один сервер.

Попутно у обновившихся с версий до 2.25.17 бывает состояние «Shield
выключен, но выбран в пикерах»: в новом UI его не создать, а сборка в нём
молча переставляет оба пикера на первый пригодный сервер (heal §419) и
сохраняет это.

Итерации 1–2 этой задачи (см. «История») решали не то: ослабляли локи от
выключенной группы и форсировали пикеры в сборке, из-за чего тумблер в UI
расходился с флагом в хранилище. Откатываются здесь же.

## Модель (решения владельца)

1. **Шаблонные серверы и группы редактируемы.** В редакторе шаблонной
   записи на Params, под vars, та же форма тела, что у inline
   (`ServerFormSection`: у группы — состав/режим, у сервера — адрес, порт,
   path/SNI, `domain_resolver`, detour). Save при изменённом теле пишет
   **inline-запись с тем же тегом** (override, §117: бейдж «Overridden»,
   сборка берёт её тело, ссылки и пикеры по тегу не ломаются). Тело
   override = тело шаблона после подстановки vars + правки формы; vars у
   override больше нет. В редакторе override — кнопка **«Reset to
   template»** (пункт ⋮ рядом с Duplicate §682): запись снова становится
   `template` с тем же тегом, `enabled` и description сохраняются, vars —
   дефолты шаблона. Подтверждение не нужно.
2. **Выключенное нельзя выбрать.** Пикеры DNS Final, Default Domain
   Resolver, var `dns_servers` (`domain_resolver`), пикер членов группы
   предлагают только включённые записи списка (`enabledServerTags` по
   `enabled`, без исключения `forceIncluded`; у members — то же). Уже
   выбранное выключенным быть не может по правилу 3; старое состояние
   лечит правило 5.
3. **На что есть ссылка, то нельзя выключить и удалить.** Ссылки: член
   группы, `domain_resolver` другого сервера, DNS Final, Default Domain
   Resolver, пресет, правило с DNS-опцией. Независимо от того, включена
   ли ссылающаяся запись. Это §680 как было: `dnsServerListHolds` без
   учёта `enabled`.
4. **Добавление из каталога тянет зависимости по цепочке.** (+) → «Add
   DNS server» / «Add all defaults»: вместе с выбранной записью в список
   добавляются (включёнными, из каталога) её члены (группа, рекурсивно) и
   цель `domain_resolver` (после подстановки дефолтов vars), если их в
   списке нет. Запись о добавленных по цепочке — SnackBar «Also added: …».
   Висячих ссылок после этого не бывает.
5. **Нормализация старого состояния.** В `resolveDnsServersList`
   (`post_steps/dns_servers.dart`, уже чистит сирот, сеет каталог и
   сохраняет список при изменении) новый шаг: всякая запись, на которую
   есть ссылка по правилу 3 (включая пикеры — их значения приходят
   параметрами), получает `enabled: true`; изменение сохраняется, в лог
   приложения строка «DNS server "X" enabled: referenced by …». Выполняется
   на каждой загрузке, но меняет что-то только у старого состояния.
6. **Сборка ничего не форсирует ради пикеров.** Heal §419 остаётся для
   настоящего dangling (тега нет в списке вовсе). Force-include пресетов и
   правил (§117) не трогаем — это отдельный вопрос.

Остаются из итераций 1–2: тап по тумблеру выключенной группы, у которой в
списке нет ни одного члена, даёт SnackBar «No members left in the list.
Enable or add a member first.»; счётчик членов в тайле группы — по
записям списка.

## Что откатить (итерации 1–2, уже в develop)

- Сборка: `dnsServerRefEmitted(resolverReferenced:)`, параметр
  `resolverReferencedTags` в `resolveDnsServersBodies`, чтение пикеров в
  `applyCustomDns` (`post_steps/dns_rules.dart`). Функцию раскрытия группы
  `dnsResolverForcedTags` переименовать и использовать для правила 4
  (замыкание зависимостей) — или снести, если удобнее написать заново.
- UI: `ResolvedServer.usedByResolver` и его вклад в `forceIncluded`;
  `enabled` в записях `dnsServerListHolds` (вернуть лок от любой записи);
  `danglingResolver`, строка ⚠ в тайле, `notInListDnsTags` и пометка
  «(not in list)» в `template_var_list.dart`, их строки ru/zh и тесты.
- Текст предупреждения §419 «is not in the list» — оставить.

## Макеты (стиль §680)

Редактор Shield (шаблонная группа), Params:

```
←  Edit DNS Server                   ↺   ⋮   🗑   💾   ← ⋮: Duplicate, Reset to template (у override)
   [ Params ] [ JSON ]
──────────────────────────────────────────────────────
  Description        Shield DNS (multi-provider group)
  Enabled            [on ]
  ─────────────────────────────────────────────────
  GROUP
  Mode               fastest                        ▾
  Members                                           ← форма §312, как у inline-группы
    [✓] Google DoH            google_doh
    [✓] Google DoT            google_dot
    [ ] Cloudflare DoT        cloudflare_dot          ← снял галку: после Save он свободен
    [✓] OpenDNS DoH           opendns_doh
    [✓] Quad9 DoH             quad9_doh
    [✓] Yandex DoT            yandex_dot
                                                     ← выключенных записей в пикере нет (правило 2)
```

Вкладка DNS после Save:

```
│ [on ] Shield DNS (multi-provider group) [Overridden] │   ← inline с тегом dns_shield
│       dns_shield · group · fastest · 5               │
│       🔒 used by DNS Final, Default Domain Resolver  │
├──────────────────────────────────────────────────────┤
│ [on ] Cloudflare DoT                      [Template] │   ← ссылок нет: тумблер и Delete свободны
│       cloudflare_dot · tls · 1.1.1.1                 │
```

Каталог, (+) → «Safe DNS (DoT)» при отсутствующем `google_doh`:

```
 ╭────────────────────────────────────────────────────╮
 │ Also added: Google DoH (domain resolver)           │   ← правило 4
 ╰────────────────────────────────────────────────────╯
```

## Файлы

- `app/lib/screens/dns_server_edit/edit_controller.dart`, `tabs/params_tab.dart`,
  `sections/server_form_section.dart` — форма тела у template, snapshot →
  inline при изменённом теле, Reset to template.
- `app/lib/screens/dns_settings_screen/dns_server_resolver.dart` —
  `enabledServerTags` только по `enabled`; откат `danglingResolver`.
- `app/lib/screens/dns_settings_screen/dns_server_catalog_screen.dart`,
  `dns_settings_tab.dart` (`onAdd`) — замыкание зависимостей, SnackBar.
- `app/lib/services/dns/dns_server_holds.dart` — откат `enabled`.
- `app/lib/services/builder/post_steps/dns_servers.dart` — откат
  force-include; шаг нормализации в `resolveDnsServersList` (пикеры
  параметрами; вызывающие: сборка и вкладка DNS).
- `app/lib/services/builder/post_steps/dns_rules.dart` — откат чтения пикеров.
- `app/lib/widgets/template_var_list.dart` — откат «(not in list)».
- `app/assets/l10n/ru/ui.json`, `zh/ui.json` — новые строки («Reset to
  template», «Also added: %s», «DNS server …»), снять откаченные.
- `docs/spec/tasks/680-dns-servers-catalog-seed-once.md` — пометку
  «отменено §695» у п. 4 снять (правило 3 = §680 как было); `docs/STORAGE.md`
  — override у `dns.servers` (inline с тегом шаблона) одной строкой, если
  не описан; `CHANGELOG.md` Unreleased → Fixed: одна запись §695 переписать
  под модель.

## Риски и граничные случаи

- Бэкап §681: inline-override с тегом шаблона при экспорте/импорте —
  обычная inline-запись (`kind: inline`); правило снятия template-записей
  по `template_catalog` её не касается (вид не template). Тест
  `dns_backup_merge_test.dart` + кейс: override `dns_shield` переживает
  импорт, не задваивается с template-записью файла (тег один — побеждает
  локальная, как у слияния).
- Override Shield перестаёт получать изменения состава из будущих версий
  шаблона — по модели §680 «список принадлежит пользователю»; Reset to
  template возвращает.
- Правило 3 + правило 1: убрать последнего члена из состава группы в форме
  нельзя (форма §312 требует ≥ 1, проверить); пустая группа всё равно
  ловится валидатором `EmptyDnsGroup`.
- Правило 5 и пресеты: сервер пресета, выбранный в пикере, уже
  force-included; нормализация ставит ему `enabled:true` — безвредно.
- Правило 4 и ссылки на серверы пресетов (`ru-direct:yandex_udp`): в
  каталоге их нет, цепочка их не добавляет; ссылка на отсутствующий сервер
  пресета — как раньше (heal §419 / §680).
- Launcher: формат записи не меняется (inline с тегом — уже в контракте).

## Проверка

Тесты — только затронутые файлы по одному, Sonnet-субагентом:
`resolved_server_locks_test.dart` (лок от выключенной группы снова держит;
override виден как inline/Overridden), `locked_switch_test.dart`,
`dns_group_test.dart` (откат force-include; нормализация правила 5),
`edit_controller_test.dart` (template → inline при правке тела; Reset to
template), `dns_server_catalog_screen_test.dart` (цепочка правила 4),
`dns_backup_merge_test.dart`, `dns_servers_resolver_test.dart`
(`enabledServerTags`).

Эмулятор:
1. Состояние автора (хранилище: `dns_shield` `enabled:false`, пикеры на
   нём): после старта в хранилище у `dns_shield` `enabled:true`, пикеры не
   тронуты, в логе строка нормализации, в `/config` группа с шестью членами.
2. Редактор Shield → Params: форма состава; снять `cloudflare_dot` → Save →
   в списке Shield «Overridden», счётчик 5; `cloudflare_dot` без лока —
   выключить, удалить. `/config`: группа из пяти. Start → connected.
3. Редактор Shield → Reset to template → запись снова Template, счётчик 6,
   `cloudflare_dot` в списке отсутствует → лок у членов как у шаблона.
4. Пикер Default Domain Resolver не показывает выключенные записи.
5. Удалить `google_doh` (когда ссылок нет) → (+) → Safe DNS (DoT) →
   SnackBar «Also added: Google DoH …», обе записи в списке, `google_doh`
   залочен «used by Safe DNS (DoT)».

## История

- **Итерация 1 (30.10, afc8ba16 + 04758de3):** выключенная группа /
  сервер с `domain_resolver` не держат членов; «(last member)» под
  пикерами; пустую группу не включить; висячий `domain_resolver` с ⚠.
  Эмулятор 2/2. Откатывается кроме пустой группы и счётчика.
- **Итерация 2 (30.10, d65008cd + 104d987d, спека 696 удалена):** пикеры
  = force-include в сборке, группа тянет членов. Эмулятор 6/6. Откатывается
  целиком: тумблер в UI расходился с флагом в хранилище, а состав Shield
  по-прежнему нельзя было править.
- **Итерация 3:** модель из шести правил выше.

## Итог

Заполняется исполнителем.
