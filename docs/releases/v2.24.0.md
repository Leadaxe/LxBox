# L×Box v2.24.0

**One storage and backup format with the desktop launcher 1.6.0.** The
desktop launcher [v1.6.0](https://github.com/Leadaxe/singbox-launcher/releases/tag/v1.6.0)
is out and writes only LX Backup 1.0 files, which 2.23.2 refused as newer than
supported. 2.24.0 imports them, and the phone now keeps subscriptions,
servers, folders, chains, rules and DNS in the same records as that file
(contract 1.0.2): export no longer loses fields, and the app's own settings
travel in the backup too. The switch runs once, on the first start, and the
built config does not change. Detours and chain positions point at a node
rather than at a tag string, so renaming or moving a node rewrites them. All
variables of template DNS servers and presets travel, the DNS address
included. **Rolling back to 2.23.2 is not supported:** 2.23.2 cannot read a
backup made on 2.24.0. The core is `v1.14.0-lx.39` (UDP through SOCKS5).

**Один формат хранения и бэкапа с десктопным лаунчером 1.6.0.** Десктопный
лаунчер [v1.6.0](https://github.com/Leadaxe/singbox-launcher/releases/tag/v1.6.0)
вышел и пишет только файлы LX Backup 1.0, а 2.23.2 отвергала их как «новее
поддерживаемого». 2.24.0 их импортирует, а телефон теперь хранит подписки,
серверы, папки, цепочки, правила и DNS теми же записями, что этот файл
(контракт 1.0.2): экспорт больше не теряет поля, и собственные настройки
приложения тоже едут в бэкапе. Переход выполняется один раз при первом
запуске, собранный конфиг не меняется. detour и позиции цепочек указывают на
узел, а не на строку тега, поэтому переименование и перенос узла их
переписывают. Переменные шаблонных DNS-серверов и пресетов едут все, включая
адрес DNS. **Откат на 2.23.2 не поддерживается:** бэкап, снятый на 2.24.0,
версия 2.23.2 не читает. Ядро — `v1.14.0-lx.39` (UDP через SOCKS5).

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 💾 Backup shared with the desktop launcher 1.6.0 ([docs/spec/tasks/438](docs/spec/tasks/438-lx-backup-1-0-read-write.md), [docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md), contract 1.0.2)

The desktop launcher [v1.6.0](https://github.com/Leadaxe/singbox-launcher/releases/tag/v1.6.0)
has been released and writes only LX Backup 1.0. Until the phone is updated to
2.24.0, a file from it is not imported: 2.23.2 refuses it as newer than
supported.

**Transfer to desktop** now writes the same LX Backup 1.0 file and reads both
1.0 and the older 0.12 files with one merge. The file record is the record
the phone stores, so export takes it as is and cuts only runtime data
(subscription status, node cache).

| Data | Before (0.12 file) | Now (1.0 file) |
|---|---|---|
| A 1.0 file from the desktop launcher 1.6.0 | Refused as newer than supported | Imported |
| Folder | Members as separate servers; folder settings and unreadable members lost | A folder record with its members; an unreadable member keeps its text |
| Autoselect node in a folder | Skipped with a warning when it came in a desktop 1.0 file | Carried both ways |
| Node sections, personal detour, shared detour of a subscription or folder | Not carried | Carried; references point at the node inside its container |
| JSON rule | Lost | The sing-box body as is; an array is split into `name`, `name #2`, … |
| Preset DNS server | Matched by tag | Matched by `<preset>:<tag>` |
| DNS `default_domain_resolver` | Not carried | Carried |
| App settings: import rules, detour policy, folder ping options and the like | Import rules, detour policy and folder ping options were lost, named on export | Carried |

The app's own settings that travel in the file: import rules and the update
action of a subscription, detour policy, the tag prefix of a standalone
server, folder ping options, chain names, the update interval of an srs rule,
the raw-JSON marker, DNS server description and variable values, rule-based
membership and badges of an autoselect node. The desktop launcher ignores
them. LxBox applies them on import, and a file without them, such as a
launcher export, leaves the phone's values as they are. Only srs DNS rules and
a JSON rule whose text does not parse are not carried; export names them. A
chain inside a folder is not stored on the phone and is named on import.
Variables of template DNS servers and presets are covered in their own
section below.

Import matches a folder by id first, then by name among folders that existed
before the import, so two folders with the same name are no longer merged and
importing your own export adds nothing. Identical DNS rules inside the file
are all imported. The tag prefix is translated between the sides: the
launcher keeps the separator inside the prefix. WG-INI configs with a comment
in the first line are no longer taken for the same server.

## 🗄 Storage migration on the first start ([docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md))

Until now the phone kept its settings in its own shape and translated them
into the LX Backup 1.0 format on export. From this release the settings file
holds the same records as the backup file and the desktop launcher 1.6.0
state, so there is no translator left to lose a field.

| Before | Now |
|---|---|
| Subscriptions, servers and folders in one list, chains in a separate list with a position number | One list of sources; chains at its end in their own order |
| Route rules with app-specific field names | Rules with the sing-box body as is |
| A JSON rule holding an array of rules | One rule per object: `name`, `name #2`, … with the same toggle and position |
| Folder autoselect node stored as an `autogroup://` text | A record with its members and strategy |
| — | A copy of the old file, `lxbox_settings.json.v0.bak`, made once before the switch |

What you notice: nothing. The switch runs by itself on the first start of
2.24.0 and also when you load a workspace saved on an older version or
restore an internal backup made on 2.23.2 or earlier. The config built from
the same settings is byte-for-byte the same as before (checked on a synthetic
state with every record kind, on a real test-bench snapshot and on the
emulator over 2.23.2). Anything that could not be read as is (a broken JSON
rule, a non-numeric port) is named in the app log; the original stays in the
`.v0.bak` copy.

One exception. A folder member's detour onto a neighbour typed by hand with
the folder prefix (`EU de-1`) was not recognized as a detour inside the folder
in 2.23.2, so the neighbour stayed in the Direction groups. It is now
recognized the same way as the bare tag `de-1` the app writes, and the
neighbour leaves the groups when the folder's detour flags say so.

### ⚠️ Rolling back to 2.23.2

| Situation | Result |
|---|---|
| 2.24.0 installed, you want 2.23.2 | Android does not install an older version over a newer one; uninstalling removes the settings |
| Clean 2.23.2 + internal backup made on 2.23.2 or earlier | Restores as before |
| Clean 2.23.2 + internal backup made on 2.24.0 | **Not read:** sources, chains, rules and DNS are dropped; Directions, variables, WARP accounts and modes survive |
| Clean 2.23.2 + LX Backup 1.0 file or a rules file exported on 2.24.0 | Refused as newer than supported |
| 2.24.0 + any backup made on 2.23.2, or a desktop launcher file older than 1.6.0 | Read |

If a device may need to go back to 2.23.2, make an internal backup on 2.23.2
before updating. For test benches with the Debug API on:
`GET /backup/export?include=storage&from=v0_bak` returns the `.v0.bak` copy
(the state at the switch) in the internal backup envelope, which 2.23.2
accepts through `POST /backup/import`. There is no button for it in the app.

## 🔗 Node links: detours and chain positions point at a node ([docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md), contract NODE_LINK)

A detour of a subscription, server or folder, a personal detour of a folder
member, chain positions and the members of an autoselect node are stored as
"container + raw node tag" rather than the final tag of the config. The final
tag is computed only when the config is built.

| Situation | Before | Now |
|---|---|---|
| Rename a node (edit its body), move it to another folder, take it out of a folder, change a standalone server's prefix | The reference kept the old tag: the detour was dropped at build, a chain with that position was dropped | References are rewritten at once |
| Change the tag prefix of a folder or subscription | Same breakage: references held the prefixed tag | References hold the raw tag; the prefix does not affect them |
| Delete a node, server, subscription or folder | Chain positions were removed with a counter; detours kept pointing at nothing | The detour is removed, the position leaves the chain, the member leaves its autoselect node, and one message names the affected sources, chains and groups |
| A detour whose target is not in the config | The detour was dropped and the node went direct | The node is left out of the config with a warning, and so are nodes that went through it; a detour ring drops all its members. One warning line per broken reference, naming up to five nodes |

An autoselect node inside a folder has no **Move out of folder** item: it has
no body of its own to become a server. Deleting a folder with **Keep servers**
deletes its autoselect nodes; the confirmation names them, and a folder that
holds only autoselect nodes does not offer **Keep servers**.

References saved by 2.23.2 are converted on the switch. An ambiguous one is
kept as it was and named in the log; a detour of a node onto itself and the
edge that closed a ring inside a folder are removed.

## 🧮 Variables of template DNS servers and presets ([docs/spec/tasks/441](docs/spec/tasks/441-template-preset-vars-in-record.md), [docs/spec/tasks/443](docs/spec/tasks/443-contract-1-0-2-spec129.md), contract 1.0.2)

This concerns the variables of DNS servers from the template (Google,
Cloudflare, AdGuard…) and of rule presets (RU direct, BitTorrent…).

| Situation | Before | Now |
|---|---|---|
| Transfer between LxBox and the desktop launcher | Of a DNS server's variables only the route target travelled, and LxBox dropped it; the DNS address (`dns_ip`), profile and resolver did not travel; variables from the file were not applied to a server that already existed | All variables travel inside the server record and are laid over the same server by name |
| A value equal to the template default | Stored as the user's choice: a new default in a later template never reached this user | Not stored, neither in the settings nor in the file; picking the default in the editor resets to the template. A user who never chose a value gets the new default when the template changes. A value equal to today's default cannot be pinned; on the first start such values are dropped from the settings |
| Importing a DNS server whose route target does not exist on the phone | Imported enabled | Imported **disabled** with a warning; the value is kept |
| The route target of a DNS server is missing at build (Direction deleted, value from a foreign file) | The build removed `detour`, and the server went direct, past the VPN | The server is left out of the config with a warning, and DNS rules pointing at it become `reject`. If it was `dns.final`, `final` is removed and an unconditional `reject` rule goes last, so queries do not fall through to the first server of the list (the system one). Resolvers that named it are replaced by the template default or the first usable server; a DNS group left empty drops the same way. The settings are not changed |
| Deleting or disabling a Direction that a DNS server points at (template `outbound`, user `detour`, also in node sections) or a preset target variable | Rules were switched to vpn-1, DNS servers and preset target variables kept the deleted tag | Switched to vpn-1 as well; the message adds "N DNS server(s) switched to vpn-1" |

The config built from the same settings does not change: a default written in
the record and a missing value are substituted the same way.

## ⏱ urltest: `interval` above `idle_timeout` no longer stops the core ([docs/spec/tasks/442](docs/spec/tasks/442-urltest-interval-idle-pair.md))

| Before | Now |
|---|---|
| A subscription with a rare node check (`interval: 3h` on an Xray balancer, `1d` on a sing-box group) or a Direction with an interval above its idle timeout gave a config the core refused at start with `interval must be less or equal than idle_timeout`; the VPN did not come up | The build raises `idle_timeout` to `interval` and writes a warning with both values. `interval` is not changed, so servers are not probed more often than the provider set |
| The Direction editor showed a red "Interval must be ≤ idle timeout" | The Direction editor and the autoselect node editor show a grey hint with the value idle timeout will be raised to |

## 📝 Rules file and JSON rule editor

| Before | Now |
|---|---|
| Routing → Export rules wrote the old storage shape | The file carries storage records (`format: 2`) with every app field: srs update interval, raw-JSON marker, DNS server description and variables. 2.23.2 refuses such a file; older files are read |
| The JSON rule editor saved an array of rules | One rule holds one JSON object; the editor asks to add each object of an array as a separate rule |

## 🪢 Tailscale: connection to tailnet peers ([docs/spec/tasks/437](docs/spec/tasks/437-tailscale-bundle-import.md))

A user report: tailnet devices were visible, but nothing connected to them.
Three gaps of v2.23.2 gave exactly that picture.

| Before | Now |
|---|---|
| A pasted sing-box config with a Tailscale endpoint **and** a proxy became a file subscription; subscription nodes carry no sections, so the endpoint joined the tailnet with no route to `100.64.0.0/10` and no MagicDNS server | Tailscale nodes of such a paste become separate servers with their records (the ones the config references, or the default bundle); the rest of the config is added as before, and the cached subscription text no longer contains them |
| A bare `{"type":"tailscale",…}` body got no records; only the wizard created them | A new Tailscale node without records gets the default bundle; **Clear sections** in the node editor removes it |
| The route rule matched `100.64.0.0/10` only; with FakeIP on, `*.ts.net` names got placeholder addresses and went to the default route | One rule matches `domain_suffix .ts.net` **or** the tailnet ranges, and a `resolve` through the node's DNS server runs before it — names reach the node with FakeIP on, UDP included |
| IPv6 tailnet addresses (`fd7a:115c:a1e0::/48`) were not routed | Both ranges are in the rule |
| The Exit node field had no hint | The hint explains the format — the Tailscale IP or machine name of a peer that advertises an exit node — and that internet goes through it only when the node is picked as the Direction on Home |

Nodes added in v2.23.2 keep their old bundle. To get the new one, add the node
again (Add server → Tailscale) and delete the old one. A Tailscale node inside
a URL subscription still gets no records — add it as a server.

## 🛰 Core `v1.14.0-lx.39`: UDP through SOCKS5 ([docs/KERNEL.md](docs/KERNEL.md))

The pin was `lx.38`. Some SOCKS5 proxies answer UDP ASSOCIATE with the relay
address `0.0.0.0` or `::`. The core dialed that address as is, which meant the
local system, so TCP worked and UDP silently did not. The relay address is now
replaced by the proxy server address, as Xray does. The Java API of the core
is unchanged.

## 🐛 Fixes

Bugs present in 2.23.2:

| Before | Now |
|---|---|
| REALITY nodes had `firefox` and other fingerprints replaced with `chrome` in the config, and connections to some servers did not come up | The node's fingerprint from the subscription goes into the config as is; the app does not rewrite the source's choice. The node warning suggests trying `chrome` ([docs/spec/tasks/444](docs/spec/tasks/444-reality-fingerprint-no-override.md)) |
| Importing a backup turned off rules whose target was `direct-out` | They arrive as they were |
| A user DNS rule written without the `enabled` key (backup import, Debug API) was skipped by the build | It is in the config |
| An srs DNS rule with its body in `body` never reached the config | It is in the config |
| Two identical DNS rules in a backup file were merged into one | Both are imported, in file order |

## 🧰 Debug API

For scripts working with the local Debug API:

| Endpoint | Before | Now |
|---|---|---|
| `GET /state/storage` | `server_lists`, `custom_rules`, `dns_options`, `chains` | `storage_version`, `sources`, `rules`, `dns`; the server body length is now hidden |
| `PUT /settings/dns_options/servers`, `/rules` | Old reference shapes and a JSON string | Only `dns` records; anything else is 400 with a sample record |
| `override_detour` in `/subs`, member `detour` in `/folders`, `hops` in `/chains` | Tag strings | `{folder_id?, tag}` in requests and responses; a string is read as `{tag}` |
| `GET /chains` | Included `order` | `tag`, `label`, `enabled` plus the chain canon; the list order is the place |
| `POST /folders/{id}/members/{idx}/ungroup` on an autoselect node | Made an empty standalone server | 409 |
| `POST`/`PATCH`/`DELETE /directions` | — | `healed.dns_servers` in the response |
| `GET /backup/export` | — | `from=v0_bak` returns the pre-switch copy, 404 without it |
| `POST /backup/import` | — | A `storage` block without `storage_version` is converted first; `applied.migrated` and a report in the response |

## 📜 Contract

The contract copy is synced with the desktop launcher, contract 1.0.2: wave 3
of contract 1.0 and the canonical Tailscale bundle, the node reference form
`{folder_id, tag}` with its rename and delete rules (autoselect groups
included), "one rule — one body", the app's settings declared in the backup
schema, rule numbers kept on import, variable values living in the record of
a template DNS server or preset. The template loader refuses a template DNS
server body that uses a variable the server does not declare.

## 🧪 Tests

Full suite: 4696 passed, 0 failed. All 31 backup corpus cases shared with the
desktop launcher pass. CI on `develop` is green: `flutter analyze`, the four
l10n checkers, the docs parity check. New: golden `config.json` and LX Backup
from two storage fixtures before and after the switch (a synthetic one with
every record kind and a sanitized test-bench snapshot), the migration itself
(idempotence, the `.v0.bak` copy, a crash between steps, a document with both
forms, a workspace slot of the old form), the record codec round-trip for
sources and chains, DNS records of every kind through both resolvers, the
backup slice table, node references on a real config build and in the
reference registry on rename, move and delete, the reference migration, the
autoselect node record and its folder menu; variable norms for both record
kinds, DNS variable import from a launcher file, the fail-closed DNS build on
both fixtures (the resulting config passes `sing-box check`), the template
loader check, the urltest interval and idle timeout pair with the editor
hints.

On the emulator, a pre-release build with the storage switch was installed
over 2.23.2 with a rich state: the switch and the `.v0.bak` copy, a config byte-for-byte equal to the
2.23.2 one before and after rebuild, a workspace slot of the old form, LX
Backup export and import without duplicates, rename and delete rewriting
references, the VPN start. The DNS variable and urltest changes were checked
by tests and `sing-box check`, not on the emulator.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 💾 Бэкап, общий с десктопным лаунчером 1.6.0 ([docs/spec/tasks/438](docs/spec/tasks/438-lx-backup-1-0-read-write.md), [docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md), контракт 1.0.2)

Десктопный лаунчер [v1.6.0](https://github.com/Leadaxe/singbox-launcher/releases/tag/v1.6.0)
выпущен и пишет только LX Backup 1.0. Пока телефон не обновлён до 2.24.0, файл
из него не импортируется: 2.23.2 отвергает его как «новее поддерживаемого».

**Перенос на десктоп** теперь пишет тот же файл LX Backup 1.0 и читает и 1.0,
и старые файлы 0.12 одним слиянием. Запись файла — та же запись, что хранит
телефон: экспорт берёт её как есть и срезает только рантайм (статусы
подписки, кэш узлов).

| Данные | Было (файл 0.12) | Стало (файл 1.0) |
|---|---|---|
| Файл 1.0 из десктопного лаунчера 1.6.0 | Отказ: «новее поддерживаемого» | Импортируется |
| Папка | Члены отдельными серверами, настройки папки и нечитаемые члены терялись | Запись папки со своим составом, нечитаемый член сохраняет текст |
| Узел автовыбора в папке | В файле 1.0 с десктопа пропускался с предупреждением | Едет в обе стороны |
| Секции узла, личный detour, общий detour подписки или папки | Не ехали | Едут; ссылки указывают на узел внутри контейнера |
| JSON-правило | Терялось | Тело sing-box как есть; массив делится на «имя», «имя #2»… |
| Preset-сервер DNS | По тегу | По `<preset>:<tag>` |
| DNS `default_domain_resolver` | Не ехал | Едет |
| Настройки приложения: import-rules, политика detour, ping-опции папки и другие | Import-rules, политика detour и ping-опции папки терялись, экспорт называл потерю | Едут |

Собственные настройки приложения, которые едут в файле: import-rules и
реакция на обновление подписки, политика detour, префикс тегов одиночного
сервера, ping-опции папки, имена цепочек, интервал обновления srs-правила,
маркер сырого JSON, описание и значения переменных DNS-сервера, членство узла
автовыбора правилом и его значки. Десктопный лаунчер их игнорирует. LxBox
применяет их при импорте, а файл без них, например экспорт лаунчера, значения
на телефоне не трогает. Не едут только srs-правила DNS и JSON-правило с
неразбираемым текстом, экспорт их называет. Цепочка внутри папки на телефоне
не хранится и называется при импорте. Переменным шаблонных DNS-серверов и
пресетов посвящён отдельный раздел ниже.

Папка из файла сопоставляется сперва по id, затем по имени среди папок,
существовавших до импорта: две папки с одним именем больше не сливаются, а
повторный импорт своего экспорта ничего не добавляет. Одинаковые DNS-правила
внутри файла ввозятся все. Префикс тегов переводится между сторонами: у
лаунчера разделитель входит в префикс. WG-INI-конфиги с комментарием в первой
строке больше не принимаются за один и тот же сервер.

## 🗄 Миграция хранения при первом запуске ([docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md))

До сих пор телефон держал настройки в своей форме и переводил их в формат
LX Backup 1.0 при экспорте. С этого релиза файл настроек хранит те же записи,
что файл бэкапа и состояние десктопного лаунчера 1.6.0: переводчика, в
котором могло потеряться поле, больше нет.

| Было | Стало |
|---|---|
| Подписки, серверы и папки одним списком, цепочки отдельным списком с номером места | Один список источников, цепочки в его конце в своём порядке |
| Правила маршрута с собственными именами полей | Правила с телом sing-box как есть |
| JSON-правило с массивом правил | Одно правило на объект: «имя», «имя #2»… с тем же тумблером и местом |
| Узел автовыбора в папке хранился текстом `autogroup://` | Запись со своим составом и стратегией |
| — | Копия старого файла `lxbox_settings.json.v0.bak`, снимается один раз перед переходом |

Что заметно пользователю: ничего. Переход выполняется сам при первом запуске
2.24.0, а также при загрузке workspace, сохранённого старой версией, и при
восстановлении внутреннего бэкапа 2.23.2 и раньше. Конфиг из тех же настроек
совпадает с прежним байт в байт (проверено на синтетическом состоянии со всеми
видами записей, на снимке настоящего стенда и на эмуляторе поверх 2.23.2). То,
что не прочиталось дословно (битое JSON-правило, нечисловой порт), названо в
журнале приложения; исходник остаётся в копии `.v0.bak`.

Одно исключение. detour члена папки на соседа, набранный вручную тегом с
префиксом папки (`EU de-1`), 2.23.2 не распознавала как detour внутри папки, и
сосед оставался в группах Направлений. Теперь он распознаётся так же, как
голый тег `de-1`, который пишет приложение, и сосед уходит из групп, если так
велят флаги detour папки.

### ⚠️ Откат на 2.23.2

| Ситуация | Что будет |
|---|---|
| Стоит 2.24.0, нужна 2.23.2 | Android не ставит старую версию поверх новой; удаление стирает настройки |
| Чистая 2.23.2 + внутренний бэкап, снятый на 2.23.2 и раньше | Восстанавливается как раньше |
| Чистая 2.23.2 + внутренний бэкап, снятый на 2.24.0 | **Не читается:** источники, цепочки, правила и DNS отбрасываются; Направления, переменные, аккаунты WARP и режимы остаются |
| Чистая 2.23.2 + файл LX Backup 1.0 или файл правил, выгруженный на 2.24.0 | Отказ: «новее поддерживаемого» |
| 2.24.0 + любой бэкап 2.23.2 или файл десктопного лаунчера до 1.6.0 | Читается |

Если на устройстве может понадобиться откат, снимите внутренний бэкап на
2.23.2 до обновления. Для стендов с включённым Debug API:
`GET /backup/export?include=storage&from=v0_bak` отдаёт копию `.v0.bak`
(состояние на момент перехода) в конверте внутреннего бэкапа, который 2.23.2
принимает через `POST /backup/import`. Кнопки в приложении для этого нет.

## 🔗 Ссылки на узлы: detour и позиции цепочек указывают на узел ([docs/spec/features/439](docs/spec/features/439%20storage-contract-1-0/spec.md), контракт NODE_LINK)

detour подписки, сервера и папки, личный detour члена папки, позиции цепочек
и состав узла автовыбора хранятся как «контейнер + сырой тег узла», а не
финальный тег конфига. Финальный тег считается только при сборке.

| Ситуация | Было | Стало |
|---|---|---|
| Переименовать узел (правкой тела), перенести в другую папку, вынести из папки, сменить префикс одиночного сервера | Ссылка держала старый тег: detour снимался на сборке, цепочка с такой позицией выпадала | Ссылки переписываются сразу |
| Сменить префикс тегов папки или подписки | То же: ссылки держали тег с префиксом | Ссылка держит сырой тег, префикс на неё не влияет |
| Удалить узел, сервер, подписку или папку | Позиции цепочек снимались со счётчиком, detour продолжал указывать в пустоту | detour снимается, позиция уходит из цепочки, член — из узла автовыбора; одно сообщение называет задетые источники, цепочки и группы |
| detour на узел, которого нет в конфиге | detour снимался, узел шёл напрямую | Узел не попадает в конфиг, есть предупреждение; так же выпадают узлы, ходившие через него; кольцо detour выпадает целиком. Одна строка предупреждения на битую ссылку с именами до пяти узлов |

У узла автовыбора в папке нет пункта **Move out of folder**: у него нет
собственного тела, чтобы стать сервером. Удаление папки с **Keep servers**
удаляет её узлы автовыбора; подтверждение их называет, а папке из одних узлов
автовыбора **Keep servers** не предлагается.

Ссылки, сохранённые 2.23.2, переводятся при переходе. Неоднозначная остаётся
как была и называется в журнале; detour узла на самого себя и ребро,
замыкавшее кольцо в папке, снимаются.

## 🧮 Переменные шаблонных DNS-серверов и пресетов ([docs/spec/tasks/441](docs/spec/tasks/441-template-preset-vars-in-record.md), [docs/spec/tasks/443](docs/spec/tasks/443-contract-1-0-2-spec129.md), контракт 1.0.2)

Касается переменных DNS-серверов из шаблона (Google, Cloudflare, AdGuard…) и
пресетов правил (RU direct, BitTorrent…).

| Ситуация | Было | Стало |
|---|---|---|
| Перенос между LxBox и десктопным лаунчером | Из переменных DNS-сервера ехала только цель маршрута, и LxBox её отбрасывал; адрес DNS (`dns_ip`), профиль и резолвер не ехали; переменные из файла к уже заведённому серверу не применялись | Все переменные едут записью сервера и накладываются на тот же сервер по именам |
| Значение, равное умолчанию шаблона | Хранилось как выбор пользователя: новое умолчание в следующей версии шаблона до такого пользователя не доходило | Не хранится ни в настройках, ни в файле; выбор умолчания в редакторе — сброс к шаблону. Кто значение не выбирал, при смене шаблона получает новое умолчание. Закрепить нынешнее умолчание нельзя; при первом запуске такие значения снимаются из настроек |
| Импорт DNS-сервера, цели маршрута которого на телефоне нет | Ввозился включённым | Ввозится **выключенным** с предупреждением; значение сохраняется |
| Цели маршрута DNS-сервера нет на сборке (Направление удалено, значение из чужого файла) | Сборка снимала `detour`, и сервер ходил напрямую, мимо VPN | Сервер не попадает в конфиг, есть предупреждение; DNS-правила на него становятся `reject`. Если он был `dns.final`, `final` снимается, а последним встаёт правило `reject` без условий — запрос не уходит к первому серверу списка (системному). Резолверы, указывавшие на него, заменяются умолчанием шаблона или первым пригодным сервером; DNS-группа, опустевшая от этого, выпадает так же. Настройки не меняются |
| Удаление или выключение Направления, на которое указывает DNS-сервер (`outbound` шаблонного, `detour` пользовательского, и в секциях узла) или переменная-цель пресета | Правила переводились на vpn-1, а DNS-серверы и переменные-цели пресета оставались на удалённом теге | Переводятся на vpn-1 так же; сообщение добавляет «N DNS server(s) switched to vpn-1» |

Конфиг из тех же настроек не меняется: умолчание, записанное в запись, и
отсутствие значения подставляются одинаково.

## ⏱ urltest: `interval` больше `idle_timeout` больше не роняет ядро ([docs/spec/tasks/442](docs/spec/tasks/442-urltest-interval-idle-pair.md))

| Было | Стало |
|---|---|
| Подписка с редкой проверкой узлов (`interval: 3h` у Xray-балансера, `1d` у группы sing-box) или Направление с интервалом больше тайм-аута простоя давали конфиг, который ядро отвергало при старте: `interval must be less or equal than idle_timeout`; VPN не поднимался | Сборка поднимает `idle_timeout` до `interval` и пишет предупреждение с обоими значениями. `interval` не меняется, чтобы не проверять серверы чаще, чем задал провайдер |
| Редактор Направления показывал красное «Interval must be ≤ idle timeout» | Редакторы Направления и узла автовыбора показывают серую подсказку, до какого значения поднимется idle timeout |

## 📝 Файл правил и редактор JSON-правила

| Было | Стало |
|---|---|
| Routing → Export rules писал старую форму хранения | Файл несёт записи хранения (`format: 2`) со всеми полями приложения: интервал обновления srs, маркер сырого JSON, описание и переменные DNS-сервера. 2.23.2 такой файл отвергает; старые файлы читаются |
| Редактор JSON-правила сохранял массив правил | Одно правило — один JSON-объект; для массива редактор просит добавить объекты отдельными правилами |

## 🪢 Tailscale: связь с пирами tailnet ([docs/spec/tasks/437](docs/spec/tasks/437-tailscale-bundle-import.md))

Отчёт пользователя: устройства tailnet видны, но связи с ними нет. Ровно такую
картину давали три пробела v2.23.2.

| Было | Стало |
|---|---|
| Вставленный sing-box-конфиг с endpoint Tailscale **и** прокси становился файловой подпиской; у узлов подписки секций нет, поэтому endpoint входил в tailnet без маршрута на `100.64.0.0/10` и без DNS-сервера MagicDNS | Узлы Tailscale такой вставки становятся отдельными серверами со своими записями (теми, что ссылаются на них в конфиге, или связкой по умолчанию); остальной конфиг добавляется как раньше, а в кэше подписки их больше нет |
| Голое тело `{"type":"tailscale",…}` записей не получало, их создавал только мастер | Новый узел Tailscale без записей получает связку по умолчанию; **Clear sections** в редакторе узла её снимает |
| Правило маршрута матчило только `100.64.0.0/10`; с включённым FakeIP имена `*.ts.net` получали фиктивные адреса и уходили в маршрут по умолчанию | Одно правило матчит `domain_suffix .ts.net` **или** диапазоны tailnet, а перед ним выполняется `resolve` через DNS-сервер узла — имена доходят до узла и с FakeIP, UDP тоже |
| IPv6-адреса tailnet (`fd7a:115c:a1e0::/48`) не маршрутизировались | В правиле оба диапазона |
| У поля Exit node не было подсказки | Подсказка объясняет формат — IP Tailscale или имя машины-пира, которая анонсирует exit node, — и что интернет через него идёт, только когда узел выбран Направлением на Home |

Узлы, добавленные в v2.23.2, сохраняют старую связку. Чтобы получить новую,
добавьте узел заново (Add server → Tailscale) и удалите старый. Узел Tailscale
внутри URL-подписки записей по-прежнему не получает — добавьте его как сервер.

## 🛰 Ядро `v1.14.0-lx.39`: UDP через SOCKS5 ([docs/KERNEL.md](docs/KERNEL.md))

Пин был `lx.38`. Часть SOCKS5-прокси отвечает на UDP ASSOCIATE адресом релея
`0.0.0.0` или `::`. Ядро диалило этот адрес как есть, то есть локальную
систему, поэтому TCP работал, а UDP молча нет. Теперь адрес релея подменяется
адресом прокси-сервера, как делает Xray. Java-API ядра не изменился.

## 🐛 Исправления

Ошибки, которые были в 2.23.2:

| Было | Стало |
|---|---|
| У REALITY-узлов отпечаток `firefox` и другие подменялся в конфиге на `chrome` — соединение с частью серверов не устанавливалось | Отпечаток узла из подписки уходит в конфиг как есть: приложение не переписывает выбор источника. Предупреждение на узле советует попробовать `chrome` ([docs/spec/tasks/444](docs/spec/tasks/444-reality-fingerprint-no-override.md)) |
| Импорт бэкапа выключал правила с целью `direct-out` | Правила приезжают как были |
| Пользовательское DNS-правило без ключа `enabled` (импорт бэкапа, Debug API) сборка пропускала | Попадает в конфиг |
| srs-правило DNS с телом в `body` в конфиг не попадало никогда | Попадает в конфиг |
| Два одинаковых DNS-правила из файла бэкапа схлопывались в одно | Ввозятся оба, в порядке файла |

## 🧰 Debug API

Для скриптов, работающих с локальным Debug API:

| Эндпоинт | Было | Стало |
|---|---|---|
| `GET /state/storage` | `server_lists`, `custom_rules`, `dns_options`, `chains` | `storage_version`, `sources`, `rules`, `dns`; длина тела сервера теперь скрыта |
| `PUT /settings/dns_options/servers`, `/rules` | Старые формы ссылок и строка JSON | Только записи `dns`; прочее — 400 с образцом записи |
| `override_detour` в `/subs`, `detour` члена в `/folders`, `hops` в `/chains` | Строки-теги | `{folder_id?, tag}` в запросах и ответах; строка читается как `{tag}` |
| `GET /chains` | Было поле `order` | `tag`, `label`, `enabled` плюс канон цепочки; место — порядок в списке |
| `POST /folders/{id}/members/{idx}/ungroup` на узле автовыбора | Делал пустой одиночный сервер | 409 |
| `POST`/`PATCH`/`DELETE /directions` | — | `healed.dns_servers` в ответе |
| `GET /backup/export` | — | `from=v0_bak` отдаёт копию до перехода, без копии — 404 |
| `POST /backup/import` | — | Блок `storage` без `storage_version` сначала переводится; в ответе `applied.migrated` и отчёт |

## 📜 Контракт

Копия контракта синхронизирована с десктопным лаунчером, контракт 1.0.2:
волна 3 контракта 1.0 и каноническая связка Tailscale, форма ссылки на узел
`{folder_id, tag}` с правилами переименования и удаления (и для групп
автовыбора), норма «одно правило — одно тело», настройки приложения,
объявленные в схеме бэкапа, номера правил, сохраняемые при импорте, значения
переменных в записи шаблонного DNS-сервера и пресета. Загрузчик шаблона
отвергает тело шаблонного DNS-сервера с переменной, которую сервер не
объявил.

## 🧪 Тесты

Полный набор: 4696 прошли, 0 упали. Все 31 кейс корпуса бэкапа, общего с
десктопным лаунчером, проходят. CI на `develop` зелёный: `flutter analyze`,
четыре l10n-чекера, проверка паритета документации. Новое: golden
`config.json` и LX Backup из двух фикстур хранения до и после перехода
(синтетика со всеми видами записей и очищенный снимок стенда), сама миграция
(идемпотентность, копия `.v0.bak`, сбой между шагами, документ с обеими
формами, слот workspace старой формы), круг кодека записей источников и
цепочек, DNS-записи всех видов через оба резолвера, таблица среза бэкапа,
ссылки на узлы на настоящей сборке конфига и в реестре ссылок при
переименовании, переносе и удалении, миграция ссылок, запись узла автовыбора
и его меню в папке; нормы переменных для обоих видов записей, импорт
переменных DNS из файла лаунчера, fail-closed сборка DNS на обеих фикстурах
(получившийся конфиг проходит `sing-box check`), проверка загрузчика шаблона,
пара interval и idle timeout у urltest с подсказками редакторов.

На эмуляторе предрелизная сборка с переходом хранения поставлена поверх
2.23.2 с богатым состоянием: переход и копия `.v0.bak`, конфиг байт в байт равен конфигу 2.23.2
до и после пересборки, слот workspace старой формы, экспорт и импорт LX Backup
без дублей, переписывание ссылок при переименовании и удалении, старт VPN.
Изменения переменных DNS и urltest проверены тестами и `sing-box check`, не на
эмуляторе.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.24.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся и
будут переведены в новый формат при первом запуске. Откат на 2.23.2 не
поддерживается.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved and converted to the new format on the first
start. Rolling back to 2.23.2 is not supported.

---

Previous release / Предыдущий релиз: [v2.23.2](docs/releases/v2.23.2.md).
