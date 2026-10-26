# 686 — Карточка узла: auto-узел, вкладка INI, несколько [Peer], `#`-комментарии; правка по долгому тапу снята

| Поле | Значение |
|------|----------|
| Статус | Draft (решения владельца внесены, к реализации) |
| Дата начала | 2026-10-26 |
| Связанные спеки | [675](675-folder-auto-node-silent-drop-and-pool-gates.md) — предупреждения и гейты пула auto-узла; [237] — тап по члену папки открывает Node Settings; issue #171 п.9 |

## Проблема

Пользователь создаёт в папке auto-узел (⋮ → Add auto node…, режим пула All)
и обычным тапом открывает его. Открывается общий экран Node Settings:

1. вкладка Source пустая;
2. переименование не сохраняется: Tag меняется, Save отвечает «Source is
   empty», запись не меняется;
3. вкладка JSON показывает `"outbounds": []`.

Сборка конфига при этом верна: группа уходит в конфиг со всеми членами папки
(`test/builder/auto_group_folder_test.dart`). Пользователь видит пустую группу
и не может её отредактировать, хотя она работает.

Рядом — меню долгого тапа, которое дублирует карточку или вовсе не подходит
записи:

4. у одиночного сервера (в т.ч. OpenConnect / Fortinet) есть «Edit source…» —
   диалог смены источника ПОДПИСКИ (Online URL / Local file) с пустым полем
   URL; Save ответил бы «not a subscription» (`updateSourceAt` принимает
   только `SubscriptionServers`); там же «Update», которому у сервера нечего
   обновлять с сети;
5. у члена папки «Edit…» открывает диалог сырого текста — тот же текст, что
   вкладка Source карточки; у auto-узла — отдельный редактор группы, второе
   место правки.

## Диагностика

- Тап по члену папки с узлом всегда открывает `NodeSettingsScreen`, отдельной
  ветки для группы нет (`folder_detail_screen.dart:1350-1368`). Редактор группы
  открывается только долгим тапом → Edit… (`_editAutoNode`).
- Source берёт текст из `member.raw` (`node_settings_screen.dart:165`). У
  члена `kind: auto` `raw` пустой (`FolderMember.auto`, `server_list.dart`):
  группа хранится записью без текста узла.
- Save на этом экране только `_saveSource()`; на пустом тексте — «Source is
  empty» и выход (`node_settings_screen.dart:379-383`).
- Хранимая форма у группы есть: запись `kind: auto` контракта 1.0
  (`autoGroupMemberToRecord` / `autoGroupMemberFromRecord`,
  `models/codec/auto_group_record.dart`). Её пишут хранилище и LX Backup.
- JSON показывает `node.emit(TemplateVars.empty)`; у группы-правила
  `outbounds` там пустой, состав считает только сборка (`node_spec.dart`).
- Меню одиночного сервера и подписки — одно (`showEntryContextMenu`,
  `subscriptions_screen/entry_context_menu.dart`): «Update» и «Edit source…»
  показываются всем записям, кроме папок, без проверки на тип.
- Меню члена папки — `_showMemberMenu` (`folder_detail_screen.dart`): Edit…,
  Move to folder…, Move out of folder, Delete. У битого члена (узла нет) тап
  открывает это же меню, и «Edit…» — единственный способ поправить его текст.

## Решение (слово владельца 26.10.2026)

Вкладку Source у auto-узла чинить, а не уводить тап в другой экран.

1. **Source показывает запись, как она хранится:** результат
   `autoGroupMemberToRecord(member, spec, folderId)`, отформатированный JSON.
   Пример для режима All:
   ```json
   {
     "kind": "auto",
     "tag": "Auto",
     "enabled": true,
     "group": {
       "group_type": "urltest",
       "strategy": { "mode": "least_test", "url": "…", "interval": "15m", … },
       "members_rule": { "include": "", "exclude": "" }
     }
   }
   ```
2. **Source редактируется, Save записывает:** текст разбирается
   `autoGroupMemberFromRecord` и пишется тем же путём, что Save редактора
   группы (`SubscriptionController.updateAutoMemberAt`). Так один раз
   проверяются тег, состав и гейты, без второго пути записи.
3. **Отказ — без записи:** не JSON, не объект, `kind` не `auto` или незнакомые
   ключи (`unknown` читателя) → ошибка с путём ключа, запись не меняется,
   текст в редакторе остаётся.
