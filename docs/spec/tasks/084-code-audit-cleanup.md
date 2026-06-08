# 084 — Code audit & cleanup backlog

| Поле | Значение |
|------|----------|
| Статус | In progress — High-блок (H1–H6) закрыт; Medium/Low в backlog |
| Дата | 2026-06-08 |
| Тип | audit / tech-debt |
| Метод | Multi-agent deep audit: 13 областей × (аудитор + adversarial-verify каждой high/medium находки). 46 агентов, 2.2M токенов. **28 confirmed** (6 high + 22 medium, прошли скептика), **62 low** (passed as-is), **5 refuted**. |
| Зависимости | — (cross-cutting backlog поверх всего кода). |

## Как пользоваться

Каждая находка — независимый cleanup. Бери по одной (или кластер) →
отдельный commit. **Не** обязательно делать всё разом. High → в первую
очередь (реальные баги/gap'ы), Medium → consistency/debt, Low → nitpicks
по случаю когда трогаешь файл.

Находки **верифицированы** скептиком против реального кода (high/medium).
Low — приняты as-is без adversarial-проверки (низкий риск).

## Сводка по областям

| Область | Чистота (по мнению аудитора) | High | Med | Low |
|---|---|---:|---:|---:|
| home_screen | Хорошо структурирован, дисциплина §048–§078. Issues — оптимизация/consistency, не баги. | 0 | 3 | 7 |
| controllers | Чистые, consistent emit. Один unused import. | 0 | 1 | 5 |
| builder | В целом чисто; 2 значимых gap'а (validator detour, allocateTag fallback). | 1 | 2 | 5 |
| parser | Хорошая структура; dead-field, hysteria2 round-trip, дубли утилит. | 2 | 4 | 3 |
| models | Чисто, sealed-классы, consistent copyWith. | 0 | 0 | 5 |
| debug | Чисто; profiler-handler error-pattern inconsistency. | 0 | 2 | 7 |
| subscription_flow | Чисто, следует §027; мелкие дубли + doc. | 0 | 1 | 3 |
| storage_migration | Чисто, atomic-write; dead method + doc-drift. | 0 | 1 | 4 |
| screens_editing | Сильная consistency §076; mismatch dirty-flag в settings_screen. | 0 | 4 | 5 |
| screens_viewing | Чисто; дубли форматтеров, dead method. | 1 | 2 | 5 |
| vpn_traffic | Хорошо; asymmetry tcpClose/tcpOpen + двойная аллокация event. | 2 | 0 | 2 |
| widgets_nav_config | Структурно ок; мелкие redundancy/magic. | 0 | 1 | 7 |
| cross_cutting | Хорошая изоляция; doc-drift ARCHITECTURE.md, дубли. | 0 | 0 | 4 |

---

## 🔴 HIGH (реальные баги / gap'ы — приоритет) — ✅ ВСЕ ЗАКРЫТЫ

> Все 6 high-находок исправлены в commit'е §084 (см. ниже). Тесты:
> validator (+3), hysteria2 round-trip (+2), format_utils (+15),
> traffic_profiler (existing pass). 762/762 suite зелёный.

### H1 — Validator не проверяет `detour`-ссылки (builder) → §081 ✅
`lib/services/builder/validator.dart:11-57`. Валидируется только
`route.rules[].outbound`, но **не** `outbounds[].detour`. Dangling detour
(см. §080) не ловится → возможен невалидный config до native-уровня.
Тест `detour_append_replace_test.dart:243-274` уже документирует баг.
**Fix**: построить set валидных тегов (outbounds + endpoints), пройтись по
outbounds — если `detour` непустой и не в set → ValidationIssue. Это
ровно §081 follow-up из §080.

### H2 — Мёртвое поле `VlessSpec.encryption` (parser)
`lib/models/node_spec.dart:102`. `final String encryption` (default 'none')
не читается / не эмитится / не тестируется нигде. Leftover.
**Fix**: удалить поле + параметр конструктора (line 116).

### H3 — Hysteria2 `upMbps`/`downMbps` не round-trip'ятся в URI (parser)
`lib/models/node_spec_emit.dart:265-274`. Эмитятся в sing-box JSON
(258-259), но `toUriHysteria2()` их не сериализует → parse→emit→toUri→parse
теряет Mbps.
**Fix**: добавить `up_mbps`/`down_mbps` в query `toUriHysteria2`. Проверить
что parser их читает обратно.

### H4 — Дублирование форматтеров bytes/duration по 3 экранам (screens_viewing)
`stats_screen` / `live_events_tab` / `per_app_trace_tab`. `_fmtBytes`/`_fmtDur`/
`_fmtTime` реализованы 3 раза с разным неймингом (`_format` vs `_fmt`),
видимостью (static / instance / module) и **расходящимся выводом**.
**Fix**: вынести в `lib/services/format_utils.dart`, импортировать везде.

### H5 — Asymmetry `tcpClose` vs `tcpOpen` в global buffer (vpn_traffic)
`lib/services/traffic_profiler.dart:1399-1403`. `tcpOpen` всегда пишется в
global rolling buffer; `tcpClose` — только при `_globalRecordingActive`,
хотя комментарий говорит «всегда». Connection lifecycle неполный в global
buffer.
**Fix**: убрать guard `if (_globalRecordingActive)` на line 1400 (или
поправить комментарий если поведение намеренное — проверить интент).

### H6 — Двойная конструкция `TrafficEvent` в `_pollConnections` (vpn_traffic)
`lib/services/traffic_profiler.dart:1275-1317`. Для новой connection строится
`raw` (8 полей), затем сразу `globalEv` копированием 19 полей из `raw` + 2
новых. Hot-path (каждые 5с на connection).
**Fix**: один объект + selective apply global-полей (confidence, matchedVia)
вместо полного копирования.

---

## 🟡 MEDIUM (consistency / debt)

### home_screen
- **M1 [bottleneck]** `_viewOutboundJson` / `_copyNodeJson` (1915-2022) делают
  полный `jsonDecode(state.configRaw)` на каждый long-press пункт меню. Для
  100+ нод — latency. `configCache` pattern (home_state 43-82) уже есть для
  build() — применить и тут (расширить ConfigCache полными outbound по tag).
- **M2 [arch-violation]** Config JSON parse/manipulation в UI-слое
  (1694-2022): `_viewOutboundJson`, `_copyNodeJson`, `_countNodesInConfig`,
  `_findNodeByDisplayTag` — business logic в StatefulWidget. Вынести в
  HomeController / `ConfigIntrospection` service.
- **M3 [inconsistency]** 3 JSON-parse операции с разным error-handling
  (`catch(_){return 0}` vs `catch(_){}`). Извлечь общий
  `_parseConfigJson(raw)` (с учётом разных fallback-семантик).

### controllers
- **M4 [bottleneck]** `runMassUrltest` worker (home_controller 933-940)
  аллоцирует новые `Map.from(lastDelay)` + `Map.from(pingBusy)` на **каждый**
  ping-результат. 50+ нод × concurrency → много temp-аллокаций. Батчить
  emit или мутировать один map. (Сначала профайлить — может не блокер.)

### builder
- **M5 [bottleneck]** `allocateTag` (build_config 313-326) после 100000
  коллизий возвращает `baseTag` который **уже в `_taken`** → нарушает
  uniqueness-инвариант. Magic 100000 без объяснения. **Fix**: бросать
  exception с диагностикой ИЛИ random-hex suffix; назвать константу.
- **M6 [inconsistency]** Collision handling разный: RuleSetRegistry
  auto-suffix `'$base ($i)'`; DNS-server dedup — first-wins+warning;
  routing rules — без dedup (post_steps 554-558 vs rule_set_registry 99-106).
  Стандартизировать (или задокументировать почему rules не дедупятся).

### parser
- **M7 [inconsistency]** `_naiveHeaderName` regex продублирован
  (`uri_parsers.dart:428` и `node_spec_emit.dart:283`) идентично. Вынести в
  `uri_utils.dart` + `isValidNaiveHeaderName()`.
- **M8 [inconsistency]** Label extraction разный JSON vs URI
  (`json_parsers.dart:106` mixing remarks/tag без `sanitizeForDisplay`;
  `uri_parsers` всегда `decodeFragment`). Применить `sanitizeForDisplay` в
  json_parsers.

### debug
- **M9 [inconsistency]** `profiler.dart` handlers возвращают
  `JsonResponse({'error':...}, status:409)` напрямую, остальные кидают
  `DebugError` (ловится errorMapper middleware). Унифицировать — `throw
  Conflict(...)` / `throw NotFound(...)`. (Затрагивает 85-93, 102-121, 265.)

### subscription_flow
- **M10 [doc-drift]** `auto_updater.dart:19` — «по 4 триггерам (§026)», но
  enum `UpdateTrigger` = 5 (appStart/vpnConnected/periodic/vpnStopped/manual),
  и спека — §027 (не §026). Поправить комментарий.

### storage_migration
- **M11 [inconsistency]** Legacy-key cleanup (`node_overrides`,
  `show_detour_servers`) в `_save()` (settings_storage 180-181) полагается
  на вызов saveX(); если не вызван — stale keys persist. Вынести
  `_cleanLegacyKeys()` в `_load()`+`_save()`, задокументировать §-spec.

### screens_editing
- **M12 [inconsistency]** `settings_screen.dart:42` использует `_pendingVars`
  map + прямой `configDirty=true` (132), без `_markDirty()` как у других
  lazy-экранов (Dns/Routing/TunApps — boolean `_pendingChanges`). Добавить
  `_markDirty()` helper для симметрии.
- **M13 [arch-violation]** `node_settings_screen.dart:124,209,222,251` мутирует
  subController + `persistSources()` без синхронизации `configDirty` (сравни
  DnsSettings:110). Обернуть в `_markDirtyAndPersist()`.
- **M14 [doc-drift]** `settings_screen.dart:38-42` §076-комментарий вводит в
  заблуждение про native VPN toggles (они идут через
  `markConfigChangedNeedRestart`, не `_markDirty`). Уточнить.
- **M15 [dead-code]** см. low-список (custom_rule_edit eager-паттерн — нужен
  только комментарий, не код).

### screens_viewing
- **M16 [dead-code]** `per_app_trace_tab.dart:937` `_legacyEventSummary` —
  `// ignore: unused_element`, не вызывается. Удалить (937-953).
- **M17 [bottleneck-minor]** `jsonDecode` в `initState` (stats_screen:95,
  node_filter_screen:76) — не hot-path (раз при входе), но для больших
  config заметно. Приемлемо сейчас; memoize если станет проблемой.

### widgets_nav_config
- **M18 [redundant-check]** `node_row.dart:53-60` `_delayColor` проверяет
  `delay < 0` дважды; negative и `>=500` → один error-цвет. Слить:
  `if (delay < 0 || delay >= 500) return error;`.

---

## 🟢 LOW (nitpicks — по случаю)

**home_screen**: redundant `mounted` checks (1723-1736, 2217-2230); magic
`0.08` drag-handle width (2524) → named const; redundant empty-config checks
(1916, 1969); stringly-typed `mode` param в `_copyNodeJson`; protocol lookup
дублируется itemBuilder vs `_protocolOfTag`.

**controllers**: unused `import 'dart:convert'` (home_controller:2); redundant
defensive check (`subscription_controller:753`); duplicated type-check helpers
(757-768); duplication в `SubscriptionEntry._copy` (179-199); `_emit`
placement в `reloadVpn` (575-586).

**builder**: `jsonEncode` для deep-equality в `_dnsRulesListEqual`
(post_steps:410-419) — premature; over-broad try в
`tryRegisterRuleSet` (53-70); stale docstring `applyPresetBundles` (421-442);
redundant empty-string check `_taken` init (299); `allocateTag` не защищён от
empty baseTag.

**parser**: `_normalizeCongestion` только в uri_parsers (TUIC); комментарий
про `normalizePacketEncoding` (83); TLS SuspectInsecure normalization разный
по протоколам (transport.dart:76-160).

**models**: redundant null-check после cast (`server_list:112-117`);
unnecessary list-spread в `ConfigCache.parse` (home_state:63); `CustomRule._id`
logic (589-592); mixed DateTime-parse patterns (server_list:108-117);
re-exported symbols в home_state (10-11) — проверить usage.

**debug**: null-safety patterns в `_previewEmptyState` (action.dart:65-78,71);
redundant method-checks (profiler 61-62 итд); null-safety state.dart:48; stale
spec-031 ref (diag.dart:15); O(N) linear search (rules:65-72, subs:83-92);
stale Conflict check (profiler:263-266).

**subscription_flow**: duplicate `diagnoseEmptyParse` (subscription_controller
667-676); redundant HTTP-status checks (sources.dart:144-149); inline
case-insensitive header lookup (sources.dart:237-242).

**storage_migration**: unused `clearCache()` (settings_storage:384); stale
docstring «proxy sources» (11); нет теста на concurrent `_save()`; redundant
key removal (302).

**screens_editing**: unused import (settings_screen:9); double null-check
(node_settings:144); deep nesting `_editServerBody` >6 (dns 1027-1089);
`_displayedServers` caching premature (dns 267-334); magic detour-prefix
(node_settings:101,106,108); custom_rule_edit — задокументировать eager-паттерн.

**screens_viewing**: static naming `_formatBytes` (stats:671); прямой
`DateTime.now()` в UI (stats/per_app_trace/speed_test); stale listener-comment
(per_app_trace:54-56); magic `'vpn-1'`/`kAutoOutboundTag` (node_filter:87,91,103);
null-safety subscriptions_screen:560.

**vpn_traffic**: magic `'connections_meta'` (traffic_profiler:1313); комментарий
противоречит коду tcpClose (1399 — связано с H5).

**widgets_nav_config**: null-safety `_buildSubtitleRow` (node_row:65-67);
premature opt `ThemeNotifier._load` (main:111-120); stale comment (main:18-20);
magic `0.4` opacity (node_row:380 — §068 решал держать тут, перепроверить);
redundant null-assertion (node_row:287-293); `Random.secure()` на каждый tap
(template_var_list:167-171); 'last seen' formatting (wifi_saved_picker:333-343).

**cross_cutting**: unused builder imports (dns_settings:10,12); double
encode/decode settings (settings_storage:821,837); **ARCHITECTURE.md:1146-1154
ссылается на removed/renamed spec-секции** (doc-drift — поправить); неоднородный
стиль §-комментариев (home_state, custom_rule, screens).

---

## Отвергнуто скептиком (5 — false positives, чинить НЕ надо)

Adversarial-verify отклонил 5 находок как неверные/устаревшие/непонятые
(по одной в parser, screens_editing, screens_viewing, vpn_traffic,
cross_cutting). Не включены выше — это шум аудита, код там корректен.

---

## Приоритизированный чек-лист

**Сразу (реальные баги/gap):**
- [x] H1 — validator detour-check (= §081) — `DanglingDetourRef` + 3 теста
- [x] H2 — удалить `VlessSpec.encryption`
- [x] H3 — hysteria2 Mbps round-trip — emit→uri + parse + 2 теста
- [x] H5 — tcpClose/tcpOpen symmetry — убран guard, поведение = комментарию
- [x] H6 — traffic_profiler двойной event — `TrafficEvent.copyWith`

**Консистентность (один проход — высокий payoff):**
- [x] H4 — вынести format_utils (bytes/dur/time) — `format_utils.dart` + 15 тестов
- [ ] M7 — `_naiveHeaderName` в uri_utils
- [ ] M9 — profiler error-handling через DebugError
- [ ] M12+M13+M14 — dirty-flag симметрия в settings/node_settings
- [ ] M10 — auto_updater doc (5 триггеров, §027)
- [ ] M16 — удалить `_legacyEventSummary`

**Долг (когда трогаешь файл):**
- [ ] M1+M2+M3 — home_screen config introspection → service
- [ ] M5+M6 — allocateTag fallback + collision-handling unify
- [ ] M4 — runMassUrltest аллокации (профайлить сначала)
- [ ] M8, M11, M17, M18

**Low** — по случаю, не отдельными коммитами (кроме unused imports /
clearCache / ARCHITECTURE.md doc-drift — их можно собрать в один cleanup).

## Файлы

- `docs/spec/tasks/084-code-audit-cleanup.md` (этот файл).
- Источник: workflow `deep-code-audit` (run `wf_93b332e2-521`), 46 агентов.
