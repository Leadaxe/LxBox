# §232 — IPv6/route_address за галками (opt-in) + реактивный on_change

> **СТАТУС: РЕАЛИЗОВАНО** (ожидает device-verify). Шаблон-часть + реактивная
> модель `VarValuesModel` (Approach A из multi-agent design review).

## Зачем (мотивация)

§227 включил IPv6 (`tun_address6` + `route_address`-половинки + `prefer_ipv6`)
**безусловно** у всех. Есть риск регрессии: на сетях с broken-IPv6 или на
устройствах, где явный `route_address` конфликтует с системным роутингом, это
могло сломать/деградировать IPv4-роутинг у части пользователей. Решение —
сделать обе IPv6-фичи **opt-in за галками, по умолчанию OFF**, чтобы дефолт
после обновления был идентичен до-§227 поведению.

## Часть 1 — галки (ГОТОВО, шаблон)

Две bool-var в секции TUN (`wizard_template.json`), обе дефолт `false`:

- **`ipv6_enabled` «Enable IPv6»** — гейтит `tun_address6` в `address`-массиве
  (array-element `#if`); при OFF v6-адрес выпадает → чистый IPv4. Плюс несёт
  декларативный `on_change` (см. Часть 2).
- **`route_address_enable` «Custom tunnel routes»** — гейтит весь ключ
  `route_address` (константа-половинки `0.0.0.0/1`+`128.0.0.0/1`+`::/1`+`8000::/1`)
  через map-spread `#if`; при OFF ключа нет → sing-box авто `0.0.0.0/0`.

**Дефолт после обновления:** обе OFF → `address:["@tun_address"]`, нет
`route_address`, стратегии `prefer_ipv4` — идентично до-§227. IPv6 стал opt-in.