4. **Поля группы — на первой вкладке, как у остальных типов.** У обычного
   узла на Settings лежат редактируемые поля (Tag, Masquerade, Detour, TLS);
   у OpenConnect — целая форма поверх текста Source (`OpenConnectForm`: правка
   формы переписывает Source через `sourceWithFormBody`, Save пишет Source;
   битый Source гасит форму подписью «The form is off: Source is not a valid
   JSON object.»). У auto-узла Settings — форма редактора группы: Name (Tag),
   Servers in the pool (All / Rule / Pick) с превью состава, Mode, Advanced,
   Selected server, Sticky session, Interrupt connections. Правило то же:
   форма правит текст Source, Save один — по Source. Секции Info (Protocol,
   Server), Masquerade, Detour, TLS у группы не показываются.
5. **Форма одна на два экрана.** Тело формы выносится из
   `AutoGroupEditScreen` в общий виджет; экран создания (⋮ → Add auto node…)
   остаётся и использует тот же виджет. Место правки существующего узла
   одно — карточка (п. 8).
6. **Вкладка JSON** у группы-правила вместо `"outbounds": []` показывает строку
   «состав считает сборка» (EN в UI: «Members are resolved at build time»); у
   группы с явным составом (Pick) — сырые теги выбранных членов, как сейчас
   (`AutoSelectSpec.emitRaw`). Кнопки «Edit JSON» у группы нет: у неё нет тела
   узла, которое можно отдать ядру дословно; правят форму или Source.
7. **Выключенные члены в превью — отдельно, с иконкой ⏻** (слово
   владельца 26.10.2026). Сейчас кандидаты пула (`_poolCandidates`,
   `folder_detail_screen.dart:873`) не смотрят `m.enabled`: сервер, выключенный
   переключателем в списке папки, превью считает членом группы, а сборка его
   отбрасывает («7 of 7», в конфиге 6). Станет:
   - выключенный член остаётся в списке превью со своей иконкой выключения
     (⏻, `Icons.power_settings_new`), без текстовой подписи: в All и Rule она
     стоит на месте ✓/⊖, в Pick — справа от имени (слева чекбокс); строка
     приглушена, как у ⊖; не путается с исключённым правилом (⊖) и с
     неотмеченным в Pick (пустой чекбокс);
   - в счёт «N of M servers» не входит ни в N, ни в M; если выключенные есть,
     к счёту добавляется «· K off»;
   - в Pick выключенного можно отметить: выбор хранится и начинает работать,
     когда сервер включат; иконка ⏻ остаётся.

   Макет (выключен `P: Plain WG`):
   ```
   ── Rule (Exclude: Xcu) ──────────────────
    5 of 6 servers · 1 off
    ⏻  P: Plain WG                           ← выключен в папке
    ✓  Xc: Chrome
    ⊖  Xcu: Curl                             ← исключён правилом (серый)
    ✓  Xd: DNS
   ── Pick ─────────────────────────────────
    5 of 6 servers · 1 off
    [x] P: Plain WG                    ⏻     ← войдёт, когда включат
    [x] Xc: Chrome
    [ ] Xcu: Curl                            ← не выбран
    [x] Xd: DNS
   ```

8. **Правка по долгому тапу снята — правят в карточке (тап).**
   - Член папки с узлом (обычный и auto): пункта «Edit…» в меню нет; тап
     открывает Node Settings. Битый член (узла нет): «Edit…» остаётся —
     иначе его текст не поправить.
   - Одиночный сервер в списке Servers: «Edit source…» и «Update» в меню нет.
   - Подписка: «Edit source…» (URL ↔ файл) и «Update» остаются — это действия
     над источником, не форма; та же кнопка есть в карточке подписки.
   - Папка: меню не меняется.
9. **Вкладка INI у WireGuard / AmneziaWG** — узел в виде `.conf` при любом
   источнике (ссылка, тело JSON, подписка, сам INI). Порядок вкладок:
   Settings │ Source │ JSON │ INI │ Diagnostics; показывается только у
   WG/AWG, как Network у Tailscale.
   - Только для просмотра, как JSON: кнопки Copy, Share `.conf` и **Edit INI**.
   - Edit INI: источник уже INI → переход на Source; иначе предупреждение
     (по образцу «Edit JSON?»), источник заменяется этим INI, переход на
     Source.
   - Тег, Detour, TLS хранятся полями записи рядом с `origin`, не в нём: замена
     источника их не трогает. Masquerade живёт В источнике (ключи `ip`/`id`/`ib`,
     `masquerade_source.dart`; у ссылки и INI одни имена) — генератор INI
     обязан их переносить.
   - Ссылка и INI идут одним конвейером с одной таблицей переноса параметров
     (`ini_parser.dart`, секция `conf` реестра): из ссылки в INI ничего не
     теряется. Генератор INI строится обратным ходом по той же таблице, не
     руками (частный генератор WARP в `warp_account.dart` — не основа).
   - Теряться может только то, что есть в теле JSON и чего нет в таблице
     переноса; такие ключи перечисляются в предупреждении Edit INI и строкой
     «Not in INI: …» под текстом вкладки. Нечего терять — строки нет.

   Макет:
   ```
    Settings │ Source │ JSON │ INI │ Diagnostics
   ┌──────────────────────────────────────┐
   │ [Interface]                          │
   │ PrivateKey = …                       │
   │ Address = 172.16.0.2/32, …           │
   │ Jc = 4 …                             │
   │ [Peer]                               │
   │ PublicKey = … · Endpoint = …         │
   └──────────────────────────────────────┘
    [Copy] [Share .conf]   ✎ Edit INI
   ```

