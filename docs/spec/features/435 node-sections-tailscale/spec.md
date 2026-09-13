# 435 — Секции узла и Tailscale (контракт ## 13, NODE_SECTIONS.md, ONE_NAMESPACE.md §2)

Статус: **in progress** — волна 2 программы контракта 1.0 (после ## 12, [§434](../../tasks/434-srs-rule-multiple-rule-sets.md)).
Норма — `app/contract/docs/NODE_SECTIONS.md` (семантика) и
`app/contract/docs/ONE_NAMESPACE.md` §2 (форма записей). Решения владельца
14.09.2026: секции в состоянии сразу в целевой форме `body`; в бэкап до
контракта 1.0 не экспортируются; AAR libbox пересобирается с `with_tailscale`
(отдельный шаг, см. §10).

## 1. Мотив

Узел Tailscale бесполезен без связки: DNS-сервер типа `tailscale`, привязанный
к нему, DNS-правило на `*.ts.net`, правило маршрута на `100.64.0.0/10`. Та же
связка нужна WireGuard-узлу с подсетями за пиром. Узел носит связку **с
собой** в поле `sections`; сборка дописывает записи к общим спискам перед
обычным резолвом. Никаких пресетов, ссылок из состояния на узел и неявной
префиксации тегов.

Что это даёт пользователю LxBox:

- узел Tailscale из sing-box JSON (`endpoints[]`/`outbounds[]`) принимается,
  хранится и собирается в конфиг; на ядре без тега — хранится и выбрасывается
  только при сборке с предупреждением;
- «Add server → Tailscale»: мастер собирает узел с канонической связкой;
- целый sing-box-конфиг с одним узлом и его DNS/маршрутами импортируется
  **со связкой**, а не только с outbound'ом;
- правила узла видны в Routing на общей оси, DNS-записи узла — на экране DNS.

## 2. Форма записей (ONE_NAMESPACE §2) и где они живут

```jsonc
"sections": {
  "rules": [
    { "kind": "inline", "id": "<uuid>", "name": "@{self} network", "enabled": true, "num": 945,
      "body": { "ip_cidr": ["100.64.0.0/10"], "outbound": "@self" } }
  ],
  "dns": {
    "servers": [ { "kind": "user", "tag": "@{self}-dns", "enabled": true,
                   "body": { "type": "tailscale", "endpoint": "@self" } } ],
    "rules":   [ { "kind": "user", "name": "", "enabled": true,
                   "body": { "domain_suffix": [".ts.net"], "server": "@{self}-dns" } } ]
  }
}
```

| Место | Ключ | Кто пишет |
|---|---|---|
| `server_lists[].type=user` | `sections` (необязателен; пустой не пишется) | `UserServer.toJson` |
| `server_lists[].type=folder` → `members[]` | `sections` (то же) | `FolderMember.toJson` |
| подписка, цепочка, Направление | поля нет | — |

Правило записи: **сущность = метаданные приложения + `body` = объект sing-box
как есть** (владелец, 14.09.2026). Тег в метаданных — единственное
исключение. Плейсхолдеры `@self`/`@{self}` в состоянии лежат **как есть**;
подстановка — при сборке и при показе.

### 2.1 Модель

`lib/models/node_sections.dart`:

```dart
final class NodeSections {
  final List<CustomRule> rules;        // только inline | srs
  final List<DnsServerRef> dnsServers; // только DnsServerInline (запись kind: user)
  final List<DnsRuleRef> dnsRules;     // только DnsRuleInline  (запись kind: user)
  bool get isEmpty;
  Map<String, dynamic> toJson();                       // форма §2 через кодек
  static NodeSections? fromJson(Object? j, {List<String>? dropped}); // null = пусто/нет
  NodeSections substituteSelf(String finalTag);        // §5, через JSON-обход
}
```

Типизация через существующие `CustomRule` и `DnsServerRef`/`DnsRuleRef`, а не
сырые карты: экран Routing показывает `summary()`, работает `withEnabled`,
DNS-экран рендерит `DnsServerInline.body` тем же кодом, что корневые записи.
Чужой `kind` записи (`preset`, `json`, `template`, `srs` у DNS) при чтении
отбрасывается, причина — в `dropped` (UI редактора узла показывает, Debug API
отдаёт как есть после отброса).

`DnsRuleInline` получает поле `enabled` (по умолчанию `true`; `toJson` пишет
`enabled: false` только когда выключено — байт-совместимость хранения
`dns_options.rules`). Сборка (`applyCustomDns`) уже пропускает записи с
`enabled != true`; резолвер `resolveDnsRulesList` дописывает `enabled: true`
там, где ключа нет — поведение корня не меняется.

### 2.2 Кодек записей — будущий корневой парсер 1.0

`lib/models/record_codec.dart` — единственное место перевода между типами
LxBox и формой записи ONE_NAMESPACE (условие владельца: не времянка для
секций, а общий код, на который волна 4 переключит корень):

| Функция | Запись → тип | Что кладёт в `body` |
|---|---|---|
| `ruleToRecord(CustomRule)` / `ruleFromRecord(Map)` | `inline` ↔ `CustomRuleInline`; `srs` ↔ `CustomRuleSrs` (+ `refs[]` снаружи); `preset` ↔ `CustomRulePreset` (`ref` + `vars`, корень) | ключи sing-box: `domain`, `domain_suffix`, `domain_keyword`, `ip_cidr`, `port` (int[]), `port_range` (string[]), `package_name`, `protocol`, `network`, `ip_is_private`, `source_ip_cidr`, `source_ip_is_private`, `inbound`, `wifi_ssid`, `wifi_bssid`; действие — `outbound` либо `action: reject` (`kOutboundReject`) |
| `dnsServerToRecord` / `dnsServerFromRecord` | `user` ↔ `DnsServerInline`; `preset`/`template` ↔ `DnsServerPreset`/`DnsServerTemplate` (корень) | тело сервера без `tag` |
| `dnsRuleToRecord` / `dnsRuleFromRecord` | `user` ↔ `DnsRuleInline`; `preset`/`template` (корень) | тело правила (`server` внутри) |

Поля записи вне `body`: `kind`, `id` (LxBox пишет всегда, читает
необязательным), `name`/`tag`, `enabled`, `num`, `refs`, `dns{}`/`resolve{}`
(расширения LxBox). Незнакомые ключи `body` при чтении отбрасываются, список
возвращается вызывающему (`unknownKeys`) — редактор узла показывает их одной
строкой, сборка молчит. Незнакомые ключи корня записи игнорируются молча
(так вторая сторона игнорирует наши `dns{}`/`resolve{}`).

### 2.3 Узел Tailscale — `TailscaleSpec`

`lib/models/node_spec.dart`: новый вариант sealed-иерархии.

- `body` — тело endpoint'а sing-box как есть без `type`/`tag`/`detour`
  (`auth_key`, `control_url`, `hostname`, `ephemeral`, `accept_routes`,
  `exit_node`, `exit_node_allow_lan_access`, `advertise_routes`,
  `advertise_exit_node`, `udp_timeout`, `state_directory`, dial-поля …). Не
  типизируем намеренно: контракт тела не разбирает, а типизация потеряла бы
  незнакомое молча.
- `server = ''`, `port = 0`, `protocol = 'tailscale'`; `isGroup = false`.
  Новый признак `NodeSpec.isAddressless` (true у группы §322 и у Tailscale):
  инвариант `isAddressless ⇔ server.isEmpty && port == 0` заменяет прежний
  `isGroup ⇔ …` в тесте; подписи вида `TYPE · server:port` (пикер detour,
  строка члена папки, подпись источника) опускают адрес у безадресных.
- `emitRaw` → `Endpoint({type: tailscale, tag, ...body})`; `detour` — как у
  остальных, через `chained`.
- `toUri()` → JSON-текст endpoint'а с `tag` (URI-формы у схемы нет; текст
  парсится обратно `decode()` как `singboxOutbound`). Это делает
  `rawBody`/`raw` члена папки, переименование (`_rawWithName` знает JSON) и
  эмодзи (`prependEmojiToRawBody` знает JSON) рабочими без веток.
