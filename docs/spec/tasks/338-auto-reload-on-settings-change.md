# §338 — Автоперезапуск VPN при смене настроек (жизнь без плашек)

| | |
|---|---|
| Статус | ✅ Реализовано (DEVICE-PENDING) |
| Дата | 2026-08-02 |
| Связанные | [`323 on-update action`](323-subscription-on-update-action.md), [`324 canonical diff`](324-saved-vs-running-canonical-diff.md), [`331 blue banner`](331-blue-banner-and-manual-refresh-reaction.md), [`116 banner mechanism`](116-banner-mechanism-and-config-banner-fix.md), [`107 single-flight rebuild`](107-single-flight-rebuild.md), [`030 vpn reload button`](030-vpn-reload-button.md) |

## Задача

Галка в App Settings → **General → Behavior**: «Auto-restart VPN on settings
change», off по умолчанию. Не в Subscriptions: источник изменения — любой (узел,
detour, DNS, routing, per-app), подписка лишь один из них. Включена — приложение само применяет любое изменение конфига к
живому туннелю, и **плашек не остаётся вовсе**: ни синей («Settings changed»),
ни розовой («Config changed — restart VPN»).

§323 дал такую автоматику подписке. Но конфиг меняют и 25+ других мест (правка
узла, detour, DNS, routing, per-app, тумблеры в настройках) — там плашка
по-прежнему единственный путь. Галка распространяет §323-реакцию на все
источники изменений.

## Где вешается: одна воронка, не 25 call-site'ов

`configDirty` поднимают 25+ мест, но пересборку запускают **не они**. Все пути
сходятся в `_rebuildAndClearDirty` (§107 single-flight):

```
возврат на home (§076 homeReturnObserver) ─┐
retry-when-idle (§107 R3) ─────────────────┤
реакция подписки (§323) ───────────────────┼─→ _rebuildAndClearDirty → _rebuildConfig
гейт на Start ─────────────────────────────┘                              ↓
                                                                    saveParsedConfig
                                                                    (§324 staleness)
```

Хук ставится после успешной пересборки в `_rebuildAndClearDirty`. Это же
объясняет, почему нельзя вешать слушателя на `configDirty`: флаг живёт в
`SettingsStorage` статикой (§113), его подъём `notifyListeners` не гарантирует.

## Условия перезапуска

Перезапускаем **только** когда есть что применять:

| Условие | Почему |
|---|---|
| галка включена | явное согласие на разрыв соединений |
| туннель up | иначе применять некуда, конфиг подхватится на Start |
| `configChangedNeedRestart` после пересборки | §324-вердикт: saved разошёлся с running. `fresh` → ядро уже на этом конфиге, рвать незачем |
| пересборка успешна | `_rebuildConfig` вернул true; иначе на диске старый конфиг |

Дальше `HomeController.reloadVpn()` — внутри свой `canReload`: cooldown 3с и
гейт на не-connected состояние. Флаг при успехе гасит он же (§323 fix).

То есть механика ровно та, что у `_reactToSubscriptionUpdate(reload: true)`, но
источник изменения — любой.

## Перекрытие per-subscription выбора

Галка включена → per-subscription «При обновлении» (§323 `onUpdateAction`)
теряет смысл: глобальное «применять всё сразу» строже любого из трёх режимов.
Строка в `subscription_settings_tab` **скрывается**.

Поле в storage при этом **не трогаем**. Юзер выключит галку — вернутся его
прежние значения (`none` там, где он поставил `none`). Стереть их значило бы
потерять данные при обратимом переключении.

Эффективное значение — `effectiveOnUpdateAction`:

```
галка вкл  → reload   (для всех подписок, независимо от поля)
галка выкл → list.onUpdateAction
```

Читается в `AutoUpdater.maybeUpdateAll` (там же, где §337-флаг) — так авто-путь
подписки и общий путь настроек дают одно поведение, а не два конкурирующих
reload'а.

## Тексты не должны врать

Плашки при включённой галке не появляются (флаги гасятся), но **snackbar'ы
живут своей жизнью** и до §338 звали юзера перезапускать VPN там, где reload
уже едет сам:

| Где | Было | Стало при галке |
|---|---|---|
| пересборка конфига (`_rebuildConfig`) | «Config rebuilt: N nodes — restart VPN to apply» | «Config rebuilt: N nodes — reloading VPN» |
| правка канала (`node_list`) | второй snackbar «Restart VPN to apply changes» | не показывается — пересборка на возврате применит сама |

Условие текста — то же, что у хука (галка + туннель up + конфиг разошёлся с
running), поэтому «перезагружаю» не появится там, где reload не случится:
`fresh`-вердикт (§324) даёт обычный текст без обещаний.

Флаг читается **один раз** за пересборку, в `_rebuildAndClearDirty`, и уходит
и в текст, и в хук. Иначе юзер, снявший галку между двумя чтениями, прочёл бы
«перезагружаю» без перезагрузки.

## Что галка НЕ делает

| | Почему |
|---|---|
| не рвёт туннель при `fresh`-вердикте (§324) | конфиг совпал с работающим — применять нечего |
| не поднимает VPN, если он лежит | «перезапуск» ≠ «запуск»; автостарт — своя настройка (§189) |
| не отменяет плашку ошибки конфига (§116 case B) | это не «изменение», а сбой чтения |
| не убирает snackbar «Config rebuilt» | пересборка по кнопке — отчёт о действии юзера остаётся |

## Цена, которую юзер выбирает

Каждое применение — разрыв туннеля ~3с и смерть in-flight TCP. При активной
правке настроек (юзер перебирает DNS-правила) это серия разрывов. Поэтому off
по умолчанию, а в subtitle галки — прямое предупреждение про 3 секунды.