10. **Несколько `[Peer]` в INI — допустимы** (слово владельца 26.10.2026).
    Сейчас реестр (`wireguard.json`, `mappers.conf.ini_dialect.sections.Peer`:
    `repeat: first_only`) берёт первую секцию, остальные снимает с кодом
    `wgconf_extra_peer_dropped`. Ядро это не требует: у endpoint `wireguard`
    `peers` — массив, трафик разводится по `allowed_ips`; модель LxBox тоже
    несёт список (`WireguardSpec.peers`). Станет:
    - каждая секция `[Peer]` → свой элемент `peers[]` с теми же параметрами
      таблицы `conf` (PublicKey, PresharedKey, Endpoint, AllowedIPs,
      PersistentKeepalive, Reserved …); `[Interface]` — один, как сейчас;
    - код `wgconf_extra_peer_dropped` больше не выдаётся для INI;
    - ссылка (`wireguard://`, `awg://`) остаётся с одним пиром — у формата
      ссылки второго места нет;
    - вкладка INI (п. 9) выводит все пиры тела; у тела с N пирами Edit INI
      ничего не теряет.
    - **Норма 1.1.140 (лаунчер, e1cefc3c, `TASKS_LXBOX.md` §136 «Ответ
      лаунчера»), что делает наша сторона после синка
      (`sync_contract.sh --to 6a613701` — поправка лаунчера: ожидания корпуса тел несут только code и path, без params):**
      - движок INI (`engine/ini_space.dart`): повторяемая секция `[Peer]` —
        список экземпляров, каждый → свой `peers[]` в порядке файла;
      - секция без обязательного ключа снимается одна кодом
        `wgconf_peer_dropped` {index, missing}, путь `peer.<index>` (дедуп по
        паре код+путь); экземпляр, отказавший не по `required`, — кодом самого
        отказа + index;
      - новый атрибут тела `peers.on_item_failure: {action: drop_item, code:
        wg_peer_dropped, core_rejects: true}` (`schema/registry_body.schema.json`):
        отказ внутри элемента (drop_node или required) снимает элемент, его коды
        заменяются одним `wg_peer_dropped` {index, reason}, путь `peers[<i>]`
        (индекс входа); не уцелел ни один — прежний отказ узла; единственный
        элемент не изолируется. Действует на всех входах, включая тело sing-box
        JSON;
      - секция с ini-формой без своего `ini_dialect` берёт диалект соседней
        секции протокола — у нас это уже так (`_withIniDialect`), теперь норма
        схемы;
      - корпус: `body/wgconf/ini_multi_peer` (бывший `ini_extra_peer`),
        `ini_multi_peer_awg`, `ini_multi_peer_missing_key`,
        `ini_multi_peer_bad_key`, `uri/wireguard/awg_conf_base64_multi_peer`;
      - `wgconf_extra_peer_dropped` снят; старые записи с ним читаются молча.
    - До синка контракта вкладка INI уже выводит все пиры, а Edit INI у тела с
      N > 1 пирами предупреждает, что при разборе останется первый (имена
      отброшенных — по `Endpoint`). После синка это предупреждение снимается.
    - Норма меняется в контракте (реестр + движок разбора обеих сторон + кейс
      корпуса `conf/wireguard/multi_peer`): ведёт лаунчер (запрос — `contract/TASKS_LXBOX.md` §136 в репо лаунчера, e41d2f74; сделано в 1.1.140, синк на 6a613701); LxBox реализует свою сторону после синка контракта.