- `hasExitNode` = непустой `exit_node`. Без него узел **не кандидат
  Направлений** (не попадает в selector/auto), но законная цель `detour` и
  `outbound` правила.
- Идентичность пула (`nodeIdentityKeyRaw`) — `null` (адреса нет), как у
  группы; идентичность источника (`sourceNodeIdentities`) — по тегу, как у
  всех.
- Проба (`probe_config.dart`): узел не тестируется (`brokenByIndex = 'no-address'`),
  на Home — «—» вместо задержки. Экспортируемая связка внутри probe-конфига
  запускала бы tsnet ради пинга; не делаем.
- Эмодзи по умолчанию (`defaultEmojiFor`): `🪢`.

## 3. Разбор

### 3.1 `parseSingboxEntry`: `case 'tailscale'`

Принимается без `server`/`server_port` из `outbounds[]` и `endpoints[]`
(`_allEntries` уже читает оба). Тег пустой → `tailscale`. Никаких проверок
полей тела: сторона, чьё ядро без тега, всё равно должна узел хранить.

Корпус: `body/singbox/tailscale_endpoint` → `kind: endpoint`, `scheme:
tailscale`. Раннеры `contract_test`/`body_contract_test` добавляют
`tailscale` в `_endpointSchemes`.

### 3.2 Целый конфиг как источник (NODE_SECTIONS §6)

