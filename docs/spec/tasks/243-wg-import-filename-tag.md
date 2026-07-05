# §243 — Имя файла становится tag при импорте WireGuard/AWG `.conf`

> СТАТУС: реализовано (05.07.2026). Фиксы багов с 4PDA: B1 (регрессия
> v2.11.0 — правка tag не отражается в списке Servers) + B5 (все члены
> папки из `.conf`-файлов называются «WireGuard»).

## Симптомы (4PDA)

- **B1** (регрессия, введена 9fab6be / §234 / v2.11.0): после импорта
  одиночного `.conf` правка Tag в Node Settings не меняет имя записи в
  списке Servers. Обходной путь юзеров — «вставить JSON как новый сервер».
- **B5**: импорт нескольких `.conf` в папку — все члены называются
  «WireGuard», имена файлов игнорируются.

## Root cause (два независимых слоя)

1. **Синтетический URI с захардкоженным фрагментом.** Все WG/AWG `.conf`
   при парсинге конвертируются во внутренний URI
   (`ini_parser.dart` / `_iniToUri`):
   `wireguard://host:port?…#WireGuard` — фрагмент `#WireGuard` одинаков
   для всех файлов ⇒ tag любой INI-ноды = `WireGuard`.
2. **B1**: §234-обвязка в `subscriptions_screen.dart` (`_importFromFile`)
   после `addFromInput` делала `renameAt(…, fileBaseName(file.name))` —
   писала имя файла в `entry.name`. `SubscriptionEntry.displayName`
   возвращает `name` первым ⇒ правка tag узла (`updateConnectionAt`, name
   не трогает) в списке больше не видна.
3. **B5**: `addMembersToFolder` применяет `nameFallback` (имя файла)
   только при `!_rawHasOwnName(raw)`, а `memberRawFor` для INI-ноды
   возвращает `rawUri` = синтетический URI с `#WireGuard` ⇒ raw «имеет
   имя», фолбэк никогда не срабатывает.

## Решение (согласовано с владельцем)

**Пробросить имя файла до конвертации INI→URI** — фрагмент синтетического
URI = имя файла (без расширения). Тогда tag узла = имя файла, и оба пути
(одиночный и папочный) чинятся в одной точке. Фолбэк при отсутствии имени
(вставка INI-текста из буфера) — прежний `#WireGuard`.

### 1. Проброс `nameHint` по цепочке (опциональный именованный параметр)

| Слой | Сигнатура | Поведение |
|---|---|---|
| `ini_parser.dart` | `parseWireguardIni(String config, {String? nameHint})` | `_iniToUri` кладёт `#${Uri.encodeComponent(hint)}`; пустой/`null` hint → `#WireGuard` (как раньше). Кодирование симметрично разбору: `parseWireguardUri` → `decodeFragment` → `Uri.decodeComponent` ⇒ пробелы/скобки/кириллица переживают round-trip без %-каши. |
| `parse_all.dart` | `parseAll(DecodedBody decoded, {String? nameHint})` | `IniConfig` → `parseWireguardIni(t, nameHint:)`. `AmneziaConfig` (несколько INI-контейнеров из одного `vpn://`) → индексный суффикс: первый контейнер = `hint`, дальше `hint 2`, `hint 3`… (иначе все члены получили бы одинаковый tag, минуя суффикс-логику `addMembersToFolder` — raw теперь «имеет имя»). `UriLines`/`JsonConfig` hint игнорируют. |
| `subscription_controller.dart` | `addFromInput(String input, {String? nameHint})` | Используется ТОЛЬКО в ветке `isWireGuardConfig` → `parseWireguardIni(trimmed, nameHint:)`. `rawBody` одиночного WG-сервера = `spec.rawUri` (синтетический URI с фрагментом) ⇒ имя переживает рестарт (`UserServer.fromJson` ре-парсит rawBody). Ветка `vpn://` hint НЕ получает: там `rawBody` = оригинальная ссылка, имя потерялось бы при рестарте — не создаём иллюзию. |
| `addMembersToFolder` | без изменения сигнатуры | `parseAll(decode(input), nameHint: nameFallback)` — INI-ноды получают имя прямо во фрагменте; прежний фолбэк-цикл (`_rawHasOwnName`/`_rawWithName`) остаётся для безымянных URI-строк. |
| `subscriptions_screen.dart` | `_importFromFile` | Одиночный файл: `addFromInput(text, nameHint: fileBaseName(file.name))`; **блок `renameAt` по имени файла удалён** — `entry.name` одиночного сервера больше никем не заполняется. |
| `folder_detail_screen.dart` | без изменений | «Import from files…» уже передаёт `nameFallback` — работает через `addMembersToFolder`. |

Взаимодействие с `_autoEmoji`/`withDefaultEmoji` не меняется: tag из
файла без эмодзи получает дефолтный префикс (для WG — `🏠 `), итог
`🏠 <имя файла>` — консистентно с прежним `🏠 WireGuard`.

