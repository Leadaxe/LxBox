# 575 — Секции узлов упразднены

| Поле | Значение |
|------|----------|
| Статус | Spec. Реализация запущена |
| Дата старта | 2026-09-27 |
| Дата завершения | — |
| Коммиты | — |
| Контракт | Требует запроса в контракт: отмена нормы `NODE_SECTIONS.md` §1 (носители), §6 (связка Tailscale), E1 |
| Связанные spec'ы | [§578](578-tailscale-preset-template-for-each.md) (пресет Tailscale, выходит в одном релизе), [§576](576-node-source-is-bare-body.md), [features/435](../features/435%20node-sections-tailscale/spec.md) (отменяется в части секций), [§437](437-tailscale-bundle-import.md), [§438](438-lx-backup-1-0-read-write.md), [§445](445-tailscale-state-dir-lifecycle.md) (остаётся), [§449](449-tailscale-default-hostname.md) (остаётся) |

## Проблема

Узел описывает один сервер. Поле `sections` даёт ему власть над всем конфигом:

- правила секции вливаются в общий список маршрутов и сортируются по общей оси
  вместе с корневыми правилами и якорями пресетов;
- DNS-серверы и DNS-правила секции дописываются в общие списки;
- тело правила сырое, цель не обязана быть `@self`: допустимы `action` и любой
  чужой outbound.

Вставив чужой узел документом, пользователь получает изменённые маршруты и DNS
всего приложения. Полномочия уровня приложения выданы объекту уровня узла.

## Решение владельца (27.09.2026)

| Носитель | Секции |
|---|---|
| свой сервер, любой протокол, включая Tailscale | нет |
| член папки, любой протокол, включая Tailscale | нет |
| папка | нет |
| подписка | имя поля зарезервировано, не читается и не пишется |
| узел подписки, цепочка, группа, Направление | нет (как было) |

- Секции существующих узлов выбрасываются: не читаются, не сохраняются, в
  сборке не участвуют. Переноса в общие правила нет.
- Плейсхолдер `@self` / `@{self}` уходит из хранилища и из сборки вместе с
  секциями.
- Связку Tailscale (маршрут в tailnet, DNS-сервер, DNS-правило) даёт пресет
  шаблона, задача [§578](578-tailscale-preset-template-for-each.md).
- Кому нужны правила для сети за WireGuard/AWG — пишет их в общих правилах
  маршрутов и DNS с узлом как целью.

## Диагностика

Опись мест, где секции живут сейчас.

| Слой | Где |
|---|---|
| модель | `app/lib/models/node_sections.dart` (файл целиком); поле `sections`, `copyWith`/`clearSections`, `==`/`hashCode` у `UserServer` и `FolderMember`, `heal()` и `retargetSectionsDnsDetours` в `app/lib/models/server_list.dart`; `NodeSpec.importedSections` в `app/lib/models/node_spec.dart` |
| кодек хранения | `app/lib/models/codec/source_record.dart`: запись ключа `sections` у сервера и у члена, ключ в `_serverKeys` и `_memberKeys`, `_sectionsFromRecord` |
| миграция старого хранилища | `app/lib/services/storage_migration/legacy_form_v0.dart`: `NodeSections.fromJson(j['sections'])`, два места |
| разбор | `app/lib/services/parser/singbox_config.dart`: чтение явного `sections` документа, `extractNodeSections`, предупреждения `SectionsRecordDroppedWarning` и `SectionsConflictWarning` |
| подписка | `app/lib/services/subscription/sources.dart`: две строки журнала про секции узла подписки |
| сборка | `app/lib/services/builder/build_config.dart`: `_collectNodeSections`, `_NodeSectionsInjection`; параметры `nodeServers` и `nodeRules` в `post_steps/dns_servers.dart` и `post_steps/dns_rules.dart` |
| контроллер | `app/lib/controllers/subscription_controller.dart`: `setUserServerSections`, `setMemberSections`, `syncSectionsDnsDetourRefsHealed`, вызовы `sectionsForNewNode`, перенос `sections` при сборке и разборке папки, чтение `importedSections` в `updateConnectionAt` и `updateMemberAt` |
| экран узла | `app/lib/screens/node_settings_screen.dart`: блок Sections, диалог Clear sections, сводка |
| экран папки | `app/lib/screens/folder_detail_screen.dart`: отметка Has node sections |
| экран маршрутов | `app/lib/screens/routing_screen/node_rule_rows.dart` (файл целиком), вызовы в `routing_screen.dart` |
| экран DNS | `app/lib/screens/dns_settings_screen.dart`, `widgets/node_dns_tiles.dart`, `app/lib/services/dns/node_dns_records.dart` |
| редактор документа узла | `app/lib/screens/node_settings/node_document.dart`: проверка «и `sections`, и `dns`/`route`» |
| резервные копии | `app/lib/services/lx_backup.dart`, `app/lib/services/lx_backup_slice.dart` |
| Debug API | `app/lib/services/debug/serializers/subs.dart`: поле `sections` у сервера и у члена; текст в `handlers/help.dart` |
| связка Tailscale | `app/lib/models/tailscale_bundle.dart`: `canonicalTailscaleSectionsJson`, `canonicalTailscaleSections`, `sectionsForNewNode`, константы тега DNS-сервера и имени правила |