`singbox_config.dart` `_parseOne`: если конфиг дал **ровно один**
не-групповой узел, из `dns`/`route` извлекается его связка:

- DNS-серверы, у которых `detour` или `endpoint` равны тегу узла (или уже
  `@self`) → записи `kind: user`, `tag: '@{self}-<тег сервера>'`, `body` с
  `detour`/`endpoint` → `@self`;
- DNS-правила, чей `server` — один из взятых серверов → записи `kind: user`,
  `name: ''`, `body` с `server` → `@{self}-<тег>`;
- правила маршрута, чей `outbound` равен тегу узла → записи `kind: inline`,
  `name` = `body.name`, если провайдер его дал, иначе `@{self} rule N` (N —
  порядковый среди правил этого узла, с 1 — как у лаунчера, ответ 14.09),
  `num` = 945 + i (порядок извлечения; в конверт корпуса номер и `id` не
  идут), `body` с `outbound` → `@self` (дописывается, если нет ни
  `outbound`, ни `action`). Ключи `body`, которых кодек не знает (`rule_set`
  на набор конфига и т. п.), — в `unknownKeys` записи.

Всё остальное в `dns`/`route` игнорируется, как раньше. Результат кладётся в
`NodeSpec.importedSections` (mutable, не сериализуется — как
`sourceCompact`); контейнер (`addFromInput`, `addMembersToFolder`, редактор
узла) переносит его в `UserServer.sections` / `FolderMember.sections` **при
добавлении**. При перечитывании `raw_body` на старте `importedSections`
игнорируется: истина — поле контейнера.

### 3.3 Документ с `sections`

`{ "endpoints"|"outbounds": [тело], "sections": {…} }` — flavor
`singboxConfig` с ключом `sections`: секции читаются кодеком (§2.2) и
кладутся в `importedSections` того же единственного узла; извлечение из
`dns`/`route` при этом не выполняется. Оба вида в одном документе — ошибка
**редактора узла** (сохранение отказано с текстом); парсер подписок в такой
ситуации берёт `sections` и добавляет warning на узел
(`SectionsConflictWarning`, только UI, кода контракта нет).

У подписок `importedSections` никуда не переносится — секции только у
свободных узлов.

## 4. Сборка = инъекция (NODE_SECTIONS §3)

`build_config.dart`, после `list.build(ctx)` для всех источников:

1. **Финальные теги.** `EmitContext` получает `noteEmitted(NodeSpec, String
   finalTag)`; `ServerListBuild.build` зовёт его для каждого эмитированного
   `main`. `_BuildCtx` копит `emittedTagByNode`. Узел выключен (список или
   член), отброшен гейтом ядра или не разобран — в карте отсутствует →
   секции не инжектятся.
2. **Правила.** Для каждого `UserServer.sections` / `FolderMember.sections`
   с известным финальным тегом: `sections.substituteSelf(tag)` → правила с
   `orderNum == null` получают **945** → добавляются в список
   `settings.customRules` **до** `normalizeRuleOrder` — сортировка на общей
   оси вместе с корнем и якорями пресетов, дальше обычный
   `applyAllCustomRules` (headless rule_set, srs с кэшем по `cacheIds`,
   DNS-mirror, resolve — всё как у корня; `enabled: false` пропускается там
   же). Имя rule_set = имя правила после подстановки; дубль имени уникализирует
   реестр.
