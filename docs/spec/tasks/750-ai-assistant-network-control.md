# 750 — ИИ-ассистент управляет сетью: диагностика, маршрут приложения, подключения

| Field | Value |
|-------|-------|
| Status | Draft — спека, ждёт ответа владельца по разделу «Открытые вопросы» |
| Start date | 2026-11-17 |
| Source | Решение владельца 17.11.2026: развить управление сетью через ИИ-ассистента (три класса задач: «почему не открывается», «пусти приложение через выход/страну», «подключи к рабочей сети») |
| Related specs | §721 (AppFunctions: старт/стоп/статус, тумблер «AI assistant control»), §687 (URL Check), §047 (Automation API), §747 (два процесса `:ui`/`:bg`), §712 (`package_name_regex`), §715 (значок пула = флаг в имени узла), фича `014-AUTOMATION` |

## Problem

Ассистент Android (AppFunctions, §721) умеет только включить и выключить VPN
и прочитать статус. Три просьбы пользователя до приложения не доходят:

1. «Почему не открывается сайт / приложение» — ассистент не может запустить
   проверку и узнать, на какой стадии сбой.
2. «Пусти это приложение через такой-то выход / через такую-то страну» —
   ассистент не может ни посмотреть, ни поменять маршрут приложения.
3. «Подключи меня к рабочей сети» — ассистент не видит подключений
   (WireGuard / AmneziaWG, OpenConnect, OpenVPN, Tailscale) и не может
   включить или выключить одно из них.

Агент на компьютере (Debug API через adb) правила и Направления менять уже
умеет, но проверки адреса, списка приложений, выходов и подключений там нет.

## Diagnosis

Проверено по коду 17.11.2026 (`develop`, `3806b1ac`).

**Где исполняется функция ассистента.** AppFunction исполняется в нативном
сервисе, процесс может быть холодным, Flutter-движка нет (§721). После §747
это процесс `:bg`, в котором Flutter не будет вовсе.

**Что натив умеет сам (без Dart):**

- старт/стоп/статус туннеля (`BoxVpnService`, `TunnelState`);
- команды работающему ядру через `CoreSession.client?.newCallClient()`:
  `selectOutbound(group, tag)`, `getGroups()`, `getOutbounds()` (у WG/AWG —
  `endpointState`), `getWireGuardStatus(tag)`; снимки Tailscale и OpenConnect
  (`ServiceCommandClient.tailscaleSnapshot`, `openConnectSnapshot`);
- проверка адреса: `CommandClient.startConnectionTest(request, handler)`
  (§687) от Flutter не зависит — нужен только сокет работающего ядра. Сейчас
  обёртка есть лишь на стороне UI (`BoxCommandClient.startConnectionTest`),
  события уходят в `UiSinks`;
- список установленных приложений (`PackageManager`, разрешение
  `QUERY_ALL_PACKAGES` уже объявлено);
- чтение готового `singbox_config.json` (`ConfigManager.load()`).

**Чего натив не умеет:**

- Правила, Направления, источники (в том числе подключения) лежат в
  `lxbox_settings.json`; Kotlin этот файл не открывает (ARCHITECTURE § 5).
- Конфиг собирает только Dart (`SubscriptionController.generateConfig()`),
  фонового Dart-исполнителя в проекте нет (ни `FlutterEngine` вне
  `MainActivity`, ни `vm:entry-point`).
- Подписи Направлений и выключенные подключения в `singbox_config.json`
  не попадают — нативу их взять неоткуда.
- Соединения с именем пакета приходят только подпиской (push), разового
  запроса нет.

Вывод: чтение и действия над работающим ядром делаются нативно; всё, что
меняет сохранённую конфигурацию (правило, Направление, включение
подключения), может применить только Dart.

**Страна узла.** Признака страны у узла нет: ни поля, ни GeoIP, ни функции
«имя → код». Страна видна только в имени узла — флагом-эмодзи или названием,
как их написал поставщик подписки. Отбор узлов в Направление — регулярка по
имени (`Direction.nodeFilter`).

