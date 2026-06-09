# 090 — Логический рефактор (rewrite): осознанные изменения поведения

| Поле | Значение |
|------|----------|
| Статус | **Unblocked & re-studied** (2026-06-08): [§089](089-deep-refactor-no-monsters.md) DONE, [§091](091-config-node-model.md) DONE. Реестр пересмотрен против текущего кода — см. [Переоценку](#переоценка-после-089--091-2026-06-08). Исполнение по пунктам (каждый = своя таска); юзер выбирает порядок/когда. |
| Тип | refactor / architecture / **behavior-changing** |
| Отличие от §089 | §089 = **zero behavior change** (только извлечение/слои). §090 = **намеренные изменения рабочей логики**: дедуп с расхождениями, формализация брокеров, роутинг, чистка легаси-путей, «honest fix» из §086/§087/§088. |

> **Это living-документ + отчёт.** Раздел [Реестр кандидатов](#реестр-кандидатов-на-переписывание)
> пополняется по ходу §089 (я и так в коде — фиксирую находки сразу). Раздел
> [Журнал](#журнал-выполнения) — для фазы исполнения. Юзер автономный режим,
> не спрашивать.

---

## 1. Как понял задачу

После того как §089 уберёт «монстров» структурно (behavior-preserving),
нужен **второй проход — переписывание там, где рабочая логика должна
измениться**. Те же цели качества: аккуратные слои, дедуп, хорошие подписные
механизмы (event/state-брокеры), понятные имена, чистка ненужных комментариев
и исторических особенностей, известные паттерны, **роутинг**, **диаграммы
данных и движения событий**, полное обновление `docs/ARCHITECTURE.md`
(схемы, зоны ответственности, описание всех файлов, логика ключевых решений;
части — в отдельные файлы при необходимости). Всё проинспектировать.

**Граница §089 / §090 (ключевое):**
- Если изменение **не меняет поведение** (извлечь виджет, переименовать,
  разнести по файлам) → это **§089**.
- Если изменение **меняет наблюдаемое поведение / контракт / data-flow**
  (унифицировать расходящийся дубль, заменить ad-hoc подписку на брокер,
  централизовать роутинг, выпилить легаси-путь, починить known-minor) →
  это **§090**, и каждое такое изменение = **своя под-таска + spec + тесты**
  (нельзя прятать поведенческое изменение в «рефакторинг»).

## 2. Принципы исполнения §090

1. **Каждый пункт реестра — отдельный коммит/PR-эквивалент** с собственной
   таской `docs/spec/tasks/NNN.md` если поведение меняется нетривиально
   (правило проекта «фича это фича, таска это таска»).
2. **Тесты сначала или вместе**: поскольку поведение меняется, нужны новые/
   обновлённые тесты, фиксирующие НОВЫЙ контракт. `flutter analyze` clean.
3. **Приоритет: не сломать прод-VPN.** Изменения в recovery/VPN-логике
   (§086/§087/§088 класс) — особо осторожно, device-verify.
4. **Архитектурные решения — записывать** в ARCHITECTURE.md (раздел «логика
   ключевых решений»): что выбрали, какие альтернативы, почему.

## Переоценка после §089 + §091 (2026-06-08)

§089 (структурный) и §091 (ConfigNode) завершены — часть реестра закрылась или
сменила форму.

### Закрыто / spun-off
- **§091 ConfigNode** (был behavior-changing кандидат §090) — **СДЕЛАН**
  отдельной таской: `ConfigCache`+`ConfigIntrospection`+reverse-map
  `subscriptionsOfTag` → `ParsedConfig`/`ConfigNode` + prefix-фильтр. Закрыл
  класс §077/§079/§080.
- **deepCopy/deepEquals дубли** (часть F) — были **behavior-preserving** →
  сделаны в §089 P6 (`services/json_clone.dart`). Из §090 убираются.
- **ARCHITECTURE.md overhaul** (раздел 4) — крупный проход сделан в §089 P7
  (слои, зоны ответственности, дерево с per-file ролями, event/data-flow).
  Остаток §090: вынос в под-файлы `docs/architecture/{...}.md` ТОЛЬКО если
  основной разрастётся (~1360 строк — пока ок) + drift-сверка после каждого
  §090-пункта.
- **Документирование** event-flow / state-брокеров / routing-графа (часть
  «задокументировать» из B1/B2/C1) — сделано в P7. Остаётся только
  **поведенческая** часть (унификация/централизация).

### Новые находки сессии (в реестр)
- **G1. Update-dismiss half-wired** `[§089 P6-found]`.
  `UpdateChecker.dismissCurrent` пишет `setDismissedUpdateVersion`, read-guard
  `getDismissedUpdateVersion` активен (update-snackbar + check), но **writer'а
  в UI нет** — фича «скрыть этот релиз» наполовину разведена. **§090:** либо
  wire «Later»-action в update-snackbar → `dismissCurrent`, либо убрать
  guard+storage целиком. Решение продуктовое (stub помечен в коде).
- **G2. `⚙` / `isDetour` миграция** `[§091-deferred]`. `ConfigNode.isDetour`
  (по `detourRefCount`) и `isMarkedDetour` (`⚙` в теге) есть в модели, но UI
  (node_settings toggle, `splitNodes` detour-hide) ещё на ручной `⚙`-пометке
  через `TagResolver.isDetourMarker`. **§090:** убрать ручную пометку → любой
  одиночный сервер как detour, `⚙` = метка «внутренний сервер подписки»,
  ориентир `isDetour` по факту. Behavior-changing, переходный период.

### Подтверждённые (остаются)
A1/F (форматтеры, уточнены ниже) · D1/D2/D3 (recovery/VPN) · E1 (CustomRule
sealed-split — custom_rule 618, задокументир. исключение §089) · E2 (background
updater).

### Предлагаемый порядок (value / risk)
1. **G1** (мелко, продуктовое решение) + **A1/F форматтеры** (низкий риск).
2. **E1 CustomRule sealed-split** (изолированная модель, план в memory).
3. **G2 `⚙`/isDetour** (завершает §091-арку).
4. **D2 §042 watchdog** / **D1 §088 wake-heal** (VPN recovery — device-verify, осторожно).
5. **B/C унификация** (брокеры/роутинг) — крупно, когда остальное устаканится.

---

## 3. Реестр кандидатов на переписывание

> Накапливается во время §089. Каждый — с: что не так / предложение / риск /
> как проверить. Помечен `[§089-found]` если обнаружен по ходу структурного
> прохода.

### A. Дедупы с расхождением поведения (форматтеры) `[§089 P6 recon — точные локации]`
- **A1. `formatDuration` divergence.** `traffic_bar.dart::_uptime` сворачивает в
  дни (`1d 6h`, документировано в коде), `format_utils.formatDuration` — нет
  (`30h`), `connections_screen.dart::_formatDuration` — третий вариант (без
  секунд в минутах, без пробела в часах). Все **намеренно различны**. **§090:**
  добавить опц. `maxUnit`/`daysRollup` + `compact` флаги в `format_utils` и
  делегировать; проверить pixel-вывод во всех точках до merge.
- **A2. `formatBytes` ×4.** `format_utils.formatBytes` (канон, §084) + НЕ
  мигрированные копии: `clash_api_client.dart::_formatBytes` (нет 0-guard),
  `subscription_detail_format.dart::formatBytes` (`'0'` вместо `'0 B'`, mixed
  spacing), `connections_screen.dart::_formatBytes` (единичные литеры `B/K/M`,
  **нет GB-tier** — overflow в огромные M). **§090:** мигрировать первые две на
  канон (с 0-guard/spacing-проверкой); connections — отдельный `compact`-режим,
  НЕ менять вывод вслепую.

### B. Брокеры событий / состояний (формализация)
- **B1. Event-bus унификация.** Сейчас события идут двумя разными механизмами:
  `box_vpn_client` status `Stream<TunnelStatusEvent>` и `traffic_profiler`
  `StreamController` + ad-hoc `ChangeNotifier`-подписки в экранах. **§090:**
  задокументировать и при необходимости унифицировать в явный event-flow
  (один паттерн подписки), диаграмма движения событий в ARCHITECTURE.md.
- **B2. State-брокеры.** Контроллеры (`HomeController`/`SubscriptionController`)
  + view-model'и (`NodeFilterViewModel`) — формализовать как канонический
  слой state. Оценить `.I`-синглтоны (`TrafficProfiler.I`/`AppLog.I`/…) —
  где DI уместнее. **§090:** зоны ответственности + правила зависимостей.

### C. Роутинг
- **C1. Централизация навигации.** Сейчас — россыпь `Navigator.push(
  MaterialPageRoute(...))` по экранам + `home_return_observer` (RouteObserver).
  **§090:** оценить route-таблицу / named routes / typed router; как минимум —
  задокументировать навигационный граф (диаграмма) и убрать дубль конструкции
  переходов.

### D. Recovery / VPN-логика (из §086 research)
- **D1. §088 wake-heal escalation** (mode 2 Doze) — escalation ladder
  `resetNetwork → reloadVPN → restart` с re-check gate вместо текущего cliff
  `_onTunnelDead`. Уже есть design-док §088. **§090** включает его исполнение.
- **D2. §042 health watchdog** — сейчас только DRAFT-spec; `_checkHeartbeat`
  (home_controller) = cosmetic cliff (2 фейла → revoked, без эскалации, без
  фон-детекта «tunnel up but dead»). **§090:** построить HeartbeatHealth +
  HealthWatchdog или осознанно урезать.
- **D3. §087 `lastIfName` threading** `[from §088]`. `@Volatile` даёт
  visibility но не atomicity; attach-edge гонка. Known-minor. **§090:** confine
  network-monitor state к одному dispatcher/actor если на практике увидим
  ложные/пропущенные ресеты.

### E. Легаси / исторические особенности
- **E1. CustomRule sealed-split** `[from memory]`. Рефактор `custom_rule.dart`
  (618 стр) в sealed `Inline`/`Srs`/`Preset` + SRS-cache у Preset (spec 011
  compliance), `name` в Preset read-only. Меняет модель → §090.
- **E2. Background subscription updater** `[from memory]`. Auto-refresh по
  `profile-update-interval` — доделать (не писать с нуля).
- _(пополняется по ходу §089: дубли логики, мёртвые ветки, расходящиеся
  контракты, ad-hoc подписки, которые замечу при извлечении)._

### F. Дубли логики (не только форматтеры) `[§089 P6 recon]`
- **F1. Done в §089 P6** (behavior-preserving): `_deepCopy`/`_deepClone`/
  `_deepEquals` → `services/json_clone.dart`. Сюда НЕ относится (закрыто).
- **F2. HTTP retry-policy дубль** (low). `rule_set_downloader.download` и
  `subscription/sources._fetch` — одинаковый контракт «3 попытки, exp backoff
  1s/3s, 4xx = permanent skip», но hand-rolled раздельно с расходящимся
  success/permanent handling (return-null+atomic-file vs throw+multi-source).
  **§090:** опц. вынести только scaffold `retryHttp({backoffs, isPermanent})`;
  тела НЕ сливать. **РЕШЕНИЕ (юзер 2026-06-08): ПРОПУСТИТЬ** — низкая
  ценность × два структурно разных пути (rule_set возвращает `null`, sources
  бросает). Не баг, не делаем.
- Форматтеры — см. A1/A2.

## 4. Архитектура + документация (общая цель §090)
- **ARCHITECTURE.md** (сейчас 1231 стр) — полный апдейт: слои + правила
  зависимостей, зоны ответственности, **описание всех файлов**, event-flow и
  data-flow диаграммы, routing-граф, «логика ключевых архитектурных решений».
  Вынести части в отдельные файлы (напр. `docs/architecture/{layers,events,
  state,routing}.md`) если основной разрастётся.
- Сверить документацию с фактическим кодом после §089+§090 (drift-проверка).

## 5. Не в скопе
- Сам §089 (структурный) — отдельная задача, должен завершиться первым.
- Новые фичи (не рефактор/не из research) — отдельно.

## Журнал выполнения
### 2026-06-08 — создан (gated на §089)
- Документ-аккумулятор заведён. Исполнение начнётся после завершения §089.
- Первичные кандидаты внесены (A1, B1-2, C1, D1-3, E1-2). Пополняется по ходу.

### 2026-06-08 (ночь) — автономный батч + morning-handoff

**Сделано (закоммичено, тесты зелёные):**
- **G1** update-dismiss ✅ (`479893f`, таска 092) — «Later» в snackbar.
- **A2** formatBytes ✅ (`fee3125`) — clash байт-в-байт, subscription → канон.
- **A1** formatDuration ✅ (`0a32e56`) — `daysRollup`-флаг, свернул
  `traffic_bar._uptime`. Behavior-preserving (parity-tested).
- На телефоне: **vc 2701** (== HEAD).

**F2 (retry-дедуп) — ОЦЕНЕНО → ПРОПУЩЕНО.** `rule_set_downloader.download`
(возвращает `null`) и `sources._fetch` (бросает) структурно разные: общий
scaffold потребовал бы restructure control-flow обоих сетевых путей. Низкая
ценность (recon ранжировал последним) × чувствительность сети × нет
device-verify ночью = не оправдано. Кандидат на focused-сессию, не блокер.

**НЕ делал вслепую ночью (нужен ты / device-verify) — handoff:**
- **E1 — SRS-cache у Preset.** Sealed-split УЖЕ сделан (custom_rule sealed
  Inline/Srs/Preset). Остаток = offline SRS-кэш remote rule_sets (spec 011) +
  Preset.name read-only. Уже специфицировано: [task 011](011-sealed-customrule-split.md)
  + [feature 011](../features/011%20local%20ruleset%20cache/spec.md) + memory-план.
  **Почему не ночью:** корректность = sing-box принимает cached SRS по local
  path → проверяется ТОЛЬКО на устройстве с реальным preset'ом; тихий fail =
  routing не применяется. + memory прямо: «самостоятельный refactor, свой flow,
  согласовать». **Утром:** скажешь «делай E1» → исполняю по task 011 с device-
  проверкой routing'а.
- **G2 — `⚙`/isDetour миграция — ОТКРЫТЫЙ ДИЗАЙН, нужно твоё решение.**
  Модель готова (`ConfigNode.isDetour` по `detourRefCount`, `isMarkedDetour` по
  `⚙`). Вопрос: что значит «detour» для hide/show-фильтра?
  - **Сейчас:** прячет **вручную ⚙-помеченные** ноды (`TagResolver.isDetourMarker`).
  - **Вариант (структурный):** прятать ноды, на которые **реально ссылаются**
    через `detour` (`isDetour`) — корректнее (это и есть «релей»), ручная
    пометка не нужна.
  - **Нюанс:** не идентично — ⚙-нода без ссылок прячется сейчас, но не по
    isDetour; и наоборот. + `⚙` есть и в **билдере** (`server_list_build`
    ставит на main-as-detour) — там роль остаётся.
  - **Моя рекомендация:** перейти на `isDetour` (структурно), `⚙` в
    node_settings убрать как ручной toggle, оставить как build-time метку
    «внутренний сервер подписки». Но это user-visible UX → **твой выбор утром.**
- **D1/D2/D3** (VPN recovery, native Kotlin) / **B/C** (event-bus/routing
  унификация, архитектурные решения) — крупные/рискованные, не для unattended.

### 2026-06-08 — начато исполнение (G1, A2)
- **G1 update-dismiss** — ✅ DONE (таска [092](092-update-dismiss-wire.md)).
  «Later» в update-snackbar → `dismissCurrent` (persist + clear). +2 теста.
- **A2 formatBytes** — ✅ DONE. `clash_api_client._formatBytes` → канон
  (байт-в-байт), `subscription_detail_format.formatBytes` → делегат к
  `formatBytes(spaced:true)` (косметика: `0`→`0 B`, `500B`→`500 B` —
  консистентность). `connections_screen` НЕ трогал (compact, без GB —
  намеренно). analyze + 802 green.
- Осталось из реестра: A1 (formatDuration — аккуратнее, 3 разных вывода),
  E1, G2, D1/D2/D3, F2, B/C.

### 2026-06-08 — переизучён после §089 + §091 (unblocked)
- §089 + §091 завершены → реестр пересмотрен против текущего кода.
- **Закрыто/spun-off:** §091 ConfigNode (отдельная таска, done); deepCopy/equals
  дубли (§089 P6, behavior-preserving); ARCHITECTURE.md крупный overhaul (P7);
  документирование event/state/routing (P7) — осталась только поведенческая
  унификация.
- **Новые находки:** G1 (update-dismiss half-wired), G2 (`⚙`/isDetour миграция
  из §091-deferred).
- **Уточнено:** A1→A1+A2 (форматтеры — точные локации formatBytes ×4 +
  formatDuration ×3, все nameренно различны → нужны compact/maxUnit-флаги);
  F заполнен (F1 done, F2 retry-policy low).
- **Предложен порядок исполнения** по value/risk (G1+форматтеры → E1 → G2 →
  D2/D1 → B/C). Исполнение по-прежнему по выбору юзера.