## Решение

### 1. Хранилище

Условия:

1. запись своего сервера или члена папки прочитана из хранилища;
2. в записи есть ключ `sections`.

Поведение: ключ не читается. Запись пишется без него при первом же сохранении
состояния. Миграции нет, версия формы хранения не меняется.

Один раз на запуск, если хотя бы у одной записи найден ключ `sections` с
записями: строка в журнале приложения уровня info с числом таких узлов. Текста
в интерфейсе нет.

Чтение старой формы (`legacy_form_v0.dart`) секции тоже не поднимает.

### 2. Разбор

Парсер из документа берёт только узел.

| Вход | Узел | `dns`, `route`, `sections` документа |
|---|---|---|
| голое тело | да | нет |
| документ `{outbounds или endpoints: [узел], sections}` | да | отбрасываются |
| документ `{outbounds или endpoints: [один узел], dns, route}` | да | отбрасываются |
| целый конфиг с несколькими узлами | да, все | отбрасываются |

`importedSections` у `NodeSpec` удаляется. `extractNodeSections` удаляется.
Предупреждения `SectionsRecordDroppedWarning` и `SectionsConflictWarning`
удаляются: конфликту видов секций неоткуда взяться.

### 3. Редактор узла

Сохранение документа с `dns`, `route` или `sections`:

- узел сохраняется;
- пользователь получает сообщение, что остальное содержимое документа не
  сохранено.

Отказ «документ несёт и `sections`, и `dns`/`route`» снимается.

Что именно пишется в источник записи, решает
[§576](576-node-source-is-bare-body.md): только тело узла.

### 4. Импорт узлов

Мастер добавления сервера, вставка из буфера, файл: секции не извлекаются,
каноническая связка Tailscale новому узлу не назначается.

### 5. Сборка

Вливание секций удаляется целиком. Подстановка `@self` удаляется.

Инвариант: для состояния, в котором ни у одного узла не было секций, конфиг
совпадает с прежним байт в байт.

### 6. Интерфейс

Удаляются:

- блок Sections и кнопка Clear sections на экране узла;
- отметка Has node sections у члена папки;
- строки правил узла на экране маршрутов;
- плитки DNS-серверов и DNS-правил узла на экране DNS.

Остаётся выбор узла Tailscale в редакторе DNS-сервера типа `tailscale`
(`TailscaleEndpointOption`). Сейчас он собирается тем же кодом, что записи
секций (`collectNodeDnsRecords`). Его источник переносится на перечень узлов.

Строки интерфейса удалённых элементов удаляются из словарей всех языков.

### 7. Резервные копии

Экспорт: ключ `sections` не пишется ни у одной записи.

Импорт, условия:

1. в файле у записи любого вида есть ключ `sections`;
2. в нём есть хотя бы одна запись (правило, DNS-сервер или DNS-правило).