**Фактическая страна выхода.** URL Check (§687) тело ответа не отдаёт и
внешний адрес не показывает. Но есть диагностический GET через узел (§392,
ядро SPEC 058): `CommandClient.getURLViaOutbound(tag, link, timeoutMs,
maxBytes, userAgent)` возвращает тело; первый чекер списка —
`https://1.1.1.1/cdn-cgi/trace`, в его ответе строки `ip=` (внешний адрес) и
`loc=` (двухбуквенный код страны). Вызов нативный, тег может быть тегом
Направления. Это и есть проверка «куда на самом деле вышел».

**Подключения.** WireGuard / AmneziaWG, `openvpn-client`, `openconnect`,
`tailscale` — обычные узлы в `sources[]` с флагом `enabled`. Включение =
флаг + пересборка конфига + reload туннеля (`toggleAt` /
`enableNodeByCoreTag` → `generateConfig` → `saveParsedConfig` →
`reloadVpn`). Сеансовый выключатель ядра (`setEndpointEnabled`) есть только
у WG/AWG и не сохраняется.

**Debug API.** `/rules`, `/directions`, `/action/switch-node`,
`/action/start-vpn*` есть. Нет: проверки адреса (в §687 ручка отложена),
списка приложений, выходов, подключений, «каким маршрутом идёт приложение».
Сервер живёт только вместе с Flutter-движком.

**Правило §721 про чужой текст.** В ответы агенту не клали имена узлов:
они приходят из чужих подписок и могут быть прочитаны как инструкция
(требование Google Play к AppFunctions). Для этой задачи владелец решил
иначе — раздел «Что видит ассистент».

## Solution

### Функции ассистента

Все — в `LxBoxAppFunctions` (тот же сервис, одна точка входа), все под
тумблером «AI assistant control» (`ensureEnabled()` первой строкой, в схеме
`isEnabled = false`, идентификаторы добавляются в
`AppFunctionsLogic.FUNCTION_IDS`). Старые `startVpn` / `stopVpn` /
`getVpnStatus` не меняются.

| Функция | Параметры | Ответ | Меняет |
|---------|-----------|-------|--------|
| `getNetworkOverview` | — | `NetworkOverview` | нет |
| `listExits` | `direction: String`, `query: String?` | `ExitList` | нет |
| `checkUrl` | `url: String`, `appPackage: String?` | `UrlCheckReport` | нет |
| `checkExit` | `direction: String` | `ExitCheck` | нет |
| `findApps` | `query: String` | `List<AppMatch>` (до 10) | нет |
| `getAppRoute` | `appPackage: String` | `AppRoute` | нет |
| `selectExit` | `direction: String`, `exit: String` | `ExitSelection` | выбор узла в работающем ядре |
| `setAppRoute` | `appPackage: String`, `target: String`, `exitFilter: String?` | `ChangeRequest` | сохранённую конфигурацию |
| `setConnectionEnabled` | `connectionId: String`, `enabled: Boolean` | `ChangeRequest` | сохранённую конфигурацию |

**`getNetworkOverview`** — одно чтение вместо пяти:

- `vpnStatus` — как в `VpnState`;
- `directions[]`: `tag` (`vpn-1`…), `name` (подпись пользователя),
  `exitCount` (число выходов), `currentExit` (имя выбранного сейчас выхода;
  пусто, если туннель остановлен);
- `connections[]`: `id`, `name`, `type` (`wireguard` / `amneziawg` /
  `openvpn` / `openconnect` / `tailscale`), `enabled`, `state` (`up` /
  `connecting` / `down` / `disabled` / `unknown`; при остановленном туннеле —
  `down` либо `disabled`);
- `defaultRoute` — куда идёт трафик без правила (`route.final`): тег
  Направления, `direct` или `block`.

**`listExits`** — имена выходов Направления, как они записаны (с флагом и
названием). `query` — подстрока без учёта регистра; ответ: `exits[]` (до 200
имён), `total`, `truncated`. Страну и город по именам определяет сам
ассистент; приложение имена не разбирает.

**`checkUrl`** — запускает проверку §687 на глубину `http`, с `fresh = true`,
от имени приложения `appPackage` (если задан — путь пройдёт по правилам этого
приложения). Ждёт итог не дольше 20 с. Ответ:

