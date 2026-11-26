# 750 — ИИ-ассистент управляет сетью: диагностика, маршрут приложения, подключения

| Field | Value |
|-------|-------|
| Status | In progress — код и документы в `develop`; CI 17.11.2026 зелёный (`checks` 44162361438, build-fast 44162010641); эмулятор Android 14 17.11: маршруты `/assistant/*` проверены (см. «Проверка на эмуляторе»); эмулятор Android 16 (API 36.1) 18.11: все 10 функций AppFunctions, шлюз `callApi`, мост и оба тумблера проверены через `adb` (см. «Проверка AppFunctions на эмуляторе»); телефон и вызов из Gemini не проверены |
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

## Решения владельца (17.11.2026)

1. **Страна выхода.** «Разве ИИ по имени не сможет легко предположить
   страны? в имени же обычно подписки кодируют или флагом или названием.
   кроме того есть диагностика». Своего признака страны и разбора имён в
   приложении нет; ассистент получает имена выходов как есть и сам решает,
   какие из них нужная страна; фактический выход подтверждает проверка
   выхода. Запрет §721 на имена узлов в ответах для этой задачи снят.
2. **Не узкие функции, а возможности Debug API.** «Зачем мы делаем эти
   лишние функции, почему мы не можем просто Debug API функционал дать?
   setAppRoute это же убожество какое-то, а если я хочу чтобы этот телеграм
   работал через vpn1 только на wifi?» Отдельной функции «маршрут
   приложения» нет: ассистент получает шлюз к обработчикам Debug API и сам
   собирает правило с любыми условиями (приложение, Wi-Fi, тип сети, домены).
3. **Dart-часть не в памяти.** «Дать ошибку или поднять самим». Шлюз сам
   открывает окно L×Box и ждёт готовности; если Android не дал открыть —
   ошибка агенту и уведомление.
4. **Подтверждение изменений.** Предложение исполнителя, владелец:
   «согласен». Каждое изменение не подтверждается; изменения через шлюз
   разрешает отдельный тумблер, выключенный по умолчанию.
5. **Никакого предрасчёта.** «Всё должно быть on-demand и отложено
   запускаться, а не предрасчёт делаться». Сводка настроек для натива не
   собирается ни на старте, ни при записи конфига; на запуск приложения и на
   запись конфига задача не добавляет ничего.

## Solution

### Два слоя

- **Нативные функции** — исполняются всегда, окно L×Box не нужно: старт,
  стоп и статус VPN (§721), список выходов, проверка адреса, проверка
  выхода, смена выхода, поиск приложения.
- **Шлюз к Debug API** — две функции: `getApiHelp` и `callApi`. Всё, что
  умеет разрешённая часть Debug API (правила, Направления, источники,
  действия), ассистент вызывает сам. Исполняет Dart, поэтому нужна живая
  Dart-часть приложения (см. «Когда Dart-часть не в памяти»).

Новая возможность пишется один раз как маршрут Debug API и доступна обоим:
ассистенту на устройстве и агенту с компьютера.

### Функции ассистента (AppFunctions)

Все — в `LxBoxAppFunctions`, все под тумблером «AI assistant control»
(`ensureEnabled()` первой строкой, в схеме `isEnabled = false`,
идентификаторы — в `AppFunctionsLogic.FUNCTION_IDS`). `startVpn` / `stopVpn`
/ `getVpnStatus` не меняются.

| Функция | Параметры | Ответ | Исполняет |
|---------|-----------|-------|-----------|
| `listExits` | `direction: String`, `query: String?` | `ExitList` | натив |
| `checkUrl` | `url: String`, `appPackage: String?` | `UrlCheckReport` | натив |
| `checkExit` | `direction: String` | `ExitCheck` | натив |
| `findApps` | `query: String` | `List<AppMatch>` (до 10) | натив |
| `selectExit` | `direction: String`, `exit: String` | `ExitSelection` | натив |
| `getApiHelp` | — | `ApiHelp` | Dart |
| `callApi` | `method: String`, `path: String`, `body: String?` | `ApiResponse` | Dart |