11. **Комментарии `#` в JSON** (issue #171 п.20; слово владельца 26.10.2026 —
    в эту же задачу). Ядро их принимает: разбор sing (`common/json/internal/
    contextjson`, «JSONC comments by default») читает `#` как строчный
    комментарий наравне с `//`. Наш разбор — нет, в двух механизмах:
    - `stripJsonComments` (`services/parser/json_comments.dart`) снимает только
      `//` и `/* */`. Им пользуются вставка в поле Servers
      (`clipboard_analysis.dart`), добавление своего сервера телом JSON
      (`subscription_controller.dart`, `addFromInput`) и Save вкладки Source
      (`node_document.dart`) — текст с `#` получает «не распознано» / «Invalid
      JSON»;
    - разбор JSON5 (`config/config_parse.dart`: Save и Format экрана Config,
      кнопки Format JSON-полей `lx_code_editor.dart`, `config_io.dart`,
      `route_config.dart`) — в JSON5 `#` нет.

    Станет: оба механизма снимают `#` до конца строки вне строковых литералов,
    как `//`; `#` внутри строки (`"#fragment"`, `"vless://…#Name"`) не
    трогается. Предупреждение «Comments will be removed» и отметка «comments
    removed» при вставке срабатывают и на `#`. Подсказка поля Config — «JSON or
    JSON5 (//, /* */ and # comments)». Ответ в issue по п.20 исправляется:
    прежний «rejected» был ошибкой.

## Точки входа

Экран узла открывается не только тапом в папке: из списка Servers
(`subscriptions_screen.dart`), переходом к владельцу узла
(`owner_navigation.dart`) и из баннера отказа ядра (`core_reject_ui.dart`).
Всё сказанное про auto-узел и вкладку INI действует при любом входе: решает
тип узла, а не экран, откуда пришли. Узлы подписок этот экран не открывают —
им ничего не меняется.

## Строки и документация

- Новые строки UI (английский, переводы — по `docs/l10n.md`): «Members are
  resolved at build time», «Not in INI: %s», «Edit INI», «Edit INI?» и текст
  предупреждения, «Share .conf», «INI copied», «· %s off».
- Обновить: `features/008-NODE_EDITOR` (`node-settings`, `source-editing`,
  `json-and-schema` — вкладки Settings/Source/JSON/INI у auto-узла и WG/AWG),
  `features/007-NODE_LIST` (`server-folders` — тап и меню члена папки,
  `node-row-badges-and-menu` — меню одиночного сервера), `features/006-DETOUR_AND_BALANCE`
  (превью состава auto-узла, ⏻), `docs/USER_GUIDE.md` / `USER_GUIDE.ru.md`
  (где править auto-узел; вкладка INI), `docs/STORAGE.md` не меняется (форма
  хранения прежняя). EN и RU-версии вместе.

## Вне задачи

- Auto-узлы, приехавшие из подписки (не члены папки): их экран и запись не
  меняются.
- Состав из последней сборки на вкладке JSON (решение владельца — строка).

## Открытые вопросы

Нет (ответы владельца 26.10.2026 внесены в «Решение»: Source = хранимая
запись; поля группы на первой вкладке, как у остальных типов; JSON — строка
вместо пустого массива; превью без выключенных членов с иконкой ⏻; правка по
долгому тапу снята, всё в одной задаче).

## Проверка

- Unit: `stripJsonComments` и разбор JSON5 снимают `#`-строку вне литерала,
  не трогают `#` в строке; сырой конфиг sing-box с `#` проходит Save экрана
  Config; узел JSON с `#` вставляется в Servers и сохраняется через Source.

- Unit: запись → текст Source → разбор → та же запись (All, Rule, Pick;
  `pool_badge`, `warnings`).
- Unit/widget: правка формы на Settings переписывает Source; правка Source
  меняет форму; битый Source гасит форму; битый JSON и незнакомый ключ ничего
  не пишут.
- Widget: выключенный член папки виден в превью с иконкой ⏻, не входит в
  «N of M», счёт показывает «· K off»; в Pick его можно отметить.
- Эмулятор: папка из 3 серверов, один выключен; создать auto-узел (All) →
  превью «2 of 2 servers · 1 off», выключенный с иконкой ⏻; тап → Settings с формой группы, Source не пустой,
  JSON со строкой вместо `[]`; переименовать полем Name, Save → новое имя в
  списке папки и в собранном конфиге.
- Эмулятор, меню долгого тапа: член папки (обычный и auto) — без «Edit…»;
  битый член — «Edit…» есть; одиночный сервер (OpenConnect) — без «Edit
  source…» и «Update»; подписка — оба пункта на месте.
- Unit: ссылка WG/AWG → INI вкладки → разбор INI → то же тело узла; тело JSON
  с ключом вне таблицы переноса → ключ в «Not in INI».
- Unit: INI с двумя `[Peer]` → `peers` из двух элементов, без
  `wgconf_extra_peer_dropped`; вкладка INI выводит оба (после синка контракта).
- Эмулятор: AWG-узел из ссылки → вкладка INI → Edit INI → предупреждение →
  Source с INI, Detour и Tag на Settings не изменились.
