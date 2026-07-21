# 291 — Слоистая архитектура: внутренний домен, внешние адаптеры, унифицированный фасад

| Поле | Значение |
|------|----------|
| Тип | Feature (архитектурный инвариант + зонтик над task'ами 292–299) |
| Статус | ✅ Достигнуто (в основном) — инвариант внедрён, ключевые домены за фасадами; хвост снят с активного плана (см. «Состояние по коду») |
| Связано | task [290](../../tasks/290-automation-node-switch-gaps.md) (откуда пришло: «неверные уровни абстракции»), [031 debug api](../031%20debug%20api/spec.md), [047 public intent api](../047%20public%20intent%20api/spec.md), [125 configurable-channels](../125%20configurable-channels/spec.md) (эталон ChannelMutations), [123 subscription-model](../123%20subscription-model/spec.md) (эталон SubscriptionController) |

Задаёт **один архитектурный инвариант** для всего приложения и фиксирует, какие
домены ему уже соответствуют, а какие — нет. Это зонтичная спека: конкретная
работа живёт в task'ах 292–299, каждый дотягивает один отстающий домен до
инварианта. **Не** big-bang рефактор — strangler-fig: новая структура за старым
поведением, приложение релизится на каждом шаге.

## Инвариант (правило, которое должно держаться везде)

```
      ВНЕШНИЙ СЛОЙ (адаптеры)                    ВНУТРЕННИЙ СЛОЙ (домен)
   знает: транспорт + безопасность           знает: доменную логику + инварианты
   (порт, токен, allowlist, HTTP/broadcast)   НЕ знает: кто его вызывает
   НЕ знает: к чему даёт доступ
        Debug API ─┐
        Automation ─┤
        UI (view)  ─┼──►  ФАСАД домена  ──►  контроллер / модель / persistence
        (будущие)  ─┘   (единый для всех      (SettingsStorage вниз = тупая
                          потребителей)         персистенция, без политики)
```

Три правила, вытекающие из этого:

1. **Внутренний слой (домен) даёт наружу фасад и не знает потребителей.** В его
   сигнатурах нет `DebugContext`, виджетов, intent'ов. Только доменные типы.
   Инварианты (tunnel-up, group-selected, config-lock, heal detour-ссылок,
   валидация порта) живут **в фасаде/модели, ровно один раз**.
2. **Внешний слой (адаптер) знает про безопасность и транспорт, но не про то,
   к чему даёт доступ.** Debug держит порт/токен/host-check; Automation —
   allowlist; UI — презентацию. Ни один не переизобретает доменный инвариант —
   все зовут фасад.
3. **Унификация внешнего слоя.** Команда/операция объявлена ОДИН раз; все
   адаптеры приводят свой ввод (HTTP-путь, имя intent'а, тап) к вызову фасада.
   Дублирование состава и логики между адаптерами структурно невозможно.

## Нецели

- **Не** переписывать 15k строк экранов под MVVM за один заход. Инвариант
  внедряется по одному домену, каждый шаг релизится.
- **Не** мигрировать форму хранилища (`vars`-blob ↔ типизированные top-level
  ключи). Два представления прячутся за фасадом, JSON не трогается — миграция
  формы задевает §221 backup-инвариант (allowlist⊆export). Унификация
  представления — indefinitely deferred (task 298/299 помечены RISKY).
- **Не** трогать домены, уже соответствующие инварианту (см. «Эталоны»).
- **Не** менять внешний контракт Debug API там, где это ломает совместимость;
  Debug — root-by-design (приватный), но раскладку сырых Map наружу не плодим.

## Карта здоровья доменов (аудит 2026-07-20)

Ни один домен не «сломан». Оценка = сколько швов несёт.

| Домен | Оценка | Соответствует инварианту? |
|---|---|---|
| **Channels / detour / balance** | эталон | ✅ `ChannelMutations`-фасад + `@visibleForTesting` guard §275 |
| **Subscriptions / servers** | эталон | ✅ `SubscriptionController` владеет мутациями; Debug+Automation делегируют |
| **Runtime (home/VPN/ping/live)** | эталон | ✅ `HomeController`; 0 `SettingsStorage` в рантайм-экранах; API через контроллер |
| **Rules (custom routing)** | clean | ✅ sealed `CustomRule`; UI+Debug общий write-path |
| **WARP / Backup / Automation / native_prefs** | clean | ✅ сервис-слой / единый источник сериализации |
| **Template-engine / vars / config-gen** | clean core | ⚠️ ядро едино; швы на краях (onChange UI-only, flatten-back) |
| **DNS (servers+rules)** | **worst** | ❌ сырые `List<Map>`, нет модели, dual-write в экране |
| **VPN-mode / tun / app-settings** | minor | ❌ нет сервиса; валидация в 3 слоях; ~4 входа переизобретают инвариант |
| **Probe (§236)** | minor | ❌ у probe нет контроллера — живёт в folder_detail (1669 строк, 11 storage); folder-only по сигнатуре, хотя механизм общий для всей подсистемы ServerList (§296) |

## Эталоны (то, к чему приводим отстающих — НЕ трогать)

- **`ChannelMutations`** (`channel_mutations.dart`, 80 строк) — связывает
  storage-heal + resync контроллера в одну атомарную операцию, которую нельзя
  расщепить. Сырые статики `@visibleForTesting` → голый вызов краснеет в CI.
  **Эталон фасада.**
- **`SubscriptionController`** — владеет всеми мутациями; каждый мутатор → persist;
  Debug и Automation делегируют. **Эталон контроллера.**
- **`native_prefs.dart`** — единый write-through, один источник сериализации
  (`_exportToBackupMap`/`_applyFromBackupMap`), backup и Debug через него.
  **Эталон закрытой dual-write-ловушки.**
- **sealed `ServerList` / `CustomRule`** — trio toJson/fromJson/copyWith,
  инварианты в trio (переживают backup merge). **Эталон модели** для DNS (task 294).
- **`ProbeController`** (`services/probe/`, §296) — per-run stateless сервис:
  storage-trio за load/save + чистые static-решения, что зовёт экран и применяет
  к своему мутатору; ОДИН domain-shape адаптер (`probeNodesOf`). **Эталон
  контроллера-над-подсистемой** — образец для DnsController (§300) и
  VpnSettingsFacade (§293).

### Общий рецепт фасада (probe-эталон обобщён)

Повторяемая форма для §300/§293 и будущих:

1. **ОДИН domain-shape адаптер** — единственное место, где сырая форма storage
   резолвится в типизированный домен (probe: `probeNodesOf`; DNS: `load()` c
   §294 `fromJson`; VPN: `hasTun`-зеркало).
2. **Storage trio за load/save** = atomic-write choke point (probe:
   `loadThresholds/saveThresholds`; DNS: `load()`/`stage()`; VPN: `applyVpnMode`).
3. **Чистые static-решения**, что зовёт ЭКРАН и применяет к своему мутатору
   (probe: `unreachableIndexes/…`; DNS: `ruleDisplayRows/toggleRule*`).
4. **Экран тонкий**: transient-состояние + рендер + проводка решений; никакого
   владения мутабельным доменом не мигрирует «в контроллер как поле» —
   контроллер stateless, экран держит своё состояние локально (как folder_detail
   держит `_probe`).

## Cross-cutting долг (чинится в нескольких task'ах)

1. **Нет доменного фасада** у vpn-mode/tun/dns/app-settings — 24/28 экранов зовут
   `SettingsStorage` напрямую. Каждый из ~4 входов (UI/Debug/backup/build)
   переизобретает инвариант. → task 293 (vpn-mode), 294/295 (dns).
2. **Два мира «настройки»** (generic vars ↔ типизированные) мирятся только на
   build-time (`build_config` flatten-back). → прячем за фасадом, форму не мигрируем.
3. **onChange-каскад руками в 4 местах** (`applyPresetOnChange`) + дубль
   `_dnsEnableValue`. → task 297 (single-dispatch, после DNS-модели).
4. **Два движка подстановки** (`preset_expand` return ↔ `build_config` mutate). →
   task 298 — уже слиты в §120 (один `walk`-core, обёртки тонкие); закрыто по факту.
5. **Fat-screen** (folder_detail 1669, dns_settings 985, routing 865). → точечно
   (task 296 folder), остальное — низкий приоритет.
6. **Позиционные индексы** (`FolderMember` без id). → task 299 (RISKY, defer).

## План (strangler-fig; порядок = ROI, каждый шаг релизится)

| Шаг | Task | Размер | Что |
|---|---|---|---|
| 1 | [292](../../tasks/292-quick-invariant-holes.md) | S×4 | Быстрые дыры: proxyPort-валидация (D), setChannels в фасад §275 (E), heal-formatter (G), l10n gap (H) |
| 2 | [294](../../tasks/294-dns-typed-model.md) | L | DNS sealed-модель `DnsServer`/`DnsRule` (за resolver'ом) — крупнейшее снижение долга |
| 2a | [300](../../tasks/300-dns-controller-facade.md) | S–M | DnsController — load/snapshot + чистые статики (code-provable; под probe-эталон) |
| 2b | [295](../../tasks/295-dns-dual-write-fix.md) | M | DNS dual-write фикс (device; после 300) |
| 3 | [296](../../tasks/296-folder-probe-controller.md) | M | ProbeController — общий probe-фасад над ServerList (subs+user+folder); сдувает folder_detail |
| 4 | [297](../../tasks/297-onchange-single-dispatch.md) | M | onChange single-dispatch (после DNS-модели) |
| 3b | [293](../../tasks/293-vpn-settings-facade.md) | M | VpnSettings-фасад (унификация 4 входов) |
| ✅ | [298](../../tasks/298-unify-substitution-engines.md) | M, RISKY | Слить движки подстановки — уже сделано §120 (кода не потребовалось) |
| — | [299](../../tasks/299-folder-member-id.md) | L, RISKY | FolderMember id — defer |

Правило: каждый шаг — strangler-move (новая структура за старым поведением),
оставляет приложение релизабельным. Big-bang рефактора `SettingsStorage` нет.

## Состояние по коду (итог, проверено 2026-07-21)

Инвариант внедрён, эталоны на месте (`ChannelMutations`, `SubscriptionController`,
`HomeController`). Основные отстающие домены приведены к форме. Оставшийся хвост —
точечный и низкоприоритетный/высокорисковый — **снят с активного плана**; вернёмся
по необходимости.

| Task | Состояние | По коду |
|---|---|---|
| 292 quick-invariant-holes | ✅ реализовано | — |
| 294 dns-typed-model | ✅ реализовано | — |
| 300 dns-controller-facade | ✅ реализовано | `DnsController` (272 стр.), подключён к `dns_settings_screen` (`.load()`/`.stage()`) |
| 296 folder-probe-controller | ✅ по сути готово | `ProbeController` + `ProbeLifecycle`/`ProbeRunner` живут (`services/probe/`); UI-надстройка добита в §286 |
| 293 vpn-settings-facade | 🟡 частично | `VpnSettingsFacade` создан, но подключены не все входы — переключение экранов доведено не до конца; **не блокер** |
| 295 dns-dual-write-fix | 🟡 открыто | в DNS-экранах остаются unawaited `saveCustomRules` (dual-write); device-required, отложено |
| 297 onchange-single-dispatch | 🟡 частично | дедуп сделан; «не-UI писатели» — открыто |
| 298 unify-substitution-engines | ✅ по факту §120 | один `walk`-core (`if_engine.dart`), обёртки тонкие; приёмка выполняется текущим кодом |
| 299 folder-member-id | ⏸️ defer | RISKY (high blast-radius) — снято с плана |

Фича закрыта как **достигшая цели**. Открытые хвосты (293/295/297), закрытый по
факту §120 (298) и deferred (299) остаются задокументированными в своих task'ах —
не переоткрывают зонтик.

## Инвариант-тесты (защита от регресса к текущему состоянию)

- **Boundary:** ни один адаптер (debug/automation/screen) не импортит чужой
  адаптер; домен-контроллеры/модели импортятся только фасадом + экранами.
- **Guard сырых статик:** мутирующие статики `SettingsStorage` (по мере ввода
  фасадов) → `@visibleForTesting`; голый вызов из `lib/` = CI-analyze red
  (паттерн §275, уже работает для channels).
- **Валидация — один источник:** для gated-настройки инвариант проверяется в
  фасаде/модели, не переизобретается в адаптере (тест на отсутствие
  дубль-валидации).

## Docs to update

- `docs/ARCHITECTURE.md` — раздел про слои (внутренний/внешний) + карта здоровья
  доменов; ссылка на этот инвариант из описания Debug/Automation/UI.
- Каждый task 292–299 — свой `## Docs to update` (debug-api-reference при
  изменении эндпоинтов, CHANGELOG при user-visible).
- Эта спека — источник инварианта; task'и ссылаются сюда за правилом.