3. **DNS.** `applyCustomDns` получает `nodeDnsServers` и `nodeDnsRules`
   (записи после подстановки). Серверы подаются в `resolveDnsServersBodies`
   отдельным списком **после** корневых refs и **до** фильтра членов групп
   (иначе сервер узла, добавленный позже, вылетел бы из группы как
   `unknown`); дубль тега — первый побеждает, warning. Правила — в конец
   `dns.rules` после пользовательских и mirror-группы. `enabled: false` —
   пропуск. `normalizeDnsDetour` снимает `detour` у `type: tailscale` (как у
   `group`): у этого типа сервера поля `detour` нет, ядро отвергло бы конфиг.
4. **Санитайзер `endpoint`.** Для любого DNS-сервера (корневого или узлового)
   с `type: tailscale`: `endpoint` не среди эмитированных endpoint'ов → сервер
   выбрасывается целиком с warning; правило, чей `server` был выброшен, тоже
   выбрасывается с warning (DNS-правило без `server`/`action` ядро отвергает).
   Второй сервер на тот же `endpoint` → выбрасывается (ограничение ядра: не
   больше одного на узел). Реализация — в `resolveDnsServersBodies` рядом с
   `normalizeDnsDetour`, поэтому работает и для серверов, добавленных формой
   DNS-сервера (§9.4).
5. Дальше обычный конвейер без узловых веток: `sanitizeOutboundGraph`,
   `healDanglingResolveServers`, валидатор.

**Инвариант:** состояние без единого узла с секциями даёт байт-в-байт тот же
конфиг (тест: конфиг до/после с пустыми `sections`).

### 4.1 `state_directory`

После эмиссии: у каждого `ctx.endpoints` с `type: tailscale` без
`state_directory` — `<BuildSettings.tailscaleStateRoot>/tailscale/<финальный тег>`.
Корень передаёт контроллер: native `Context.filesDir`
(`BoxVpnClient().getFilesDir()`, тот же канал, что у §316); пустой корень
(юнит-тесты) — поле не пишется. В хранимое тело путь **не** пишется; экспорт
его не увидит. Имя каталога = тег, где всё вне `[A-Za-z0-9._-]` заменяется
на `_` (пробелы, `/`, `:` префикса), пустой результат → `tailscale` — тот же
allowlist, что у лаунчера (ответ 14.09), каталог один на узел, а не дерево.

### 4.2 Гейт ядра — `tailscale_core_unsupported`

`core_chain_capability.dart` (файл получает второго жильца, имя оставляем):
`coreSupportsTailscale(String coreVersion)` — версия ≥
`kTailscaleMinCoreVersion` (`1.14.0-lx.38`, первый релиз AAR с тегом; ядро
сейчас на lx.37, пин LxBox — lx.36). Политика та же, что у `chain`: пустая
или неразобранная версия → **поддержка есть** (деградировать на догадке
нельзя). `ServerListBuild.build` пропускает `TailscaleSpec` при `!supported` и
пишет warning через `ctx.warn(...)` (новый метод `EmitContext`, дефолт —
no-op): «Tailscale node "X" skipped: the installed core lacks with_tailscale
(lx.38 or newer required)». Конфиг собирается, остальные узлы на месте; секции
такого узла не инжектятся (п. 1). Вход в списки Направлений и cache Debug
API не меняются — узел живёт в состоянии.

## 5. Плейсхолдер `@self` (NODE_SECTIONS §2)

`substituteSelf(Object json, String tag)` — обход JSON: строка ровно `@self`
→ тег; иначе все вхождения `@{self}` → тег; ключи объектов не трогаются;
`@selfish`, `@self_dns` остаются. Применяется к записям (JSON) перед
переводом кодеком в типы — так покрыты все строковые значения на любой
глубине без пер-типовых веток. В UI подпись после подстановки строится тем же
вызовом с финальным тегом узла из последней сборки (`HomeState`), а до первой
сборки — с `TagResolver.displayTag(prefix, node.tag)`.

## 6. Бэкап (BACKUP.md, ONE_NAMESPACE §4)

- **Экспорт:** `servers[].sections` до контракта 1.0 **не пишется** (решение
  владельца; версия 0.13.0 не выпускается). Узел с непустыми секциями даёт
  `backup_local_only_dropped` с полем `sections` (принцип П6 «нет молчаливых
  потерь»: пользователь видит, что связка в файл не поехала); узел без секций
  — тишина, собственный экспорт без секций предупреждений не даёт.