**`listExits`**: имена выходов Направления, как они записаны (с флагом и
названием). `direction` — тег. `query` — подстрока без учёта
регистра; ответ: `exits[]` (до 200), `total`, `truncated`.

**`checkUrl`** — проверка §687 на глубину `http`, `fresh = true`, от имени
приложения `appPackage`, если задан. Ждёт итог до 20 с. Ответ:

- `outcome`: `ok` / `failed` / `vpn_off` / `busy` / `timeout`;
- `failedStage`: `dns` / `route` / `tunnel` / `connect` / `tls` / `http` —
  класс стадии, на которой сбой (по стадии `root_cause`; неизвестный `kind`
  → `connect`);
- `error` — текст ошибки ядра (одной строкой, до 200 знаков);
- `httpStatus`, `elapsedMs`;
- `route`: `direction` (`outbound` стадии `route`; если правило ведёт прямо
  в узел — тег узла), `exit` (по цепочке стадий `group` → `selected`, иначе
  subject первой стадии `dial`), `direct`, `blocked`;
- `findings[]` — коды находок ядра;
- `advice` — одно-два предложения «что сделать» из таблицы приложения.

При остановленном туннеле проверка не запускается и VPN не включается:
`outcome = vpn_off`.

**`checkExit`** — фактический выход Направления: GET
`https://1.1.1.1/cdn-cgi/trace` через `direction` (§392). Ответ: `outcome`
(`ok` / `failed` / `vpn_off`), `country` (`loc=`), `ip` (`ip=`), `exit`,
`error`.

**`findApps`** — поиск установленного приложения по подстроке названия или
имени пакета: `packageName`, `label`.

**`selectExit`** — выбирает в работающем ядре выход `exit` (точное имя из
`listExits`) в Направлении `direction`. Ответ: `direction`, `exit`,
`changed`. Выбор живёт до перезапуска туннеля, как выбор пальцем. Группа с
автовыбором (urltest) ручного выбора не принимает — ошибка.

**`getApiHelp`** — карта разрешённых маршрутов (содержимое `/help`,
отфильтрованное белым списком): метод, путь, назначение, параметры.

**`callApi`** — вызов разрешённого маршрута. `method`: `GET` / `POST` /
`PUT` / `PATCH` / `DELETE`; `path` — путь со строкой запроса; `body` — JSON.
Ответ: `status` (как HTTP-код обработчика), `body` (JSON строкой, до 64 КБ;
больше — `413` с просьбой сузить запрос).

Пример «Telegram через vpn-1 только на Wi-Fi Home»: `findApps("Telegram")`,
затем `callApi("POST", "/rules?rebuild=true", {"name":"Telegram on Home",
"packages":["org.telegram.messenger"],"wifi_ssids":["Home"],
"outbound":"vpn-1"})` и `callApi("POST", "/action/reload-vpn")`.

### Шлюз

Dart, `lib/services/assistant/assistant_gateway.dart`: запрос проходит
проверку политики и передаётся тем же обработчикам, что обслуживают Debug
API (`buildDebugRouter`, тот же `DebugContext`, то же отображение ошибок),
минуя HTTP-сервер и токен. Включён ли сам Debug API (сервер на порту) — не
важно: шлюз работает и при выключенном.

**Политика** — чистая функция `(method, path, query) → allow / changes /
deny`:

