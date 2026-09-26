# 570 — закрытие хвостов кампании §555–§568 (две волны: A движок/сборка, B UI/сводки)

| Поле | Значение |
|------|----------|
| Статус | Волна B выполнена (`task-570-b`, влита); волна A выполнена (`task-570-a`), ждёт влития и CI |
| Дата старта | 2026-09-26 |
| Дата завершения | — |
| Коммиты | Волна B: `8732229e` переменные и Home, `4ae15377` выбор члена, `ae072a52` свёртка в UI, `13f0c8b2` отбраковки, `aa8b18da` docs. Волна A: `74f74681` (п.2 UTF-8 и порядок форм), `711e09c0` (п.3 форма ini в движке), `b44661fa` (1.1.80 цепочка sni), `1d344d93` + `e9c1c837` (1.1.80 строка vpn://), `55efb7fb` (п.1 дельта тела), `06d566be` (п.4 сборка свёртки и коды 1.1.80), `b054db6a` + `7098a201` (п.6 сводка отбраковок), `8ae0ad9b` (п.5 DNS-серверы и строки пресетов), docs — следующий |
| Связанные spec'ы | §555, §556, §560, §561, §562, §563, §565, §566, §568 — секции «Нерешённое» |

## Проблема

Решение владельца 26.09.2026: недоделанных хвостов не оставлять. По задачам
кампании в «Нерешённое» накопились пункты, отложенные как «отдельно» или
«UI не менять молча». Всё, что не зависит от лаунчера, закрывается здесь;
попутно секции «Нерешённое» всех задач приводятся к правде (что закрыто
позже — помечается закрытым со ссылкой на коммит).

**Вне объёма (единственные допустимые хвосты):** коды 1.1.80
(`replace_group_empty`, конфликт `tag` свёртки) — ждут бампа лаунчера;
`kCoreBuildTags` константой — решение владельца оставить.

## Волна A — движок, разбор, сборка (`task-570-a`)

1. **§560 п.9 — дельта тела у узлов вне разбора.** Узел, собранный
   конструктором (правка в UI, генерация WARP/MASQUE), не несёт дельту до
   перечитывания источника. Сделать так, чтобы дельта считалась от origin при
   эмите или хранилась у узла и переживала правку; критерий — поля из дельты
   не теряются после правки узла в UI. Тест.
2. **§563 — два места декодирования вне движка** (`uri_utils.dart` ~:172,
   `sources.dart` ~:302) → `decodeUtf8Lenient`. **Порядок форм:** форма
   `default` пробуется последней независимо от позиции (как Go). Тест.
3. **§562/§566 — форма `ini` в движке маппера.** `conf_b64` секции wireguard
   объявлена реестром; научить движок пространству `space: ini`, снять
   `parseWireguardUri`, `_kOutOfEngineLinkForms` и файл
   `uri_parsers/wireguard_parser.dart` (последняя обёртка) с их тестами.
   `wg://` — по реестру (`aliases`): принимать; разрыв с Go — строка в отчёте
   для лаунчера. Корпус ссылок wireguard зелёный, identity не меняется.
4. **§568 сборка:** правило с целью-свёрткой внутри логических (`type:
   logical`) тел перенаправляется рекурсивно; detour на свёртку, опустевшую
   после отбраковок, — fail-closed по §74 п.4 (узел-носитель снимается с
   кодом, не идёт напрямую); `@urltest_*`-ссылки в `auto` свёртки — как у
   Направления (кейс `direction/fold_auto_inherits_template_vars` без skip);
   порядок провайдерской группы в selector свёртки — по §74 п.3 (пул в порядке
   модели), тест.
5. **§555:** шаблонные DNS-серверы видят все переменные шаблона (§66, как
   тела пресетов); старые строковые предупреждения пресетов, дублирующие
   коды, снять — подсказка про скачивание SRS становится параметром/текстом
   кода, не второй строкой; гейт «правило без условий» — общий критерий по
   схеме реестра (правило, у которого после Dropped нет ни одного поля-условия
   из схемы правила реестра); если реестр не размечает поля-условия — записать
   точный запрос лаунчеру и оставить узкий гейт.
6. **§561 данные:** запись `dropped` несёт `ownerTag`/имя записи источника;
   отбраковки пустого refresh (0 узлов) сохраняются в сводку как причины
   последнего разбора; дедуп одинаковых записей между элементами по
   (код, параметры, owner).

## Волна B — UI и сводки (`task-570-b`)

1. **§555 UI переменных:** `text_list` + `options` — мультивыбор из списка;
   `options_open` — своё значение сверх списка с приведением по `type`
   (`preset_params_tab.dart`, редактор переменных). Поверхность
   `template_degraded`: после сборки на Home кратко «Template: N warnings» с
   переходом в лог/шторку кодов, сохранение не блокирует.
2. **§565:** переключение члена selector прямо на экране узла (не только в
   редакторе группы); выбор члена у группы подписки сохраняется между
   перезапусками (`manualDefault` группы подписки хранится в состоянии).
3. **§568 UI:** опция `include` Направления на свёртку выбирается в
   редакторе Направления; редактор свёртки предупреждает (не запрещает) при
   `tag`, занятом узлом, другой свёрткой или Направлением.
4. **§561 UI:** шторка отбраковок называет запись-источник (по `ownerTag`
   из волны A — согласовать поле заранее: `NodeWarning.ownerTag`, если его
   нет — B добавляет поле, A заполняет); диалог анализа вставки из буфера
   показывает отбраковки.

Общее: строки английские, без §NNN; UI менять можно — решение владельца
«доводить до конца». Имена схем/протоколов в Dart не появляются; коды — из
`warnings.json`; identity не меняется.

## Итог волны A

1. **§560 п.9.** Копии узла через конструктор вне разбора (перетег
   WARP/MASQUE в `SubscriptionController`) несут `bodyDelta`, как уже нёс
   путь эмодзи у `.conf` и `withChained`. Страж
   `test/models/body_delta_carry_test.dart`: каждая копия
   `rawSource: x.rawSource` в `lib` вне разбора несёт
   `..bodyDelta = x.bodyDelta`. Правка узла в UI идёт текстом источника и
   повторным разбором — дельта считается заново.
2. **§563.** `utf8Lossy` (`uri_utils.dart`) и title подписки
   (`sources.dart`) — через `decodeUtf8Lenient`. `formsInTrialOrder`
   (`interpreter.dart`): форма `detect.default` пробуется последней на всех
   трёх входах (текст, объект, ini).
3. **§562/§566.** `_selectForm` исполняет форму `space: ini` у ссылки
   (`_selectLinkIniForm`): фрагмент снимается до `detect` и декода и
   возвращается источником `fragment`; `.conf` раскладывается диалектом
   протокола (секция без своего `ini_dialect` наследует его у секции
   протокола, которая его объявила, — `section_loader._withIniDialect`).
   Звено метки — путь тела (`peers[].address`) читается у входа со схемой;
   у голого `.conf` — нет (литерал `WireGuard` — открытый пункт DELTAS,
   identity). Сняты `parseWireguardUri`, `_kOutOfEngineLinkForms`, каталог
   `uri_parsers/`; тесты переведены на `parseLinkAs<WireguardSpec>`,
   `engine_no_scheme_names_test` требует отсутствия каталога. `wg://` —
   по реестру (`aliases`).
4. **§568 + 1.1.80 §77 п.5–6.** `findReplaceTagConflicts`: тег свёртки
   (или `<tag>-auto`) = Направление/двойник (`direction`), свёртка выше по
   списку (`replace`), тег шаблона (`system`) → `replace_tag_conflict`,
   источник собирается несвёрнутым (`EmitContext.isReplaceBlocked`).
   `replace_group_empty {tag, mode}` — один на свёртку без групп. Коды —
   `BuildResult.buildCodes` и строкой реестра в `emitWarnings`; раннер
   Направлений сверяет коды сборки. Носитель detour на свёртку,
   опустевшую после отбраковок, выпадает каскадом
   (`_dropCarriersOfDroppedReplaces`). Правила логических тел —
   рекурсивно. `@имя` в `auto` свёртки — переменная шаблона
   (`resolveAutoVars`). Порядок провайдерской группы — в порядке модели,
   тест.
5. **§555.** Шаблонные DNS-серверы видят все переменные шаблона
   (`resolveTemplateDnsServerBody(globalVars:)`, свои `vars` сильнее,
   пустое — Dropped). Строки пресетов «missing rule_set (download SRS
   first)» и «none of … available» сняты — остаётся код; подсказку про
   скачивание несёт строка набора «no cached file (download first)». Гейт
   «правило без условий» — узкий (см. «Нерешённое»).
6. **§561.** `withDropOwner` (`parse_all.dart`): запись без владельца
   получает имя записи источника (контейнер `.conf` — подсказка с индексом
   или `#N`; строка `vpn://` — строка и номер контейнера). `summaryDropped`
   сводит дубли по (код, параметры, владелец). Пустой refresh кладёт свои
   причины в сводку.

**Контракт 1.1.80 (дополнение оркестратора).** `on_invalid: default_from`
уступает сперва следующему годному звену цепочки `source`
(`_nextValidSource`, MAPPER_ENGINE §10.5). Строка `vpn://` в списке ссылок —
все контейнеры профиля с origin `.conf` (`parseAmneziaVpnUriAll`,
`parseContainerLineAll`); контейнер по умолчанию сохраняет прежнее имя
строки (имя профиля), прочие — `<профиль> <контейнер>`. detour вида
`amnezia_link` с `all`/`not`/`regex` движок исполнял и прежде.

## Итог волны B

1. **§555.** `TemplateVarListView` и параметры пресета: `text_list` +
   `options` — чипы мультивыбора (`VarMultiSelect`), значение — выбранные
   строки в порядке `options`; `options_open` — список плюс своё значение
   (у `int` — цифры и clamp, у `text_list` — поле по одному на строку);
   закрытые `options` у `text`/`int` — dropdown, свободного ввода нет
   (TEMPLATE_LANG §2.1). Четыре переменные шаблона со свободным вводом
   рядом со списком (`urltest_url`, `urltest_interval`, `urltest_tolerance`,
   `proxy_listen`) получили `options_open: true` — поведение не изменилось.
   `template_degraded`: `SubscriptionController.templateWarnings` + stamp,
   Home — снек «Template: N warnings» с кнопкой в `showNodeWarningsSheet`
   (тексты реестра); сохранение не блокируется.
2. **§565.** Экран узла ручной группы: кружок у члена выбирает его —
   при туннеле `HomeController.selectInGroup` (`selectOutbound`), без
   туннеля — сразу в состояние. Выбор запоминает
   `SubscriptionController.rememberGroupMember`: группа папки — её
   `manualDefault`, группа подписки — `SubscriptionServers.groupDefaults`
   (сырой тег группы → сырой тег члена, ключ записи `group_defaults`,
   в бэкап не едет — `lx_backup_slice` рантайм: у `sourceSubscription` схемы
   поля нет). Сборка накладывает выбор на копии узлов
   (`withGroupDefaultsApplied`), обратная карта ведёт к оригиналам. Выбор с
   главного экрана (`switchNode`) запоминается тем же путём. Живой выбор
   не поднимает `configDirty` (плашка и автоперезапуск были бы шумом), но
   ставит `groupDefaultsPending` — старт VPN пересобирает конфиг.
3. **§568.** Редактор Направления: группы свёрток — кандидаты `include`
   (`foldCandidatesOf`), в Routing и в правке фильтра с главного экрана;
   попутно правка фильтра с главного экрана больше не вычёркивает опции
   (кандидаты раньше не передавались). Редактор свёртки: подсказка под
   именем, если оно занято узлом другого источника, другой свёрткой или
   Направлением (`replaceTagOwnersOf`); сохранение не запрещено.
4. **§561.** `NodeWarning.ownerTag` — геттер базы (пусто), поле у
   `RegistryWarning` и `DialerProxyUnusableWarning` (было); шторка
   показывает «Entry: <тег>» под заголовком записи. Диалог вставки из
   буфера: `ClipboardAnalysis.dropped` — сухой разбор того же входа, строка
   «N entries will be skipped» открывает шторку причин.

## Верификация

По одному файлу, каждая волна — свои: корпуса `contract_test`,
`body_contract_test`, `direction_corpus_test` (A); тесты редакторов и
виджет-тесты (B); новые тесты на каждый пункт. Полный прогон — CI после
слияния обеих.

Волна A (по одному файлу, контракт 1.1.80): `contract_test` 379/0,
`body_contract_test` 169/0, `direction_corpus_test` 29/0 (skip снят),
`backup_corpus_test`, `before_480_identity_snapshot_test`,
`engine_emit_roundtrip_test`, `wireguard/vless/vmess_pipeline_invariants`,
`registry_dart_refs_test`, `template_contract_test`, `build_config_test`
(вместе 845/0); новые: `engine_link_ini_form_test` 4/4,
`engine_form_redetect_utf8_test` 10/10, `vpn_line_all_containers_test`,
`body_delta_carry_test` 3/3, `source_replace_build_test` 11/11,
`dropped_summary_tails_test` 3/3; `preset_expand_test` 67/67,
`dns_servers_resolver_test`, тесты переведённых с `parseWireguardUri`
(awg, wireguard_edge, warp, round_trip, build_config, home_node_warnings).
`flutter analyze` — 0, `hardcoded_check --strict` 0/0.

Волна B (по одному файлу): `test/widgets/template_var_options_test.dart`
4/4 (новый), `template_var_list_test` 8/8, `template_var_list_pointwise_test`;
`test/screens/template_warnings_snack_test.dart` 2/2 (новый);
`selector_member_pick_test.dart` 4/4 (новый: хранение, кодек, экран узла);
`fold_ui_570_test.dart` 3/3 (новый); `dropped_owner_paste_test.dart` 3/3
(новый), `node_notifications_test`, `subscription_dropped_summary_test`;
`lx_backup_test` + `record_codec_sources_test` + `lx_backup_slice_test`
134/134; `tag_prefix_commit_test`, `clipboard_analysis_l10n_test`,
`switch_node_noop_guard_test` зелёные. `dart analyze` изменённых файлов —
0; `hardcoded_check` 0/0, `ui_check --strict` 0/0, `template_check` 0/0.

## Нерешённое / follow-up

Вне объёма (решение владельца): `kCoreBuildTags` константой. Коды 1.1.80
(`replace_group_empty`, конфликт `tag` свёртки) — сделаны волной A после
бампа.

Запросы лаунчеру (волна A):

- **Гейт «правило без условий».** Реестр не размечает поля-условия правил
  `route.rules`/`dns.rules`; у Go список в коде
  (`core/build/preset_expand.go:isRuleEmpty`, `isDNSRuleEmpty`). Просьба —
  объявить в реестре набор условий (или служебных ключей), тогда гейт LxBox
  станет общим по данным. До того — узкий гейт по `rule_set`.
- **dart-ссылка** `registry/protocols/wireguard.json` →
  `app/lib/services/parser/uri_parsers/wireguard_parser.dart:parseWireguardUri`
  протухла (файл снят): заменить на
  `app/lib/services/parser/engine/interpreter.dart:runSection`; до замены
  строка в `registry_dart_refs_known_stale.txt`.
- **`wg://`**: LxBox принимает по `aliases` реестра, Go `IsDirectLink` — нет.

Замечание по identity (по норме реестра, не хвост): у ссылки
`<схема>://<base64 .conf>` с фрагментом И комментарием под `[Peer]` имя
теперь из фрагмента (цепочка `label.source` формы `conf_b64`: fragment →
comment), прежняя обёртка брала комментарий первым.