- **Импорт 0.12:** `sections` добавляется в `_serverKeys` — поле объявлено в
  схеме как поле лаунчера, значит игнорируется **молча** (BACKUP.md §1), без
  `backup_unknown_field`. В состояние не кладётся: форма 0.12 (`match`/`value`)
  — второй парсер, которого быть не должно. Кармана провоза у LxBox нет
  (§401 П3).
- `chains[].sections` / `subscriptions[].sections` в схеме нет → прежнее
  `backup_unknown_field`. Код `backup_section_record_dropped` LxBox до 1.0 не
  заводит: заводить константу без реестра нельзя (`registry_sync_test`), а
  реестр лаунчера его пока не содержит.
- Корпус: кейс секций в бэкапе будет только в 1.0 (`v10_node_sections`,
  `lx_backup: 2`); 0.12-кейса не будет. Раннер `backup_corpus_test` файл с
  `lx_backup` выше читаемого **пропускает** по маркеру (как чужой
  extension), без override-файлов.

## 7. Debug API

`GET /subs` (UserServer) и члены папки: поле `sections` (форма §2, как
хранится, с плейсхолдерами) — read-only на этой волне. `PATCH` секций нет:
запись — только через мастер и редактор узла.

## 8. Ядро и пин

Отдельный шаг (память: «при первом пересборе снять время и прирост AAR»):
в `sing-box-lx/cmd/internal/build_libbox/main.go` восстановить апстримный
`append(sharedTags, "with_tailscale", "ts_omit_logtail", …)` вместо блока
`// lx:begin no-tailscale`, выпустить `v1.14.0-lx.38`, замерить время сборки
(потолок F-Droid 3 ч; 2 ABI = 73 мин на lx.36) и размер AAR (116 МБ сейчас),
бампнуть `app/android/libbox.version` по процедуре `docs/KERNEL.md`
(javap-diff, эмулятор). До этого узел Tailscale на устройстве доезжает до
гейта §4.2.

## 9. UI (NODE_SECTIONS §7)

### 9.1 Routing

Строки `sections.rules[]` всех свободных узлов с секциями показываются **на
общей оси** вместе с корневыми правилами и якорями пресетов, с подписью «from
node <финальный тег>» и той же карточкой (`summary()`, outbound после
подстановки). Тумблер пишет `enabled` **в запись узла**; перетаскивание пишет
`num` в запись узла (ленивый сдвиг `moveRuleAfter` работает над объединённым
списком; сдвинутые соседи персистятся каждый в своего владельца: корневые —
`SettingsStorage.setCustomRules`, узловые — контейнер через
`SubscriptionController`). Редактирования и удаления у строки нет: меню
предлагает «Open node». После правки узла список перечитывается (экран
слушает `SubscriptionController`).

Реализация: узловые правила **не кладутся** в `_customRules` (буфер
персистится целиком в `custom_rules`, перечитывается при heal, экспортируется
и обходится SRS-кэшем); экран держит отдельный список `_nodeRules`
(владелец: индекс источника, индекс члена, индекс записи) и строит
объединённый порядок `_rows` по оси `num`. `placeRuleAfter` типизирован
`List<CustomRule>` и мутирует `orderNum` на месте — работает над временным
объединённым списком, после чего сдвинутые корневые уходят в `stageChanges`,
узловые — во владельца. Запись без `num` показывается на
`kNodeRuleDefaultNum = 945` (константа рядом с `kUserRuleNumStart`; в
`markRuleOrder` узловые не попадают — иначе получили бы 1000+). Экран
подписывается на `SubscriptionController` (сегодня не слушает): правка узла
при открытом Routing перечитывает `_nodeRules`. Пикер outbound у узловой
строки не показывается (цель — тег узла, а не Направление; пикер подставил бы
первую опцию): outbound после подстановки идёт текстом в подзаголовке.

Выключенный узел/список: его строки **показываются приглушёнными** с
подсказкой «node is disabled» и живым тумблером — как у лаунчера (ответ
14.09): пользователь видит, куда правило встанет, когда узел включат. В
конфиг такие строки не попадают (§4 п. 1).

### 9.2 DNS Settings

Серверы и правила узлов — read-only строки внизу соответствующих списков с
подписью после подстановки и пометкой «from node <тег>»; без тумблера, меню и
drag. Блокировки/lifecycle корневых серверов их не касаются. Реализация:
записи узлов **производные** (как preset-серверы в `DnsController.load`), в
`_servers`/`_rules` не кладутся — резолверы `resolveDnsServersList` /
`resolveDnsRulesList` отбрасывают чужой `kind` и персистят усечённый список
на каждый load. Узловые серверы не входят в опции членов групп и резолверов
(`dns.final`/`default_domain_resolver`) на этой волне.