| Группа | Маршруты | Решение |
|--------|----------|---------|
| Чтения | `GET /state`, `/state/rules`, `/state/vpn`, `/state/subs`, `/rules*`, `/directions*`, `/subs`, `/subs/{id}`, `/subs/{id}/rules*`, `/folders*`, `/pool`, `/assistant/*`, `/settings/{node_sort,enabled_groups,tun_apps,ping_options}` | allow |
| Диагностика | `POST /assistant/check-url`, `/assistant/check-exit`, `/action/check-config`, `/action/urltest*`, `GET /chains/{tag}/probe`, `POST /folders/{id}/probe` | allow |
| VPN и выбор | `POST /action/{start-vpn-headless,stop-vpn,reconnect,reload-vpn,reset-network,switch-node,set-group}`, `POST /assistant/exit` | allow |
| Изменения | `POST/PATCH/DELETE /rules*`, `/directions*`; `PATCH /subs/{id}` (только поля `enabled` и `name`), `POST /subs/{id}/refresh`, `POST /action/{refresh-subs,rebuild-config}`, `POST /settings/rebuild-config`, `PUT /settings/{route_final,node_sort,enabled_groups,tun_apps}`, `POST /assistant/connection` | changes |
| Закрыто | всё остальное, в том числе `/config`, `/backup`, `/files`, `/logs`, `/diag`, `/nodes`, `/mixins`, `/warp`, `/taildrop`, `/support`, `/profiler`, `/core_reject`, `/wifi_history`, `/device`, `/settings/vars`, `/settings/dns_options`, `/settings/config_locked`, `/settings/vpn/*`, `/settings/core_logs*`, `/settings/vpn_mode` (ответ содержит пароль локального прокси, запись открывает прокси), `GET /chains`, `/chains/{tag}` (в `rewrite` могут лежать адреса и ключи), создание и удаление источников (`POST /subs`, `DELETE /subs/{id}`, запись в `/folders`, `/chains`), смена `url` подписки, любой запрос с `reveal` или `warnings` | deny → `403` |

`changes` исполняется, только если включён тумблер «Let assistants change
settings»; иначе `403` с текстом «Changing settings is turned off in L×Box:
App Settings → Automation → Let assistants change settings.»

В ответах шлюза поля `error`, `last_error`, `last_start_error` проходят
маскировку сетевых адресов (`maskNetworkAddresses`): текст ошибки ядра
содержит `IP:port` сервера. Ссылки подписок без `reveal` отдаются как
`scheme://host/***`.

Шлюз `/settings/vars` не пропускает, поэтому ассистент оба тумблера себе
не включит. Самому Debug API они доступны через общий `PUT /settings/vars`,
как и в §721 — решение владельца 17.11.2026: «Debug API полный доступ имеет
по дизайну».

Почему закрыто: сырой конфиг, бэкап, логи и ссылки подписок содержат ключи
и адреса; миксины и DNS-настройки позволяют перенаправить трафик в обход
видимых правил; добавление источника — способ подменить выход целиком.

### Когда Dart-часть не в памяти

`callApi` / `getApiHelp` идут из натива в Dart через мост
`AssistantBridge` (приём `AutomationBridge`: канал ставит `VpnPlugin` при
подключении движка). Движка нет:

1. натив пробует открыть окно L×Box (`startActivity` с `MainActivity`);
2. ждёт до 10 с, пока мост появится и обработчики перестанут отвечать
   «controller not ready», затем исполняет вызов;
3. не дождался (Android не дал открыть окно из фона) — показывает
   уведомление «Open L×Box to let the assistant continue» с переходом в
   приложение и возвращает агенту ошибку «L×Box is not open. Open the app
   and repeat.»

Сработает ли шаг 1 при вызове от ассистента, зависит от ограничений Android
на запуск окон из фона и проверяется только на устройстве.

После §747 мост становится межпроцессным (`:bg` → `:ui`), шаги те же.

**После 747: как идёт вызов** (подробно — `ARCHITECTURE.md` → «Process
boundary», спека 747 → «Интеграция с задачей 750»):

- AppFunctions исполняются в процессе `:bg`; на время функции процесс
  удерживается и сам не завершается.