Дебаунс не делаем: пересборка уже привязана к возврату на home (§076), то есть
к завершению серии правок, а не к каждому тумблеру.

## Реализация

| Слой | Файл | Что |
|---|---|---|
| Storage | `services/settings_storage.dart` | ключ `auto_reload_on_change` + `get/setAutoReloadOnChange`; в `_appFeatureFlagVars` (§221) |
| Хук | `screens/home_screen.dart` | в `_rebuildAndClearDirty` после успешной пересборки — `_maybeAutoReload()`; флаг кэшируется в поле `_autoReloadOnChange` |
| Подписки | `services/subscription/auto_updater.dart` | `effectiveOnUpdateAction` — при флаге `reload` для всех |
| UI галки | `screens/app_settings_screen/widgets/general_tab.dart` | `SwitchListTile` в блоке Behavior (под «Auto-start on boot») + предупреждение про 3с |
| Скрытие | `screens/subscription_detail_screen/widgets/subscription_settings_tab.dart` | строка «On update» под `if (!autoReloadOnChange)` |
| Текст | `screens/home_screen.dart` (`_rebuildConfig`), `screens/home/widgets/node_list.dart` | snackbar не обещает рестарт, когда reload едет сам |
| Проводка | `screens/app_settings_screen.dart`, `screens/subscription_detail_screen.dart` | поле состояния + чтение + колбэк |

Флаг читаем из storage (не из state-поля home_screen), потому что
`AutoUpdater` и `subscription_detail_screen` живут вне его state.

`subscription_detail_screen` читает флаг один раз в `initState` без
`RouteAware`: App Settings открываются с home, а не из экрана подписки, —
попасть сюда с несвежим значением можно только зайдя на экран заново, и тогда
`initState` отработает снова.

`_reactToSubscriptionUpdate` (§323) свой `reloadVpn` не дублирует: при
включённой галке reload уже сделал хук внутри `_rebuildAndClearDirty` и погасил
флаг. Гейт `configChangedNeedRestart` отсеял бы второй вызов и так, но зависеть
от порядка гашения не хочется.

## Тесты

`test/subscription/auto_reload_on_change_test.dart`:

- `effectiveOnUpdateAction`: флаг вкл → `reload` при любом поле (`none`,
  `rebuild`, `reload`); выкл → значение поля;
- решение о reload (копия логики хука, приём §323/§311): вкл+tunnelUp+
  needRestart → true; каждое из трёх условий по отдельности снятое → false;
- дефолт ключа = `false`.

## Инспекция 02.08.2026 (device-фидбэк «плашка всё равно вылезла»)

Лог устройства показал: основной путь работал (`changed=true → stale →
auto-reload → ok`), а «плашка» была окном мигания (п.3). Разбор дал четыре
дефекта:

1. **Ложный mtime-фикс (отменён).** Первая реакция — «`touchConfig` после
   записи конфига» — строилась на неверной гипотезе: `saveConfig` сам
   переписывает `singbox_config.json` (mtime=now), bootstrap-сравнение после
   пересборки и так чисто. Наблюдавшийся `dirty=true` на старте был честным
   (сессию убил установщик посреди правок). Правка откатана.
2. **Bootstrap мимо воронки.** Холодный старт с dirty при живом туннеле
   (VpnService переживает kill приложения) пересобирал голым
   `generateConfig+saveParsedConfig` — хук §338 не срабатывал, розовая плашка
   переживала включённую галку. Теперь bootstrap-ветка зовёт
   `_rebuildAndClearDirty(silent: true)` (внутри то же + §107-restore + хук).
3. **Окно мигания розовой плашки.** Между `saveParsedConfig` (взвёл
   `needRestart`) и завершением reload (~1–3с) плашка честно показывалась —
   при включённой галке читается как «не работает». Теперь на окно применения
   (`_autoApplying`, ставится в воронке) розовая подавляется параметром
   `autoApplying` в `activeBanners`. Если reload сорвался — окно закрывается с
   невзятым флагом, плашка возвращается честным fallback'ом.
4. **Молчаливый cooldown-скип.** `reloadVpn` при `!canReload` (3с cooldown /
   не-connected) тихо выходил — авто-применение «пропадало без следа». Теперь
   `_maybeAutoReload` проверяет `canReload` сам и логирует warning; плашка
   после окна подавления — объяснимый fallback.

Известное ограничение (не дефект): `configDirty`, поднятый пока юзер УЖЕ на
home (Debug API, automation §047), не триггерит пересборку — воронка заводится
от возврата на home, Start или реакции подписки. Синяя плашка в этом случае
показывается, тап по ней применяет (и хук §338 сработает).

## Device-verify

1. Галка off (дефолт): правка узла → синяя плашка есть, поведение прежнее.
2. Галка on, туннель up: правка узла → вернулся на home → туннель дропнулся
   ~3с, **плашек нет ни одной**.
3. Галка on, туннель down: правка → плашки нет, туннель не поднялся сам;
   Start применил новый конфиг.
4. Галка on + подписка в режиме `none`: авто-обновление со сменившимся
   составом всё равно применилось (перекрытие работает).
5. Галка on → выключить: в подписке снова видна строка «При обновлении» с её
   прежним значением (`none` не потерялось).
6. Галка on, пересборка дала конфиг, идентичный работающему (§324 `fresh`):
   туннель НЕ дропнулся.

## Docs to update

- `CHANGELOG.md` — Unreleased.
- `docs/STORAGE.md` — ключ `auto_reload_on_change`.
- §323 — модель `onUpdateAction` перекрывается галкой §338.