- `outcome`: `ok` / `failed` / `vpn_off` / `busy` / `timeout`;
- `failedStage`: `dns` / `route` / `tunnel` / `connect` / `tls` / `http` /
  пусто — класс стадии, на которой сбой (сопоставление `kind` стадии ядра с
  классом — таблица в коде; неизвестный `kind` → `connect`);
- `error` — текст ошибки ядра по упавшей стадии (обрезан до 200 знаков);
- `httpStatus`, `elapsedMs`;
- `route`: `direction` (тег), `exit` (имя узла, через который пошёл запрос),
  `direct: Boolean`, `blocked: Boolean` — чем закончился выбор маршрута;
- `findings[]` — коды находок ядра (`excluded_from_vpn`, `fakeip_*`,
  `quic_rejected`, `reality_not_recognized`, …);
- `advice` — одно-два предложения «что сделать», из постоянной таблицы
  приложения по паре (`failedStage`, находки). Примеры: `vpn_off` — «The VPN
  is off. Start it and repeat the check.»; `dns` — «The name does not
  resolve. Check the DNS servers in L×Box or try another exit.»; `route` +
  `blocked` — «A routing rule blocks this address.»; `tunnel`/`connect` через
  Направление — «The exit server does not respond. Switch to another exit.»; `tls` — «The site refuses the secure connection through this
  exit. Try another exit or a direct route.»; `http` 4xx/5xx — «The site
  answered with an error itself; the network path works.»

При остановленном туннеле проверка не запускается и VPN сам не включается:
`outcome = vpn_off` с советом. Включать VPN — отдельное действие ассистента
(`startVpn`).

**`checkExit`** — фактический выход Направления: GET
`https://1.1.1.1/cdn-cgi/trace` через `direction` (§392), из ответа берутся
две строки. Ответ: `outcome` (`ok` / `failed` / `vpn_off`), `country`
(`loc=`, двухбуквенный код), `ip` (`ip=`), `exit` (имя выбранного узла),
`error`. Так ассистент после переключения убеждается, что страна выхода та,
которую просили, — и отвечает на «какой у меня сейчас IP».

**`findApps`** — поиск установленного приложения по подстроке названия или
имени пакета (без регистра): `package`, `label`. Нужен, чтобы «Telegram»
превратить в `org.telegram.messenger`.

**`getAppRoute`** — статический ответ по сохранённым правилам: первое
включённое правило, в чьих `package_name` / `package_name_regex` есть пакет.
Ответ: `target` (тег Направления, `direct`, `block`), `targetName`,
`ruleName` (пусто, если правило не найдено — действует `defaultRoute`),
`conditional: Boolean` (у правила есть ещё условия — домен, сеть, Wi-Fi; тогда
маршрут зависит от них).

**`selectExit`** — в работающем ядре выбирает в Направлении `direction`
выход `exit` (точное имя из `listExits`; `selectOutbound`). Ответ:
`direction`, `exit`, `changed`. Ошибки: туннель остановлен; такого выхода в
Направлении нет. Выбор, как и выбор пальцем на главном экране, живёт до
перезапуска туннеля.

**`setAppRoute`** — «пусти приложение через…». `target`: тег Направления,
`direct` или `block`. `exitFilter` (необязателен, только с тегом Направления)
— подстрока имён выходов, которую ассистент выбрал по `listExits`: флаг,
название страны или полное имя одного сервера.

- Без `exitFilter` правило ведёт в Направление `target` как есть.
- С `exitFilter` правило ведёт в Направление, ограниченное этими выходами:
  ищется Направление, чей фильтр узлов равен этой подстроке (экранированной
  для регулярки); если такого нет, оно создаётся — подпись = `exitFilter`,
  фильтр узлов = подстрока, авто-выбор лучшего узла (urltest) включён.
  Под подстроку в `target` не попал ни один выход — ошибка, ничего не
  создаётся.
- Правило: если уже есть включённое inline-правило ровно с одним условием
  `package_name = [пакет]` — у него меняется выход; иначе создаётся новое
  правило «<название приложения>» в пользовательской зоне (`nextUserRuleNum`).
  Если выше по списку стоит другое правило, ловящее этот пакет, новое правило
  ставится перед ним (`placeRuleAfter` / перенумерация в пределах зоны);
  пресеты не двигаются.