- Нативные операции (`AssistantCore`) — там же, рядом с ядром. Для Debug API
  окна те же операции — методы `assistant*` канала плагина; окно пересылает
  их в `:bg`, ответ и коды ошибок прежние.
- Шлюз: `AssistantBridge` (`:bg`) → обратный вызов `UiCalls` → окно исполняет
  `assistantCall` в Dart → ответ `{status, body}` возвращается в `:bg`. «Мост
  есть» — окно подключено к `:bg` и подтвердило получение запроса (2 с).
- Моста нет (окно закрыто, не подключилось, заморожено системой при
  остановленном туннеле): как описано выше — открыть окно, ждать до 10 с,
  уведомление и `app_not_open`. При работающем туннеле свёрнутое окно живо и
  отвечает; на время вызова окно удерживается и при остановленном.

### Обзор сети — по требованию

`GET /assistant/overview` (ассистенту — через `callApi`): `vpn_status`;
`directions[]` — `tag`, `name` (подпись пользователя), `exit_count`,
`current_exit`; `connections[]` — `id`, `name`, `type` (`wireguard` /
`amneziawg` / `openvpn` / `openconnect` / `tailscale`), `enabled`, `state`
(`up` / `connecting` / `idle` / `needs_login` / `down` / `disabled` /
`unknown`; у OpenVPN всегда `unknown`); `default_route`.

Обработчик в момент запроса собирает из настроек сводку (подписи
Направлений, подключения включая выключенные, правила по приложениям) и
передаёт её нативу аргументом вызова; натив добавляет живое состояние ядра
(выходы, выбранный выход, состояния подключений). Сводка нигде не хранится
и заранее не считается. Так же устроен `GET /assistant/app-route`.

### Что видит ассистент

- Имена выходов, подписи Направлений, имена подключений, названия приложений
  и правил в ответах нативных функций — после очистки: без управляющих
  символов и переводов строк, до 64 знаков.
- Через шлюз — ответы разрешённых обработчиков Debug API как есть.
- Никогда: содержимое конфига, ключи, ссылки подписок, бэкап, логи.
- `checkExit` отдаёт внешний адрес выхода.

### Тумблеры

App Settings → Automation, раздел «AI assistants» (Android 16+):

- **AI assistant control** (`appfunctions_enabled`, как в §721) — все функции.
  Подпись: «Let Android assistants control the VPN, run network checks and
  read your routing setup (Android 16+)».
- **Let assistants change settings** (`appfunctions_allow_changes`, по
  умолчанию выключен; активен, только когда включён первый) — группа
  «Изменения» шлюза. Подпись: «Assistants can add and edit routing rules and
  Directions and turn sources on or off without asking».

Оба — в `vars`, в бэкапе рядом с `appfunctions_enabled`. Второй тумблер
читает сам шлюз (Dart), зеркало в натив ему не нужно.

### Debug API — новые маршруты `/assistant`

| Маршрут | Делает |
|---------|--------|
| `GET /assistant/overview` | обзор сети |
| `GET /assistant/exits?direction=&q=` | выходы Направления |
| `POST /assistant/check-url` `{url, app?}` | проверка адреса |
| `POST /assistant/check-exit` `{direction}` | фактический выход |
| `GET /assistant/apps?q=` | поиск приложения |
| `GET /assistant/app-route?app=` | какое правило ловит приложение и куда ведёт |
| `POST /assistant/exit` `{direction, exit}` | смена выхода |
| `POST /assistant/connection` `{id, enabled}` | включить/выключить подключение (флаг, пересборка, reload; при включении и остановленном туннеле — старт) |

Проверки и живое состояние Dart берёт у натива методами канала
(`assistantOverview`, `assistantCheckUrl`, …) — логика одна. Правила создаются существующим
`POST /rules`.

### Файлы