### 9.3 Редактор узла (`NodeSettingsScreen`, член папки и одиночный)

Принимает: голое тело (`type` на верхнем уровне — секции не трогает),
документ с `sections`, sing-box-документ с `dns`/`route` (извлечение §3.2).
Оба вида — ошибка сохранения. Ниже тела — блок «Sections»: счётчик записей
(«2 rules · 1 DNS server · 1 DNS rule»), раскрывающийся JSON (форма §2, как
хранится), кнопка «Clear sections». Отброшенные записи и незнакомые ключи —
одной строкой предупреждения при сохранении.

### 9.4 Форма DNS-сервера

Тип `tailscale`: поля `tag`, `endpoint` (выбор из узлов `tailscale` — теги из
последней сборки; пусто → подсказка «No Tailscale nodes»), чекбокс
`accept_default_resolvers`. Сохраняется как обычный `DnsServerInline`; висячий
`endpoint` чинит санитайзер §4 п. 4.

### 9.5 Add Server Wizard → режим Tailscale

Поля: Tag (обязателен), Auth key (секрет, `obscureText`, обязателен), Control
URL, Hostname, Ephemeral, Accept routes, Exit node (тег выходного узла
tailnet). Подсказка под ключом обязательна: «A one-time key is consumed on
the first login; the device identity then lives in the state directory —
deleting the app data registers a new device». Результат — `UserServer` с
`rawBody` = JSON endpoint'а (`toUri()` `TailscaleSpec`) и `sections` с
канонической связкой из §2 (`@{self}-dns`, правило `.ts.net`, маршрут
`100.64.0.0/10` на 945 с именем `@{self} network`). Второй узел tailnet —
ещё один мастер с другим тегом; маршрут `100.64.0.0/10` у второго снимает
пользователь (Routing → тумблер строки узла).

### 9.6 Home и списки

Подпись протокола `tailscale` (`protoLabel`), «—» вместо задержки (проба не
делается), copy URI даёт JSON-текст. Узел без `exit_node` не появляется в пуле
Направлений (это делает сборка, UI ничего не фильтрует). Следствие для Home:
список Home — члены selector-группы ядра, поэтому такой узел на Home **не
виден** вовсе, как ⚙-detour без регистрации; он живёт на экране Servers, в
пикере detour и в позициях цепочек. Это ожидаемо: в интернет он не выпускает,
а связка (маршрут `100.64.0.0/10` → узел) работает без участия Направлений.

## 10. Тесты

- модель: `NodeSections` round-trip JSON (форма §2 байт-в-байт), пустое =
  отсутствие поля, отброс чужих `kind`, `substituteSelf` (обе формы,
  не-плейсхолдеры, ключи, глубина), `DnsRuleInline.enabled`;
- кодек: `ruleToRecord/ruleFromRecord` для inline/srs/preset (типы sing-box:
  `port` int[], `port_range` string[]; `action: reject`; `refs`; `dns`/`resolve`
  снаружи `body`; незнакомые ключи → `unknownKeys`), DNS-записи;
- парсер: `tailscale` из `outbounds[]` и `endpoints[]`, без адреса; целый
  конфиг с одним узлом → `importedSections` (серверы по `detour`/`endpoint`,
  правила по `server`, маршруты по `outbound`, переписывание ссылок);
  документ с `sections`; оба вида → warning; два узла → секций нет;
- сборка: инъекция на ось (945 перед `private-ips` 950), `enabled: false`,
  выключенный узел/член, узел без финального тега, DNS в конец,
  `endpoint`-санитайзер (висячий, дубль), `state_directory` (есть/нет корня,
  тег с `/`), гейт по версии (lx.36 → выброс с warning, lx.38 → эмиссия,
  пусто → эмиссия), `exit_node` и пул Направлений, инвариант байт-в-байт;
- контракт: `_endpointSchemes` + `tailscale`; корпус `tailscale_endpoint`,
  `whole_config_sections` (сверка `sections` — §13.1), `backup/node_sections`
  (§13.2);
- бэкап: `servers[].sections` в 0.12 → молча, без warning; экспорт узла с
  секциями → поля нет;