- Применение: пересборка конфига и перезагрузка ядра на месте, если туннель
  поднят (без оглядки на галку «Auto-restart VPN on settings change»: человек
  просил результат сейчас).

**`setConnectionEnabled`** — включить/выключить подключение `connectionId`
из `getNetworkOverview`. Включение: флаг `enabled` у узла, пересборка,
reload; если туннель остановлен и согласие на VPN выдано — старт туннеля.
Выключение: флаг, пересборка, reload; туннель не останавливается.

`ChangeRequest`: `status` (`applied` / `confirmation_required` / `rejected`),
`summary` — что именно будет или было сделано, собранное приложением из
собственных шаблонов («Route Telegram through 🇩🇪»).

### Как применяются изменения конфигурации (рекомендуемый вариант, см. «Открытые вопросы», В1)

`setAppRoute` и `setConnectionEnabled` применяет Dart, после подтверждения
пользователя в приложении:

1. Функция проверяет параметры по индексу (ниже), записывает заявку в
   `SharedPreferences` `lxbox_assistant` (одна ячейка: новая заявка замещает
   старую; срок жизни 10 минут) и показывает уведомление «Assistant request:
   <summary>» с действием «Review».
2. Агенту сразу возвращается `status = confirmation_required` и `summary`.
3. Нажатие открывает L×Box; приложение показывает окно подтверждения с тем же
   описанием и кнопками «Apply» / «Reject». Если окно L×Box уже на экране —
   окно подтверждения появляется сразу, без нажатия на уведомление.
4. «Apply» — Dart вносит изменение, пересобирает конфиг, перезагружает ядро,
   обновляет индекс. Заявка стирается в любом исходе.

Так изменение сохранённой конфигурации никогда не происходит без человека,
и схема не требует Flutter в фоновом процессе (совместима с §747).

Действия без подтверждения (исполняются сразу, нативно): все чтения,
`checkUrl`, `checkExit`, `selectExit`, `startVpn`, `stopVpn`.

### Индекс для натива

Нативу нужны подписи Направлений, имена их выходов, подключения (включая
выключенные) и правила по приложениям. Dart после каждой записи конфига и на старте
передаёт нативу сводку методом канала `setAssistantIndex(json)`; натив хранит
её в `lxbox_assistant` (приём `AutomationCache`). Это производное зеркало,
настройкой не является; Kotlin `lxbox_settings.json` по-прежнему не открывает.

```json
{"v":1,
 "route_final":"vpn-1",
 "directions":[{"tag":"vpn-1","name":"Proxy","enabled":true,
                "exits":["🇩🇪 Frankfurt 1","🇳🇱 Amsterdam"]}],
 "connections":[{"id":"…","name":"Office","type":"wireguard","enabled":false,"tag":"…"}],
 "app_rules":[{"name":"Telegram","packages":["org.telegram.messenger"],
               "package_regexes":[],"outbound":"vpn-2","conditional":false}]}
```

При поднятом туннеле список выходов и выбранный выход берутся из живых групп
ядра (`getGroups`), индекс — запасной источник для остановленного туннеля.

Индекса нет (приложение после обновления ещё не открывали) — чтения отвечают
ошибкой «Open L×Box once to finish setup.»

### Страна выхода

Решение владельца 17.11.2026: «разве ИИ по имени не сможет легко
предположить страны? в имени же обычно подписки кодируют или флагом или
названием. кроме того есть диагностика».

- Своего признака страны у узла и разбора имён в приложении **нет**.
  Ассистент получает имена выходов как есть (`listExits`) и сам понимает,
  какие из них «Германия».
- Параметр функций — выход или подстрока имён (`exit`, `exitFilter`), не
  страна.
- Фактическую страну выхода подтверждает `checkExit` (ответ
  `cdn-cgi/trace`: `loc=` и `ip=`).

### Что видит ассистент (чужой текст в ответах)

- Решение владельца 17.11.2026 (см. «Страна выхода») отменяет для этой
  задачи запрет §721: имена выходов агенту **отдаются**.
- Отдаются: имена выходов, подписи Направлений, имена подключений, названия
  приложений и правил — после очистки: без управляющих символов и переводов
  строк, не длиннее 64 знаков. Это поля данных; в описаниях функций сказано,
  что это имена, заданные поставщиком или пользователем.