- Kotlin, `appfunctions/`: `LxBoxAppFunctions.kt`, `AssistantTypes.kt`,
  `AssistantLogic.kt` (чистая логика), `AssistantCore.kt` (операции над ядром), `AssistantBridge.kt` (мост в Dart,
  открытие окна, уведомление); `vpn/ServiceCommandClient.kt` (сервисные
  вызовы групп, состояний, выбора, GET через узел), `vpn/VpnPlugin.kt`
  (методы канала, установка моста).
- Dart, `lib/services/assistant/`: `assistant_index.dart` (сборка сводки),
  `assistant_actions.dart` (`setConnectionEnabled`),
  `assistant_gateway.dart` (политика, исполнение, справка);
  `lib/services/debug/handlers/assistant.dart`; тумблер —
  `automation_tab.dart`, `settings_storage.dart`.
- Тесты: `AssistantLogicTest.kt`; `test/services/assistant/*_test.dart`,
  `test/services/debug/assistant_handler_test.dart`.

## Docs to update

- `docs/AI_ASSISTANT.md` + `docs/AI_ASSISTANT.ru.md` — пользовательский гайд;
  ссылки из `docs/README.md`, `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md`.
- `docs/AUTOMATION.md` / `.ru.md` — раздел «AI assistants (AppFunctions)»:
  новый перечень функций, ссылка на гайд.
- `docs/api/debug-api-reference.md` — раздел `/assistant`; `handlers/help.dart`.
- `docs/ARCHITECTURE.md` — шлюз и мост ассистента.
- `docs/spec/features/014-AUTOMATION/` — функция `assistant-control` + строка
  в `FEATURE.md` (en/ru).
- `docs/PRIVACY_POLICY.md` / `.ru.md` — что получает ассистент.
- `CHANGELOG.md` → Unreleased.
- `RELEASE_NOTES.md`, `pubspec.yaml` — `[deferred till release]`.

## Risks and edge cases

- AppFunctions API экспериментальный; вызывать функции из Gemini могут только
  участники программы раннего доступа. До её открытия пользователь увидит
  изменения только через Debug API и `adb shell cmd app_function`.
- Шлюз даёт ассистенту много: при включённом втором тумблере ошибка или
  обманутый ассистент может изменить маршрутизацию. Защита — белый список,
  отдельный тумблер, закрытые секреты. Подтверждения каждого изменения нет.
- Требования Google Play к AppFunctions (с 14.04.2027): обобщённая функция
  `callApi` и чужой текст в ответах (имена узлов) могут потребовать правки —
  вернуться при подготовке к этой дате.
- Открытие окна из фона Android может запретить — тогда ошибка и уведомление.
- Kotlin-тесты и компиляция Kotlin на CI `checks` не гоняются — проверяются
  локально и сборкой APK.
- Имя узла пишет поставщик подписки; флаг в нём может не совпадать со
  страной выхода. Для этого есть `checkExit`.
- `checkExit` обращается к `1.1.1.1` через туннель.
- `config_locked_for_debug` включён — пересборка отклоняется обработчиком.

## Verification

1. JVM-тест `AssistantLogicTest`: очистка текста; разбор сводки; поиск
   выходов; маршрут приложения по сводке; разбор `cdn-cgi/trace`; класс
   стадии и совет; состояния подключений.
2. Dart-тесты: сборка сводки; `setConnectionEnabled`; политика шлюза (по
   строке на группу таблицы, `reveal`, выключенный тумблер изменений);
   исполнение через шлюз (чтение, изменение, закрытый маршрут, ответ больше
   предела); справка содержит только разрешённое; хендлеры `/assistant/*`.
3. Локально: `flutter analyze`, `:app:compileDebugKotlin` (схема KSP: все
   функции `enabledByDefault=false`), `:app:testDebugUnitTest`,
   `boundary_check --strict`.
4. Эмулятор Android 16, если доступен: `adb shell cmd app_function
   execute-app-function` для каждой функции при выключенных и включённых
   тумблерах; `callApi` при открытом и закрытом окне; `/assistant/*` через
   `adb forward`.