- UI: виджет-тесты строк Routing (пометка, тумблер пишет в узел, drag меняет
  `num` узла), DNS read-only, мастер Tailscale (обязательные поля, результат
  с канонической связкой), редактор узла (три вида входа, отказ на два вида).

## 11. Docs to update

| Файл | Что |
|---|---|
| `docs/STORAGE.md` | `sections` у `type: user` и у `members[]`; `dns_options.rules[].enabled`; формы записей §2 |
| `docs/PROTOCOLS.md` | Tailscale: приём из sing-box JSON, без URI, гейт ядра, состояние |
| `docs/KERNEL.md` | AAR build tags + `with_tailscale`/`ts_omit_*` (после пересборки), lx.38 в истории версий |
| `docs/api/debug-api-reference.md` | `sections` в `/subs` |
| `docs/ARCHITECTURE.md` | строка 435 в Feature Specs; поток «секции узла → инъекция» |
| `docs/spec/features/README.md` | строка 435 |
| `CHANGELOG.md` | Unreleased: Tailscale и секции узла |
| `assets/l10n/ru/ui.json` | переводы новых строк |

## 12. Сценарии для волны 5 (прогон UI)

1. Мастер Tailscale → узел на Home, «—» в задержке, строка «@{self} network»
   в Routing с подписью узла, DNS-сервер и правило на экране DNS read-only.
2. Выключить узел → строки исчезли из Routing/DNS; конфиг без следов.
3. Перетащить правило узла выше корневого → `num` в узле изменился, корневые
   номера не тронуты (ленивый сдвиг), конфиг отражает порядок.
4. Переименовать узел → подписи и конфиг следуют (плейсхолдеры в состоянии).
5. Папка с `tag_prefix` → финальный тег с префиксом в подписях и конфиге.
6. Вставить целый sing-box-конфиг с WireGuard-узлом и связкой → узел с
   секциями; вставить конфиг с двумя узлами → без секций.
7. Ядро без тега (пин lx.36): узел хранится, при сборке warning в снекбаре,
   остальные узлы работают; после бампа на lx.38 — узел в `endpoints[]` со
   `state_directory`.
8. Restore на телефоне файла десктопа 0.12 с узлом Tailscale и `sections` →
   узел приезжает, секций нет, предупреждений нет (до 1.0).
9. Узел подписки с приехавшими `sections` в теле подписки → секции не
   применяются.
10. Форма DNS-сервера `tailscale` с `endpoint` на удалённый узел → сервер
    выброшен санитайзером с warning, правило на него — тоже.

## 13. Вопросы лаунчеру и ответы (14.09.2026, singbox-launcher-ef)

1. **`whole_config_sections`**: `nodes[].sections` в форме §2 без `id` и
   без `num`; имя извлечённого правила — `body.name` провайдера, иначе
   `@{self} rule N` (N с 1 среди правил узла); `outbound: "@self"`
   дописывается, если нет ни `outbound`, ни `action`. Кейс приедет волной 3
   вместе с раннером конверта. **Принято.**
2. **`backup/node_sections`**: только 1.0 (`v10_node_sections`,
   `lx_backup: 2`); файл с версией выше читаемой раннер пропускает по
   маркеру. **Принято.**
3. **«Правила на него чинятся»**: у лаунчера так же — сервер с висячим
   `endpoint` вон целиком, DNS-правила на недоехавший `server` вон, правила
   только с `action` живут; `dns.final` на отсутствующий → первый доехавший,
   `domain_resolver` на отсутствующий снимается. **Совпадает.**
4. Реестр: пометки «LxBox не применяет» лаунчер снимет волной 3 вместе со
   схемой 1.0; LxBox присылает точные пути (`refs.dart`) после реализации.
5. `state_directory`: у лаунчера всё вне `[A-Za-z0-9._-]` → `_`, пусто →
   `tailscale`. **LxBox берёт тот же allowlist.**
6. Ядро: первый AAR с тегом — `v1.14.0-lx.38`; гейт по версии, неизвестная
   версия = поддержка есть (у лаунчера — проба тегов бинаря; эквивалентно).
7. Строки выключенного узла: у лаунчера показаны приглушёнными с подсказкой
   «node is disabled» и живым тумблером. **LxBox делает так же.**
8. Экспорт до 1.0: обе стороны дают `backup_local_only_dropped` с полем
   `sections`. **Совпадает.**