- Адреса серверов, ключи, ссылки подписок, содержимое конфига, логи, список
  соединений — не отдаются никогда.
- `error` в `UrlCheckReport` — текст ядра, обрезанный до 200 знаков, одной
  строкой.
- `advice` и `summary` — только из таблиц приложения.

### Чего ассистент не может

Добавлять и удалять серверы, подписки и подключения; менять DNS, настройки
TUN, список приложений туннеля, тумблеры безопасности; удалять правила и
Направления; читать и менять конфиг целиком; включать сам тумблер «AI
assistant control»; выдавать согласие на VPN.

### Debug API

Тот же набор для агента на компьютере — префикс `/assistant` (сервер
`app/lib/services/debug/`, нужен включённый Debug API и токен; подтверждение
не спрашивается — доступ уже выдан владельцем устройства):

| Маршрут | Соответствует |
|---------|---------------|
| `GET /assistant/overview` | `getNetworkOverview` |
| `GET /assistant/exits?direction=&q=` | `listExits` |
| `POST /assistant/check-url` `{url, app?}` | `checkUrl` |
| `POST /assistant/check-exit` `{direction}` | `checkExit` |
| `GET /assistant/apps?q=` | `findApps` |
| `GET /assistant/app-route?app=` | `getAppRoute` |
| `POST /assistant/exit` `{direction, exit}` | `selectExit` |
| `POST /assistant/app-route` `{app, target, exit_filter?}` | `setAppRoute` (сразу `applied`) |
| `POST /assistant/connection` `{id, enabled}` | `setConnectionEnabled` (сразу `applied`) |

Ответы — те же поля в snake_case. Логика одна: чтения и проверку Dart берёт у
натива методами канала (`assistantOverview`, `assistantCheckUrl`, …),
изменения выполняет тот же Dart-код, что и после «Apply».

### Тумблер

Строка «AI assistant control» остаётся одна. Подпись меняется: «Let Android
assistants control the VPN, check why a site does not open, and request
routing or connection changes (Android 16+)». Отдельных тумблеров по классам
функций нет.

### Файлы (план)

- Kotlin, `appfunctions/`: `LxBoxAppFunctions.kt` (+7 функций),
  типы ответов (`@AppFunctionSerializable`), `AssistantIndex.kt` (чтение
  индекса), `AssistantLogic.kt` (чистая логика: поиск выходов по
  подстроке, маршрут приложения по индексу, класс стадии, совет, разбор
  `cdn-cgi/trace`, очистка текста), `AssistantRequests.kt` (заявка + уведомление),
  `AssistantCore.kt` (проверка адреса, проверка выхода, группы — через
  сервисный клиент ядра).
- Kotlin, `vpn/`: метод проверки адреса на сервисной стороне
  (`ServiceCommandClient`), методы канала в `VpnPlugin`, приём extras заявки
  в `MainActivity`.
- Dart, `lib/services/assistant/`: `assistant_index.dart` (сборка индекса), `assistant_actions.dart`
  (`setAppRoute`, `setConnectionEnabled`), `assistant_request.dart` (заявка,
  окно подтверждения в `lib/screens/…`); `lib/services/debug/handlers/assistant.dart`.
- Тесты: JVM-тест `AssistantLogicTest.kt`; Dart —
  `test/services/assistant/*_test.dart`,
  `test/services/debug/assistant_handler_test.dart`.

## Docs to update

- `docs/AI_ASSISTANT.md` + `docs/AI_ASSISTANT.ru.md` — новый пользовательский
  гайд «Работа с ИИ-ассистентом и сетью»; ссылки из `docs/README.md`,
  `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md`.
- `docs/AUTOMATION.md` / `.ru.md` — раздел «AI assistants (AppFunctions)»:
  новый перечень функций, ссылка на гайд.
- `docs/api/debug-api-reference.md` — раздел `/assistant` с bash-примерами;
  `handlers/help.dart`.
- `docs/ARCHITECTURE.md` — индекс ассистента (§ 5, зеркала), заявка и её путь.
- `docs/spec/features/014-AUTOMATION/` — функция `assistant-control`
  (чёрный ящик) + строка в `FEATURE.md` (en/ru).