`addFileSubscription` (§129) не трогаем: INI всегда даёт ≤1 ноды ⇒ в
файловую подписку не попадает; `profileTitle`/`_stripExt` для
многонодных файлов работают как раньше. WARP-пути (`_addWarpObfuscated`)
ставят tag принудительно поверх — hint им не нужен.

### 2. `UserServer.name` больше не показывается

`SubscriptionEntry.displayName`: для `UserServer` поле `name`
**игнорируется** (показывается tag/label первой ноды, как до §234);
для подписок (URL/файловых) и папок `name` работает как раньше.

- **Миграции хранилища НЕТ** (решение владельца): залежавшийся `name` у
  старых записей v2.11.0 просто игнорируется при отображении.
- `updateConnectionAt` (пересохранение сервера из Node Settings)
  дополнительно затирает `name` в `''` — запись самоочищается при первой
  правке.

### 3. Визард §074/§222 больше не пишет `UserServer.name`

До §243 у SOCKS5/HTTP-форм визарда (`add_server_wizard_screen.dart`) было
отдельное поле «Display name (optional)» → `UserServer.name` (заголовок
записи). С `displayName`, игнорирующим `name`, поле стало враньём —
**решение владельца: довести «name = tag» до конца**:

- Поле «Display name» **удалено** из обеих форм; единственный источник
  заголовка — поле **Tag** (терминология как в Node Settings).
- Поле Tag теперь **опционально** (раньше required + prefill): пусто →
  прежний дефолтный tag (`local-socks5-out` / `local-http-out`), дефолт
  показан hint'ом и назван в helper-тексте. Helper честный: «Shown as the
  server title in the Servers list. If empty, "<default>" is used.»
- Введённый tag живёт в `rawBody` (JSON outbound, поле `tag`) ⇒ переживает
  рестарт через re-parse (`parseSingboxEntry`), как и раньше.
- `UserServer.name` визард всегда пишет `''`.
- Авто-эмодзи (§090 G2b) без изменений: tag без эмодзи получает дефолтный
  префикс при `addUserServer` (для localhost — `🔁 `); ручной пикер в поле
  Tag остаётся.

**Принятые последствия** (осознанно, без смягчения): у существующих
визардных записей v2.11.0 и старше заголовок в списке молча меняется с
введённого «Display name» на tag узла; залежавшийся `name` затирается при
первом пересохранении из Node Settings (`updateConnectionAt`) — это ОК,
безусловное затирание безопасно по построению (name больше никто не пишет).

## Файлы

- `app/lib/services/parser/ini_parser.dart` — `nameHint` → фрагмент.
- `app/lib/services/parser/parse_all.dart` — проброс в INI/Amnezia ветки.
- `app/lib/controllers/subscription_controller.dart` — `addFromInput`
  (`nameHint`), `addMembersToFolder` (hint в `parseAll`),
  `updateConnectionAt` (затирание `name`).
- `app/lib/controllers/subscription_controller/subscription_entry.dart` —
  `displayName` игнорирует `name` для `UserServer`.
- `app/lib/screens/subscriptions_screen.dart` — `nameHint` вместо
  `renameAt`-блока.
- `app/lib/screens/add_server_wizard_screen.dart` — поле «Display name»
  удалено, Tag опционален (пусто → дефолт), `name` всегда `''`.

## Тесты

- `test/parser/ini_parser_test.dart` — nameHint → tag/label = имя файла
  (включая пробел + кириллицу + скобки, round-trip через `rawUri`);
  без hint → `WireGuard`; `parseAll` IniConfig/UriLines-гейтинг.
- `test/parser/awg_test.dart` — awg2-экспорт INI с nameHint: tag = имя
  файла, AWG-поля не теряются.
- `test/subscription/wg_import_filename_test.dart` (новый) —
  контроллерные сценарии: одиночный импорт (`name` пуст, displayName =
  `🏠 <файл>`); правка tag через `updateConnectionAt` отражается в
  displayName + `name` затирается; legacy-запись v2.11.0 с непустым
  `name` игнорируется; папочный путь (proton-INI и awg2-INI) → member
  tag = имя файла; суффиксы Amnezia-контейнеров; JSON-вставка
  (label=tag) не сломана.
- `test/screens/add_server_wizard_test.dart` (новый) — визардный путь:
  заполненный Tag → tag узла = введённое, `name == ''`; пустое поле →
  дефолтный tag; tag переживает persist round-trip (re-parse `rawBody`
  через `UserServer.fromJson`); helper/лейблы без «Display name».

## Docs to update

- `CHANGELOG.md` → Unreleased: фикс «имя файла становится именем сервера
  при импорте .conf; правка Tag снова отражается в списке» —
  **[deferred: вне зоны этой сессии, добавить при релизном проходе]**.

## Связанные

§234 (импорт файлов/папки, источник регрессии B1), §129 (файловые
подписки — не затронуты), §110 (Amnezia `vpn://`), §097 (AWG INI),
§090 G2b (авто-эмодзи), §237 (member Node Settings).