Поведение: поле снимается целиком с предупреждением
`backup_section_record_dropped`, причина `not_allowed`. Механизм есть
(`_dropForeignSections`), расширяется на записи своего сервера и члена папки.
Пустой набор предупреждения не даёт.

### 8. Debug API

Поле `sections` уходит из ответа у своего сервера и у члена папки. Текст
справки про секции узла в описании `DELETE /directions/{tag}` удаляется.

### 9. Подписка: закладка

Имя `sections` у записи подписки резервируется в контракте. В коде поля нет:
модель не хранит, кодек не пишет и не читает, интерфейса нет. Приехавшее в
резервной копии снимается по правилу раздела 7.

Две строки журнала в `sources.dart` про секции узла подписки удаляются. Узел
Tailscale из подписки получает связку от пресета наравне с остальными.

### 10. Что у Tailscale остаётся

- каталог состояния и его жизненный цикл (§445);
- hostname по умолчанию (§449);
- тип endpoint `tailscale`, его поля, санитайзер, build-тег ядра.

## Запрос в контракт

| Документ | Изменение |
|---|---|
| `NODE_SECTIONS.md` §1 | носителей секций нет; имя `sections` у подписки зарезервировано |
| `NODE_SECTIONS.md` §2, §3 | плейсхолдер `@self` и инъекция отменяются |
| `NODE_SECTIONS.md` §4, §5, норма E1 | экспорт не пишет секции; импорт снимает их у любой записи |
| `NODE_SECTIONS.md` §6 | каноническая связка Tailscale заменяется пресетом шаблона |
| `NODE_SECTIONS.md` §7 | требования к интерфейсу секций снимаются |
| код `tailscale_from_subscription` | теряет смысл, удаляется |
| корпус `v10_node_sections` | ожидание меняется: секции сняты, предупреждение `backup_section_record_dropped` |
| `ONE_NAMESPACE.md`, `BACKUP.md`, `GLOSSARY.md` | примеры и статьи о секциях узла |

Жизненный цикл каталога состояния Tailscale из `NODE_SECTIONS.md` остаётся
нормой и переносится в документ о протоколе.

### Реализация: фаза 1 (интерфейс)

Сделано:

- экран узла: блок Sections, кнопка и диалог Clear sections, сводка
  счётчиков удалены; переключатель Skip presets остался;
- экран папки: отметка Has node sections удалена;
- экран маршрутов: `routing_screen/node_rule_rows.dart` удалён, список таба
  Rules снова строится только из корневых правил; у `CustomRuleTile` сняты
  параметры строки узла (`canDelete`, `originLabel`, `dimmed`);
- экран DNS: плитки серверов и правил узла удалены
  (`widgets/node_dns_tiles.dart`), поля и перечитывание по слушателю
  контроллера тоже;
- выбор узла Tailscale в редакторе DNS-сервера: `node_dns_records.dart`
  переименован в `services/dns/tailscale_endpoint_options.dart`, опции
  собирает `collectTailscaleEndpointOptions` через `presetNodesForView`
  (включённые узлы `tailscale` своих записей, папок и подписок; тег последней
  сборки или отображаемый); `DnsSettingsSnapshot` поля узловых записей
  потерял;
- контроллер: `setUserServerSections`/`setMemberSections` удалены;
  `updateConnectionAt`/`updateMemberAt` больше не пишут `importedSections` в
  запись, прежние секции записи остаются до фазы 3;
- редактор документа: отказ «и `sections`, и `dns`/`route`» снят; документ с
  любым из этих ключей даёт узел и одно сообщение «Node saved. The rest of
  the document was not saved.»;
- строки интерфейса удалённых элементов убраны из словарей `ru`/`zh`.

Оставлено фазам 2 и 3: разбор (`importedSections`, `extractNodeSections`,
предупреждения секций, в том числе строка предупреждения на экране узла),
вливание в сборку, резервные копии, Debug API, `sources.dart`, импорт
(`sectionsForNewNode` в мастере и контроллере), модель, кодек хранения,
`tailscale_bundle.dart`, документация. Что пишется в источник записи — §576.