- `docs/PRIVACY_POLICY.md` / `.ru.md` — что получает ассистент.
- `CHANGELOG.md` → Unreleased.
- `RELEASE_NOTES.md`, `pubspec.yaml` — `[deferred till release]`.

## Risks and edge cases

- AppFunctions API экспериментальный; вызывать функции из Gemini могут
  только участники программы раннего доступа. До её открытия пользователь
  изменения увидит только через Debug API и `adb shell cmd app_function`.
- Kotlin-тесты и компиляция Kotlin на CI `checks` не гоняются — проверяются
  локально (`:app:testDebugUnitTest`, `:app:compileDebugKotlin`) и сборкой APK.
- Имя узла пишет поставщик подписки; флаг в нём может не совпадать со страной
  выхода. Для этого есть `checkExit`.
- В ответах агенту появляется текст из чужих подписок (имена узлов). Он
  очищается и обрезается, но остаётся чужим текстом — осознанное решение
  владельца; при проверке требований Google Play к AppFunctions (с 14.04.2027)
  к нему вернуться.
- `checkExit` обращается к `1.1.1.1` через туннель; внешний адрес уходит
  ассистенту в ответе.
- Направление с фильтром выходов остаётся в списке Направлений после просьбы — это
  обычное Направление, пользователь удаляет его сам.
- Заявка одна: вторая просьба до подтверждения первой замещает её.
- Уведомление о заявке требует разрешения на уведомления; без него заявка
  видна только при открытии приложения (окно подтверждения показывается при
  старте, если заявка не истекла).
- `config_locked_for_debug` включён — изменение отклоняется с понятным
  текстом.
- После §747 функции уезжают в `:bg`; индекс и заявка лежат в
  `SharedPreferences`, читаемых обоими процессами через существующий канал
  `:ui` → `:bg` (уточняется при слиянии §747).

## Verification

1. JVM-тест `AssistantLogicTest`: поиск выходов по подстроке; разбор
   `cdn-cgi/trace`; маршрут приложения (точное имя, регулярка, условное правило, нет правила);
   класс стадии и совет; очистка текста; разбор индекса.
2. Dart-тесты: сборка индекса; `setAppRoute` (новое правило, замена выхода,
   создание и повторное использование Направления с фильтром выходов, под
   фильтр ничего не попало, правило выше по списку); `setConnectionEnabled`;
   хендлеры `/assistant/*`.
3. Локально: `flutter analyze`, `:app:compileDebugKotlin` (KSP порождает
   схему с новыми функциями, все `enabledByDefault=false`),
   `:app:testDebugUnitTest`.
4. Эмулятор (Android 16), если доступен: `adb shell cmd app_function
   execute-app-function` для каждой функции при выключенном и включённом
   тумблере; заявка → уведомление → окно → «Apply» → правило в списке и
   маршрут в `getAppRoute`; `/assistant/*` через `adb forward`.
5. CI `checks` зелёный на голове `develop`.

## Открытые вопросы (к владельцу, до реализации)

**В1. Как применяются изменения конфигурации по просьбе ассистента**
(`setAppRoute`, `setConnectionEnabled`).

- (а) **Подтверждение в приложении** — рекомендую, описано выше. Ничего не
  меняется без человека; не нужен Flutter в фоне; укладывается в §747.
  Цена: «подключи к рабочей сети» голосом требует одного касания.
- (б) **Сразу, без рук** — нужен фоновый Dart-исполнитель (второй
  Flutter-движок без окна в процессе сервиса либо, после §747, сервис в
  `:ui`), защита от двух писателей `lxbox_settings.json`. Отдельная крупная
  работа, пересекается с §747; изменение конфигурации чужой командой без
  подтверждения.
- (в) **(а) сейчас, (б) следующей задачей после §747** — с настройкой
  «применять без подтверждения», выключенной по умолчанию.

**В2. Что из имён отдаётся ассистенту** — **решено** владельцем 17.11.2026:
имена выходов отдаются, страну определяет ассистент (раздел «Страна выхода»).

## Unresolved / follow-up

- Фоновое применение изменений без окна приложения (В1-б).
- «Через какой выход сейчас идёт приложение» по живым соединениям.
- Проверка в Gemini — после открытия программы раннего доступа.