5. CI `checks` зелёный на голове `develop`.

## Проверка на эмуляторе (17.11.2026)

`emulator-5554`, AVD LxBox_test, Android 14 (API 34), APK из CI build-fast
44162010641 (2.25.22-dev.53, коммит `e51125fb`), Debug API через `adb forward`.

| Что | Результат |
|-----|-----------|
| `GET /assistant/overview`, туннель остановлен | Направления с подписями и числом выходов, 8 подключений: выключенные `disabled`, остальные `down` |
| `GET /assistant/overview`, туннель поднят | `current_exit` заполнен; AmneziaWG и Tailscale — `up`, OpenConnect — `down` |
| `GET /assistant/exits?direction=vpn-1` | 20 имён, `truncated: false` |
| `GET /assistant/apps?q=chrom` | `com.android.chrome` / Chrome |
| `GET /assistant/app-route?app=com.android.chrome` | `vpn-1`, правила нет |
| `POST /assistant/check-url`, туннель остановлен | `outcome: vpn_off`, совет |
| `POST /assistant/check-url` `https://example.com` (и с `app`) | `ok`, HTTP 200, `route.direction: vpn-1`, `route.exit` — выбранный узел |
| `POST /assistant/check-url` несуществующее имя | `failed`, `failed_stage: dns`, `error: rcode NXDOMAIN`, совет про DNS |
| `POST /assistant/check-exit` | `country: FI`, `ip` заполнен; через нерабочий узел — `failed` с текстом ошибки |
| `POST /assistant/exit` | выход сменился (`changed: true`), обзор показывает новый; неизвестное имя — `not_found` |
| `POST /assistant/connection` выкл/вкл | `applied`; после перезагрузки ядра состояние `disabled`, затем `up`; неизвестный id — `not_found` |

Не проверено: всё, что требует Android 16, — вызов функций через
`adb shell cmd app_function` (на эмуляторе сервиса `app_function` нет), шлюз
`getApiHelp` / `callApi`, мост с открытием окна и уведомлением, оба тумблера
(раздел AI assistants на Android 14 скрыт). JVM-тесты Kotlin после правок
этапа 2 не запускались.

**Дополнение 18.11.2026 (сессия задачи 747, эмулятор `LxBox_a16`, Android 16,
API 36.0, сборка образа 13894323).** На ветке `task/747-two-processes`
(`a5cc2e0b`) `AssistantLogicTest` (24) и `AppFunctionsLogicTest` (6) зелёные,
Dart-тесты ассистента (118) зелёные; маршруты `/assistant/*` через границу
процессов отвечают в прежней форме. `adb shell cmd app_function` на этом
образе отвечает «No shell command implementation»: сервис есть
(`dumpsys app_function`), shell-команд нет. Поэтому функции AppFunctions,
шлюз `getApiHelp` / `callApi`, мост и тумблеры на устройстве по-прежнему не
проверены и уходят в `v2.25.23-rc.1` в таком виде. Пути проверки: образ
`android-36.1` (есть ли там команда — не проверено) или отладочный вызов
своих функций из самого приложения через `AppFunctionManager` — отдельная
задача, не начата.

### Проверка AppFunctions на эмуляторе (18.11.2026)

Эмулятор `LxBox_a161`: Android 16, API 36.1 (образ `google_apis`, arm64,
сборка BE4B.251210.005), APK 2.25.22-dev.83 (код = `v2.25.23-rc.1`, два
процесса). В этом образе `adb shell cmd app_function` есть. Вызовы —
`execute-app-function … --brief-yaml`.