## Порядок выпуска

Эта задача и [§578](578-tailscale-preset-template-for-each.md) выходят в одном релизе. Порознь нельзя:
между ними узел Tailscale остаётся без маршрута и без DNS.

## Риски и edge cases

- **Узлы не Tailscale с секциями.** Пользователь теряет правила маршрутов и
  DNS, привязанные к узлу. Уведомления в интерфейсе нет, только строка в
  журнале. Решение владельца.
- **Связка Tailscale, правленная руками.** Правки теряются. Пресет даёт
  каноническую связку.
- **Откат на прошлую версию приложения.** Состояние, уже сохранённое без
  ключа `sections`, прошлая версия читает как узлы без секций. Узел Tailscale
  в ней останется без связки до ручного восстановления.
- **Висячие ссылки.** Корневое правило или DNS-правило пользователя могло
  ссылаться на DNS-сервер узла (`<тег>-dns`). После удаления секций такого
  сервера нет. Ссылка снимается общим санитайзером висячих ссылок сборки.
- **Общий код с выбором узла Tailscale** в редакторе DNS-сервера: удалять
  `node_dns_records.dart` целиком нельзя, пока источник выбора не перенесён.

## Верификация

Тесты удаляются вместе с кодом:

- `app/test/models/node_sections_test.dart`
- `app/test/builder/node_sections_build_test.dart`
- `app/test/screens/routing_screen/node_rule_rows_test.dart`
- `app/test/parser/singbox_sections_test.dart`
- `app/test/parser/tailscale_sections_test.dart`
- `app/test/contract/lx_backup_sections_test.dart`

Тесты переписываются:

- `app/test/models/tailscale_bundle_test.dart`: остаётся hostname;
- `app/test/services/node_dns_records_test.dart`: остаётся выбор узла
  Tailscale;
- `app/test/screens/node_settings/node_document_test.dart`: документ даёт
  узел, секции отброшены, отказа по конфликту видов нет;
- `app/test/contract/backup_corpus_test.dart`,
  `lx_backup_v10_test.dart`, `lx_backup_roundtrip_test.dart`: секции в файле
  сняты с предупреждением;
- `app/test/models/record_codec_sources_test.dart`: запись с ключом
  `sections` читается, узел без секций, при записи ключа нет;
- `app/test/subscription/singbox_config_import_test.dart`,
  `detour_direction_resync_test.dart`.

Критерии приёмки:

1. Запись хранилища с ключом `sections` читается без ошибки, в сборке её
   правила и DNS-записи не появляются.
2. После сохранения состояния ключа `sections` в хранилище нет.
3. Конфиг для состояния без секций совпадает с прежним байт в байт.
4. Резервная копия с секциями у своего сервера импортируется, узел на месте,
   в отчёте импорта предупреждение `backup_section_record_dropped`.
5. В приложении нет экрана, строки или кнопки со словом Sections в значении
   секций узла.
6. `grep -rn "@self" app/lib` пуст.

Прогон тестов — по одному затронутому файлу, полный прогон делает CI.

## Docs to update

| Файл | Что |
|---|---|
| `docs/STORAGE.md` | убрать `sections` из схемы записи и пример канонической связки |
| `docs/api/debug-api-reference.md` | убрать поле `sections` из ответа |
| `docs/ARCHITECTURE.md` | убрать инъекцию секций из описания сборки |
| `docs/PROTOCOLS.md` | Tailscale: связка приходит из пресета |
| `docs/spec/features/435 node-sections-tailscale/` | перенести в `docs/spec/tasks/` как историческую, с пометкой «отменена §575» |
| `CHANGELOG.md` | запись в Unreleased |

## Нерешённое / follow-up

- [§578](578-tailscale-preset-template-for-each.md): пресет Tailscale.
- [§576](576-node-source-is-bare-body.md): источник узла хранит только тело.
- Секции подписки: как включать, где показывать, использовать ли вообще.
