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
умеет, но проверки адреса, списка приложений, стран и подключений там нет.

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
«имя → код». Единственный след — флаг-эмодзи в имени узла; на него уже
опирается значок пула (`kDefaultPoolBadge`, §715) и чипы фильтра
(`NodeFilter.extractEmojis`). Отбор узлов в Направление — регулярка по имени
(`Direction.nodeFilter`).

**Подключения.** WireGuard / AmneziaWG, `openvpn-client`, `openconnect`,
`tailscale` — обычные узлы в `sources[]` с флагом `enabled`. Включение =
флаг + пересборка конфига + reload туннеля (`toggleAt` /
`enableNodeByCoreTag` → `generateConfig` → `saveParsedConfig` →
`reloadVpn`). Сеансовый выключатель ядра (`setEndpointEnabled`) есть только
у WG/AWG и не сохраняется.

**Debug API.** `/rules`, `/directions`, `/action/switch-node`,
`/action/start-vpn*` есть. Нет: проверки адреса (в §687 ручка отложена),
списка приложений, стран, подключений, «каким маршрутом идёт приложение».
Сервер живёт только вместе с Flutter-движком.

**Правило §721 про чужой текст.** В ответы агенту не клали имена узлов:
они приходят из чужих подписок и могут быть прочитаны как инструкция
(требование Google Play к AppFunctions). Список выходов без имён бесполезен
— нужно решение (раздел «Что видит ассистент»).

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
| `checkUrl` | `url: String`, `appPackage: String?` | `UrlCheckReport` | нет |
| `findApps` | `query: String` | `List<AppMatch>` (до 10) | нет |
| `getAppRoute` | `appPackage: String` | `AppRoute` | нет |
| `selectExitCountry` | `direction: String`, `countryCode: String` | `ExitSelection` | выбор узла в работающем ядре |
| `setAppRoute` | `appPackage: String`, `target: String`, `countryCode: String?` | `ChangeRequest` | сохранённую конфигурацию |
| `setConnectionEnabled` | `connectionId: String`, `enabled: Boolean` | `ChangeRequest` | сохранённую конфигурацию |

**`getNetworkOverview`** — одно чтение вместо пяти:

- `vpnStatus` — как в `VpnState`;
- `directions[]`: `tag` (`vpn-1`…), `name` (подпись пользователя),
  `countries[]` (`code` ISO 3166-1 alpha-2, `nodes` — число узлов),
  `currentCountry` (код страны выбранного сейчас узла; пусто, если туннель
  остановлен или у узла нет флага);
- `connections[]`: `id`, `name`, `type` (`wireguard` / `amneziawg` /
  `openvpn` / `openconnect` / `tailscale`), `enabled`, `state` (`up` /
  `connecting` / `down` / `disabled` / `unknown`; при остановленном туннеле —
  `down` либо `disabled`);
- `defaultRoute` — куда идёт трафик без правила (`route.final`): тег
  Направления, `direct` или `block`.

**`checkUrl`** — запускает проверку §687 на глубину `http`, с `fresh = true`,
от имени приложения `appPackage` (если задан — путь пройдёт по правилам этого
приложения). Ждёт итог не дольше 20 с. Ответ:

- `outcome`: `ok` / `failed` / `vpn_off` / `busy` / `timeout`;
- `failedStage`: `dns` / `route` / `tunnel` / `connect` / `tls` / `http` /
  пусто — класс стадии, на которой сбой (сопоставление `kind` стадии ядра с
  классом — таблица в коде; неизвестный `kind` → `connect`);
- `error` — текст ошибки ядра по упавшей стадии (обрезан до 200 знаков);
- `httpStatus`, `elapsedMs`;
- `route`: `direction` (тег), `country` (код страны узла, если есть флаг),
  `direct: Boolean`, `blocked: Boolean` — чем закончился выбор маршрута;
- `findings[]` — коды находок ядра (`excluded_from_vpn`, `fakeip_*`,
  `quic_rejected`, `reality_not_recognized`, …);
- `advice` — одно-два предложения «что сделать», из постоянной таблицы
  приложения по паре (`failedStage`, находки). Примеры: `vpn_off` — «The VPN
  is off. Start it and repeat the check.»; `dns` — «The name does not
  resolve. Check the DNS servers in L×Box or try another exit.»; `route` +
  `blocked` — «A routing rule blocks this address.»; `tunnel`/`connect` через
  Направление — «The exit server does not respond. Switch the exit country or
  server.»; `tls` — «The site refuses the secure connection through this
  exit. Try another exit or a direct route.»; `http` 4xx/5xx — «The site
  answered with an error itself; the network path works.»

При остановленном туннеле проверка не запускается и VPN сам не включается:
`outcome = vpn_off` с советом. Включать VPN — отдельное действие ассистента
(`startVpn`).

**`findApps`** — поиск установленного приложения по подстроке названия или
имени пакета (без регистра): `package`, `label`. Нужен, чтобы «Telegram»
превратить в `org.telegram.messenger`.

**`getAppRoute`** — статический ответ по сохранённым правилам: первое
включённое правило, в чьих `package_name` / `package_name_regex` есть пакет.
Ответ: `target` (тег Направления, `direct`, `block`), `targetName`,
`ruleName` (пусто, если правило не найдено — действует `defaultRoute`),
`conditional: Boolean` (у правила есть ещё условия — домен, сеть, Wi-Fi; тогда
маршрут зависит от них).