| Что | Итог |
|---|---|
| `list-app-functions` | все 10 функций в индексе системы, `enabledByDefault: false` |
| Тумблер «AI assistant control» выключен | любая функция — «The app function is disabled» (код 1002) |
| Вкладка Automation | раздел AI assistants виден; второй тумблер неактивен, пока выключен первый; включение первого пишет зеркало `appfunctions_enabled=true` |
| `getVpnStatus`, `startVpn`, `stopVpn` | `stopped` → `started` → `stopped`; без согласия на VPN `startVpn` — «VPN permission is not granted. Open L×Box and connect once.» |
| `listExits` | список выходов Направления; `query` фильтрует (`total`, `truncated`); неизвестное Направление — «No such direction.» |
| `findApps` | `chrome` → `com.android.chrome` |
| `checkUrl` | VPN выключен — `vpn_off`; при включённом — маршрут (`direction`, `exit`), `failedStage` `connect` / `tunnel` / `tls` / `dns` и совет под стадию; `appPackage` принимается |
| `checkExit` | VPN выключен — `vpn_off`; через `direct-out` — `ok` с `ip` и `country`; нерабочий выход — `failed` с текстом ошибки |
| `selectExit` | `changed: true`, повтор — `changed: false`; неизвестный выход — «No such exit in this direction.» |
| `getApiHelp` | `200`, тело справки шлюза |
| `callApi`, чтение | `/assistant/overview`, `/assistant/app-route`, `/rules` — `200`; `/config` — `403` «not available to assistants» |
| `callApi`, изменение, второй тумблер выключен | `403` «Changing settings is turned off in L×Box: …» |
| `callApi`, изменение, второй тумблер включён | `POST /assistant/connection` выкл/вкл — `applied`; `POST /rules` (пакет + Wi-Fi SSID) — `201`, `app-route` показывает правило с `conditional: true`; `DELETE /rules/{id}` — `200`; `PUT /settings/vars` — `403` |
| Шлюз, окно свёрнуто, туннель работает | отвечает сразу |
| Шлюз, окно свёрнуто, туннель остановлен, процесс окна заморожен системой (`isFrozen=true`) | отвечает сразу |
| Шлюз, процесса окна нет (убит), туннель работает | Android запрещает открыть окно из фона («Background activity launch blocked»); через 10–11 с ошибка «L×Box is not open. Open the app and repeat.» (код 3501) и уведомление «Open L×Box to let the assistant continue» (канал `lxbox_assistant`) |
| Нативные функции без процесса окна | `getVpnStatus`, `listExits` отвечают |

Наблюдения:

- Сразу после изменения, которое перезагружает ядро (`POST
  /assistant/connection`, `POST /rules`), `selectExit` несколько секунд
  отвечает «The VPN core is not reachable yet. Try again in a few seconds.»,
  а `checkUrl` / `checkExit` — `failed` с сырой ошибкой ядра «rpc error: …
  invalid argument». После паузы всё отвечает. Исправлено 18.11.2026: ошибку
  связи с ядром (`rpc error: …`) `checkUrl` и `checkExit` отдают так же, как
  `selectExit`, — ошибкой `core_error` «The VPN core is not reachable yet. Try
  again in a few seconds.» (`AssistantLogic.isCoreTransportError`); на
  эмуляторе после правки не проверено.
- Уведомление «Open L×Box…» не показывается, пока приложению не выдано
  разрешение на уведомления (на свежей установке его нет); ошибка агенту
  приходит в любом случае.
- Запрет открытия окна из фона получен при вызове из `adb shell`; у системного
  ассистента привилегии могут быть другими — не проверено.

Не проверено: успешный `checkUrl` (`outcome: ok`) — у эмулятора TLS до
внешних сайтов не проходит ни через один выход; переход по тапу на
уведомление; русские строки раздела; вызов из Gemini; релизная сборка тега
(проверялась сборка ветки с тем же кодом); телефон.

## Unresolved / follow-up

- Исполнение шлюза без окна (фоновый Dart-исполнитель) — после §747.
- «Через какой выход сейчас идёт приложение» по живым соединениям.
- Состояние OpenVPN-подключения.
- Проверка в Gemini — после открытия программы раннего доступа.
