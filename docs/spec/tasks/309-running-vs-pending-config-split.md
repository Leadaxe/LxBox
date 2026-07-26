# §309 — Разведение running / pending конфига

**Тип:** таска (bug-fix + разведение поля состояния)
**Статус:** спека
**Связано:** §116 (флаг `configChangedNeedRestart`), §091 (`ParsedConfig`), §122 (CommandClient как источник дерева групп), §302/§307 (import-rules — типовой источник смены тегов)

---

## Симптом

Long-press по ноде → «View details» отдаёт `Not found: L: 🇫🇷zФранция`, при том что
нода видна в списке строкой выше и помечена как активная.

Device-verified 26.07.2026 (скрин 12:10, туннель поднят 11h41m назад, подписка
Liberty обновилась в 10:13). Воспроизведено повторно вручную.

---

## Корень

`saveParsedConfig` ([config_io.dart:89](../../../app/lib/controllers/home_controller/config_io.dart:89))
кладёт свежесобранный конфиг в `configRaw` и **тем же** `copyWith` признаёт, что он
разошёлся с работающим ядром:

```dart
_emit(_state.copyWith(
  configRaw: raw,                        // UI-состояние
  configChangedNeedRestart: needRestart, // …и оно уже не то, на чём работает туннель
```

Одно поле обслуживает две разные сущности:

| Сущность | Кто её потребляет |
|---|---|
| конфиг, на котором **работает ядро** | список нод, resolve тега, routing-строки, шторка |
| конфиг, **собранный последним** | редактор конфига, плашка «Config changed», следующий старт |

При живом туннеле они расходятся, и UI начинает смешивать срезы:

```
Nodes list      ← ccGroups (CommandClient)   = СТАРОЕ (память ядра)
configModel     ← configRaw (стор)           = НОВОЕ (пересобрано)
                        ↓
        resolve тега из старого среза по новому конфигу → промах
```

Дерево групп при этом **не** перетирается — `_onCcGroups` честно replace-not-merge
и защищён guard'ом от пустых push'ей ([home_controller.dart:848](../../../app/lib/controllers/home_controller.dart:848)).
Перетирается именно `configRaw`.

Смена тегов — рядовое событие: import-rules §302 (`substitute` `⚡`→`z`),
`tag_prefix` подписки, переименование ноды в фиде. Правило вида «заменить символ,
встречающийся почти всюду» задевает разом весь список.

### Почему это не только снекбар

Все три действия контекстного меню резолвят по `configRaw`:

| Действие | Поведение при промахе | Файл |
|---|---|---|
| View details | снекбар `Not found: %s` | [node_actions.dart:33](../../../app/lib/screens/home/node_actions.dart:33) |
| Copy JSON (server/detour/both) | **молчит** (`server == null` → return) | [node_actions.dart:69](../../../app/lib/screens/home/node_actions.dart:69) |
| Copy URI | свой источник (`subController.entries`), свой промах | [node_actions.dart:132](../../../app/lib/screens/home/node_actions.dart:132) |

Молчаливый выход в Copy JSON — анти-паттерн немого гейта (ср. §277/§278):
юзер жмёт «копировать», реакции нет, в буфере остаётся прошлое.

---

## Решение

Развести одно поле на два. Пока туннель жив, UI смотрит на конфиг работающего
туннеля; свежесобранный лежит рядом и ждёт рестарта.

```
HomeState:
  configRaw        → конфиг, на котором РАБОТАЕТ ядро    (actual)
  pendingConfigRaw → результат последней пересборки       (pending, nullable)
  configModel      → ParsedConfig от configRaw            (без изменений)
```

**Инвариант.** `pendingConfigRaw != null` ⟺ `configChangedNeedRestart == true`.
Флаг перестаёт быть самостоятельным состоянием и становится геттером — рассинхрон
двух представлений одного факта делается невыразимым.

### Жизненный цикл

| Событие | `configRaw` | `pendingConfigRaw` |
|---|---|---|
| туннель **down**, save | ← новый | остаётся null |
| туннель **up**, save, конфиг изменился | не трогаем | ← новый |
| туннель **up**, save, canonical-идентичен (§116) | не трогаем | не трогаем |
| `_startInternal` / рестарт | ← pending (если был) | → null |
| `_stopInternal` | ← pending (если был) | → null |

При выключенном туннеле actual-конфига не существует, поэтому `configRaw` = pending —
поведение ровно как сейчас (решение юзера, 26.07).

`_stopInternal` тоже промотирует pending: после остановки «running» больше нет,
и следующий старт обязан идти с самого свежего конфига. Сейчас этот путь просто
гасит флаг ([home_controller.dart:521](../../../app/lib/controllers/home_controller.dart:521)) —
семантика сохраняется, т.к. промоушен обнуляет pending, а значит и геттер флага.

### Ограничение, которое надо принять явно

Конфиг хранится в **одном** файле `singbox_config.json`, `ConfigManager.save()`
перезаписывает его поверх работающего, копии «того, с чем стартовало ядро» нет
ни в Dart, ни в native ([ConfigManager.kt:24](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ConfigManager.kt:24)).

Следствие: после **рестарта приложения** поверх живого туннеля actual-конфиг
восстановить неоткуда — `getConfig()` вернёт уже перезаписанный файл. В этом
(редком) сценарии `configRaw` = содержимое файла, как сегодня; баг там остаётся
теоретически возможен.