**`selectExitCountry`** — в работающем ядре выбирает в Направлении
`direction` узел страны `countryCode`: первый узел группы с таким флагом
(`selectOutbound`). Ответ: `direction`, `country`, `changed`. Ошибки: туннель
остановлен; в Направлении нет узлов этой страны (в тексте — доступные коды).
Выбор, как и выбор пальцем на главном экране, живёт до перезапуска туннеля.

**`setAppRoute`** — «пусти приложение через…». `target`: тег Направления,
`direct`, `block` либо `country` (тогда обязателен `countryCode`).

- Для `country`: ищется Направление страны — Направление, чей фильтр узлов
  равен флагу этой страны; если такого нет, оно создаётся: подпись
  «<флаг> <код>», фильтр узлов = флаг, авто-выбор лучшего узла (urltest)
  включён. Нет ни одного узла этой страны — ошибка с перечнем доступных
  стран, ничего не создаётся.
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
собственных шаблонов («Route Telegram through 🇩🇪 DE»).

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
`checkUrl`, `selectExitCountry`, `startVpn`, `stopVpn`.

### Индекс для натива

Нативу нужны подписи Направлений, страны, подключения (включая выключенные)
и правила по приложениям. Dart после каждой записи конфига и на старте
передаёт нативу сводку методом канала `setAssistantIndex(json)`; натив хранит
её в `lxbox_assistant` (приём `AutomationCache`). Это производное зеркало,
настройкой не является; Kotlin `lxbox_settings.json` по-прежнему не открывает.

```json
{"v":1,
 "route_final":"vpn-1",
 "directions":[{"tag":"vpn-1","name":"Proxy","enabled":true,
                "countries":[{"code":"DE","nodes":4}]}],
 "connections":[{"id":"…","name":"Office","type":"wireguard","enabled":false,"tag":"…"}],
 "app_rules":[{"name":"Telegram","packages":["org.telegram.messenger"],
               "package_regexes":[],"outbound":"vpn-2","conditional":false}]}
```

Индекса нет (приложение после обновления ещё не открывали) — чтения отвечают
ошибкой «Open L×Box once to finish setup.»

### Страна узла

Код страны = первая пара символов Regional Indicator в имени узла
(`[\u{1F1E6}-\u{1F1FF}]{2}`), переведённая в две латинские буквы. Узел без
флага страны не имеет и в отбор по стране не попадает. Чистая функция
`countryCodeOfTag` в Dart (индекс, Направление страны) и такая же в Kotlin
(`selectExitCountry`, `currentCountry` — по живым группам ядра).

Отвергнуто для этой задачи: GeoIP по адресу сервера (адрес входа ≠ страна
выхода, нужна база в APK), проба через каждый узел (трафик, время, запрос к
стороннему сервису), разбор кодов и слов в имени («IN», «NO», «IT» дают
ложные срабатывания). Точная страна выхода — в «Unresolved».

### Что видит ассистент (чужой текст в ответах)

- Имена серверов из подписок агенту **не отдаются** (как в §721): вместо них
  — код страны и число узлов.
- Отдаются: подписи Направлений, имена подключений, названия приложений и
  правил — после очистки: без управляющих символов и переводов строк, не
  длиннее 48 знаков.
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
| `POST /assistant/check-url` `{url, app?}` | `checkUrl` |
| `GET /assistant/apps?q=` | `findApps` |
| `GET /assistant/app-route?app=` | `getAppRoute` |
| `POST /assistant/exit` `{direction, country}` | `selectExitCountry` |
| `POST /assistant/app-route` `{app, target, country?}` | `setAppRoute` (сразу `applied`) |
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
  индекса), `AssistantLogic.kt` (чистая логика: страна по имени, выбор узла
  страны, маршрут приложения по индексу, класс стадии, совет, очистка
  текста), `AssistantRequests.kt` (заявка + уведомление),
  `UrlCheckRunner.kt` (проверка через сервисный клиент ядра).
- Kotlin, `vpn/`: метод проверки адреса на сервисной стороне
  (`ServiceCommandClient`), методы канала в `VpnPlugin`, приём extras заявки
  в `MainActivity`.
- Dart, `lib/services/assistant/`: `node_country.dart`,
  `assistant_index.dart` (сборка индекса), `assistant_actions.dart`
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
- Флаг в имени ставит поставщик подписки; он может не совпадать со страной
  выхода. Ассистент в ответе получает именно «страну по имени узла».
- Направление страны остаётся в списке Направлений после просьбы — это
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

1. JVM-тест `AssistantLogicTest`: страна по имени; выбор узла страны;
   маршрут приложения (точное имя, регулярка, условное правило, нет правила);
   класс стадии и совет; очистка текста; разбор индекса.
2. Dart-тесты: `countryCodeOfTag`; сборка индекса; `setAppRoute` (новое
   правило, замена выхода, создание и повторное использование Направления
   страны, нет узлов страны, правило выше по списку); `setConnectionEnabled`;
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

**В2. Что из имён отдаётся ассистенту** (в §721 решено имён узлов не
отдавать «до отдельного решения»).

- (а) **Подписи Направлений, имена подключений, названия приложений; серверы
  — только страной** — рекомендую, описано выше.
- (б) То же плюс имена отдельных серверов (тогда возможна просьба «переключи
  на сервер такой-то»; в ответы попадает текст из чужих подписок).
- (в) Никаких имён: только теги `vpn-N`, типы и коды стран.

## Unresolved / follow-up

- Точная страна выхода (проба через узел) и поиск по имени сервера.
- Фоновое применение изменений без окна приложения (В1-б).
- «Через какой выход сейчас идёт приложение» по живым соединениям.
- Проверка в Gemini — после открытия программы раннего доступа.