**Дефолт-фикс (пойман device-verify'ем):** `default_value` у
`dns_strategy`/`resolve_strategy` оставались `prefer_ipv6` (§227) при галке
OFF — рассинхрон на свежей установке (галка выключена, стратегии v6).
Возвращены на `prefer_ipv4`; prefer_ipv6 теперь ставится ТОЛЬКО галкой
(on_change).

**Грабля диагностики:** `GET /config` (Debug API) = конфиг, который ядро
крутит С МОМЕНТА СТАРТА VPN, а НЕ свежесобранный `singbox_config.json` с
диска. После правок шаблона/галок ядро показывает старый конфиг до
рестарта VPN — не путать с «гейт не сработал».

Тесты: `test/builder/vpn_mode_test.dart` — 5 кейсов реальной сборки tun (оба
OFF/ON комбинации), `test/builder/if_engine_test.dart` — array-drop.

## Часть 2 — декларативный `on_change` (ПЕРЕДЕЛЫВАЕТСЯ)

Синтаксис (в var `ipv6_enabled`):
```json
"on_change": {
  "set": {
    "@dns_strategy":     {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv6", "else": "prefer_ipv4"}},
    "@resolve_strategy": {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv6", "else": "prefer_ipv4"}}
  }
}
```
Замысел: переключение галки IPv6 ставит `dns_strategy`/`resolve_strategy` в
prefer_ipv6/ipv4. Юзер потом волен поменять вручную (разовый эффект).

### Три бага первой (наивной) реализации — почему переделываем

1. **`_applyOnChange` писал в storage** (`setVar`) — НЕВЕРНО. Юзер может уйти
   с экрана без сохранения → storage уже испорчен. Side-effect должен менять
   ТОЛЬКО модель в памяти (`_varValues`), а на диск — общим save-флоу.
2. **Виджеты не подписаны на `_varValues`** — `TemplateVarListView` копирует
   значения в свою `_values` в initState и не синхронизируется. Внешнее
   изменение (галка → стратегия) виджет не видит → UI показывает старое.
3. **`walk()` на `#if`-узле возвращал `{}`, не строку** — map-spread `#if`
   мержится в родителя, а не отдаёт скаляр. `resolved is String` = false →
   запись целевой var НИКОГДА не происходила. Отсюда «после перезапуска
   значение старое» (device-verified пользователем).

### Целевая архитектура (по требованию пользователя)

- `_varValues` — единый источник истины (модель в памяти), **реактивная**.
- `_applyOnChange` меняет ТОЛЬКО `_varValues[name]` (+ pending-dirty для
  обычного сохранения), НЕ пишет storage напрямую.
- Виджеты подписаны **односторонне (emit)** каждый на свой узел
  `_varValues[name]` → перерисовываются при внешнем изменении. Убрать/
  синхронизировать приватную копию `_values`.
- Правильная оценка `#if`-узла до скаляра (не `{}`).

### Финальный дизайн (multi-agent review → Approach A: per-key ValueNotifier)

**Модель `VarValuesModel`** (новый `app/lib/widgets/var_values_model.dart`) —
`Map<String, ValueNotifier<String>>` (per-key) + `Set<String> _dirty`.
`set(name, value)` меняет notifier (emit подписчикам своего ключа) + метит
dirty, **НЕ пишет storage/cache**. `dirtyKeys` для сохранения.

**Виджеты** (`template_var_list.dart`) — убрать приватную `_values`; каждое
поле оборачивается в `ValueListenableBuilder` на `model.notifier(v.name)` →
подписка односторонняя, каждое на свой узел. Внешнее изменение (галка →
стратегия) виджет видит через emit.

**`_applyOnChange`** — только `model.set(target, resolved)` (in-memory + emit +
dirty), БЕЗ `setVar`. Рекурсия по цепочке on_change (fixpoint-guard: пишем
только если значение изменилось).

**Фикс `walk()={}`** — helper `evalIfScalar(node, resolve)` в `if_engine.dart`:
оборачивает bare `{"#if":...}` в массив → array-branch отдаёт скаляр (не
map-spread `{}`).

**Персистентность** — строгое чтение требования «не трогать storage»: cache/disk
пишутся ТОЛЬКО в `_persist` (dispose/paused), который итерирует
`model.dirtyKeys` → `setVar(k, v, flush:false)` → `flushToDisk()`. Это
единственный call-site `setVar`. Force-kill без dispose теряет staged-значения —
но так уже для ВСЕХ правок на этом экране (нет Save-кнопки), не регрессия.

### ГОТЧА — кросс-экранность (честно фиксируем)

`dns_strategy` рендерится на ОТДЕЛЬНОМ экране (DNS Settings,
`dns_settings_screen.dart`, свой State + рукописный dropdown), `resolve_strategy`
— на VPN Settings. `VarValuesModel` одного экрана **физически не может** эмитить
виджету другого экрана. Реальность:
- `resolve_strategy` (тот же экран) — обновляется ВЖИВУЮ при щелчке галки ✓
- `dns_strategy` (DNS Settings) — подхватывается при СЛЕДУЮЩЕМ открытии
  DNS-экрана (читает из общего `_cache` после `_persist`). Live-обновления нет.

Экраны **никогда не co-mounted** → юзер рассинхрона не видит. App-global модель
ради фейковой кросс-реактивности — оверинжиниринг (0 прецедентов). Принято.

### §161-edge при single source of truth (осознанная дельта)

Старое «пустое required не персистим» держало ДВА значения: display пусто,
staged — последний валидный ввод (через cache). Одна модель два значения
держать не может. Решение: `set(markDirty:false)` (display-only) + `unstage` —
пустота видна с errorText, в storage не доезжает НИКОГДА, но и промежуточный
валидный ввод, стёртый юзером, тоже не сохраняется (storage остаётся при
исходном значении). Строже старого поведения; юзер, стёрший свой ввод,
арguably его отменил. Гарантия §161 «пусто не сохраняется» — без изменений.

### Второй callsite TVLV (dns_server_edit)

`edit_controller` держит `_varValues`-Map как persistence-истину (сериализуется
только с явно заданными ключами) + `varModel` для TVLV (сидируется
vars+defaults). TVLV пишет в модель напрямую, `onChanged`→`setVarValue` ведёт
в Map. §161: пустое required остаётся display-only в модели, Map не трогается.

## Файлы

- `app/assets/wizard_template.json` — галки `ipv6_enabled`/`route_address_enable`,
  гейтинг address (array-element `#if`) / route_address (map-spread `#if`),
  `on_change` у `ipv6_enabled`.
- `app/lib/models/parser_config.dart` — поле `WizardVar.onChange` (парсинг
  `on_change`).
- **new** `app/lib/widgets/var_values_model.dart` — `VarValuesModel`: per-key
  `ValueNotifier` + dirty-set (`set(markDirty)` / `unstage` / `dirtyKeys` /
  `snapshot`).
- `app/lib/services/builder/if_engine.dart` — `evalIfScalar` (одиночный
  `{"#if":…}` → скаляр через `_selectArrayBranch`; bare-Map в `walk` уходил в
  map-spread и схлопывал скаляр в `{}`).
- `app/lib/screens/settings_screen.dart` — `_varValues`+`_pendingVars` →
  `VarValuesModel`; `_applyOnChange` только in-memory (`model.set`), storage
  трогает только `_persist` (dirtyKeys → setVar → flushToDisk, единственный
  call-site).
- `app/lib/widgets/template_var_list.dart` — приватная `_values` удалена
  (grep-гейт: 0 хитов); каждое поле в `ValueListenableBuilder` на свой
  `model.notifier(name)`.
- `app/lib/screens/dns_server_edit/edit_controller.dart` + `tabs/params_tab.dart`
  — второй callsite TVLV: `varModel` (см. выше).
- тесты: `vpn_mode_test.dart` (5 кейсов гейтинга tun), `if_engine_test.dart`
  (array-drop + `evalIfScalar`), `template_var_list_test.dart` (§161 миграция +
  §232 per-key подписка: внешний `model.set` обновляет dropdown/switch,
  unstage-семантика).

## Связано

- §227 (безусловный IPv6 — регрессию которого чиним opt-in'ом).
- §120 (if-движок, `#if` value/else — переиспользуем для on_change).