Закрывается это только вторым файлом (снапшот на старте ядра) — **вне объёма
таски**, отдельным решением. Здесь фиксируем как известную границу, а не чиним
молча половину.

---

## Раскладка читателей

Все места из `grep configRaw|configModel` по `lib/`, приписанные осознанно.

### → actual (`configRaw`) — «что реально крутится»

| Место | Почему |
|---|---|
| [home_state.dart:85,336](../../../app/lib/models/home_state.dart:85) `configModel` | база для всего resolve'а тегов |
| [node_actions.dart:27,58](../../../app/lib/screens/home/node_actions.dart:27) | ровно баг из симптома |
| [node_list_presenter.dart:62,72,141,208,214](../../../app/lib/screens/home/node_list_presenter.dart:62) | протокол/detour-метки строк списка ← список из ядра |
| [ping_orchestration.dart:25,250](../../../app/lib/controllers/home_controller/ping_orchestration.dart:25) | пингуем то, что в ядре |
| [home_controller.dart:535](../../../app/lib/controllers/home_controller.dart:535) `_pushNotificationLabels` | шторка описывает текущий туннель |
| [home_controller.dart:889](../../../app/lib/controllers/home_controller.dart:889) `finalTag` в `_applyGroups` | выбор группы поверх снапшота ядра |
| [stats_screen.dart:73](../../../app/lib/screens/stats_screen.dart:73) + traffic_bar/home_drawer | трафик идёт по работающему конфигу |
| [node_list.dart:69](../../../app/lib/screens/home/widgets/node_list.dart:69) | empty-state списка |

### → pending (при живом туннеле; иначе actual)

| Место | Почему |
|---|---|
| [config_screen.dart:31](../../../app/lib/screens/config_screen.dart:31) | редактор обязан показывать правки, иначе они «пропадают» |
| плашка «Config changed» | сам факт наличия pending |

### → отдельно

| Место | Решение |
|---|---|
| [config_io.dart:75](../../../app/lib/controllers/home_controller/config_io.dart:75) diff §116 | сравнивать с **actual** — «устарел ли running», исходная семантика |
| [home_controls.dart:66](../../../app/lib/screens/home/widgets/home_controls.dart:66), [home_screen.dart:369,544](../../../app/lib/screens/home_screen.dart:369) «есть ли что стартовать» | `configRaw.isNotEmpty \|\| pending != null` |
| [debug/handlers/config.dart:77](../../../app/lib/services/debug/handlers/config.dart:77) `GET /config` | отдаёт **actual** (контракт: «что в памяти контроллера»); pending — новым полем в `/state` |
| [serializers/home_state.dart:11](../../../app/lib/services/debug/serializers/home_state.dart:11) `config_length` | actual + рядом `pending_config_length` |

Диагностическая ценность: `/state` начинает показывать сам факт расхождения —
сегодня его видно только по флагу, без возможности сравнить срезы.

---

## Изменения по файлам

1. **`models/home_state.dart`** — поле `pendingConfigRaw` (nullable), `copyWith`
   (с явным сбросом в null — обычный `??`-паттерн этого не умеет),
   `configChangedNeedRestart` → геттер `pendingConfigRaw != null`.
2. **`controllers/home_controller/config_io.dart`** — `saveParsedConfig` ветвится
   по `tunnelUp`; diff §116 против actual.
3. **`controllers/home_controller.dart`** — `_startInternal` / `_stopInternal`
   промотируют pending → actual; снять прямые записи `configChangedNeedRestart`
   (стал геттером), включая `markConfigChangedNeedRestart` (§076) — он теперь
   выставляет `pendingConfigRaw = configRaw` (изменение вне config pipeline:
   native-тоглы, конфиг тот же, но running устарел).
4. **`screens/config_screen.dart`** — читать pending при живом туннеле.
5. **`screens/home/node_actions.dart`** — Copy JSON перестаёт молчать: общий
   резолв, при промахе снекбар (см. §277/§278).
6. **`services/debug/`** — `pending_config_length` в `/state`.

---

## Тесты

`test/models/home_state_test.dart`, `test/controllers/`:

1. tunnel **down** + save → `configRaw` новый, pending null, флаг false.
2. tunnel **up** + save изменённого → `configRaw` старый, pending новый, флаг true.
3. tunnel **up** + save canonical-идентичного (§116) → pending остаётся null.
4. start/stop → pending промотирован в actual и обнулён.
5. **регресс §309:** tunnel up → save конфига с переименованным тегом →
   `configModel` продолжает резолвить **старый** тег (из ядра) непусто.
6. sticky-флаг: два save подряд (изменённый, затем идентичный) → флаг остаётся true.
7. `markConfigChangedNeedRestart` при tunnelUp → флаг true без смены конфига.

Регресс-тест (5) — то, чего сегодня нет ни в одном тесте: он ловит именно
смешение срезов, а не сообщение об ошибке.

## Device-verify

Рецепт воспроизведения (подтверждён юзером):

1. VPN запущен, список нод отрисован.
2. Не останавливая VPN — подписка Liberty → import-rules → поменять `substitute`
   (`⚡`→`z` на `⚡`→`Q`); либо сменить `tag_prefix` подписки.
3. Дождаться плашки `Config changed — restart VPN to apply`.
4. Long-press по ноде → View details.

Ожидаемо после фикса: JSON узла открывается (старый срез), Copy JSON копирует,
плашка на месте. После рестарта — данные из нового конфига.
