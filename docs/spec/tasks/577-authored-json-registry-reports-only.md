# 577 — Авторский JSON: реестр сообщает, не правит

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-27 |
| Дата завершения | 2026-09-27 |
| Коммиты | b49e5677 (код, тесты, документы) |
| Контракт | 1.1.87–1.1.89: авторское тело, `core_rejects`, `applied`, корпус `authored/` (TASKS_LXBOX §84–§86) |
| Связанные spec'ы | [§576](576-node-source-is-bare-body.md) (условие авторского тела), [features/460](../features/460%20contract-registry-bundle/spec.md), [§574](574-tls-fragment-yields-to-detour.md), [§473](473-contract-115-awg-mtu-by-registry.md) (исключение по входу для MTU), [features/478](../features/478%20core-rejected-node-auto-disable/spec.md) |

## Проблема

Узел, написанный руками в форме ядра, считается дословным. Диалог Edit JSON
обещает: узел уйдёт в ядро как есть, приложение перестаёт его проверять. На
сборке обещание не выполняется: несколько шагов переписывают тело по правилам
реестра.

Часть правил реестра спорная. Пользователь нарушает их сознательно, на своей
сети и на свой риск. Примеры: MTU WireGuard выше рекомендованного, поля,
которые реестр считает лишними.

## Решение владельца (27.09.2026)

На авторском теле реестр сообщает, но ничего не меняет.

## Условие авторского тела

Тело авторское, когда выполнены все четыре условия (те же, что у дословности
в §576):

1. контейнер: свой сервер или член папки;
2. узел не группа автовыбора;
3. вид источника записи ровно `singbox_outbound`;
4. текст узла разбирается как JSON-объект.

Узел подписки авторским не бывает, даже если провайдер прислал sing-box JSON.

Условием не являются: кто набрал текст, вид хранения `json`, факт правки.

## Диагностика

Шаги сборки, которые меняют тело узла (известные на момент спеки):

| Шаг | Где | Что делает |
|---|---|---|
| гейт реестра | `app/lib/services/builder/registry_gate.dart` | санитайзер, тело переписывается на месте, узел может быть снят |
| уступка detour | `app/lib/services/builder/detour_yields.dart`, вызов в `build_config.dart` и `probe_config.dart` | снимает `tls.fragment`, `listen_port` |
| починка отпечатков uTLS | `app/lib/services/builder/post_steps/heal_unknown_utls_fingerprints.dart` | заменяет неизвестный отпечаток |
| глобальные настройки TLS | `app/lib/services/builder/post_steps/tls_transforms.dart` | дописывает фрагментацию, меняет регистр SNI |

Сегодня набор дословных записей (`verbatimEntries`) виден только гейту
реестра и влияет только на правила с `except_sources`.

### Опись шагов сборки и пробы, меняющих тело узла

| Шаг | Где | Что меняет | Решение §577 |
|---|---|---|---|
| подстановка дословного тела | `server_list_build.dart` → `verbatimBodyOf` | снимает `detour`, пустой `tag` = тег модели | не правило реестра: `tag`/`detour` пишет сборка; ставит `authored` |
| гард реестра | `registry_gate.dart` | санитайзер: снятие, замена, дефолты, снятие узла | через точку правки |
| узловой гейт ядра | `registry_gate.dart` → `nodeCoreRefusal` | снимает узел | жёсткое |
| страховка `type` | `registry_gate.dart` | снимает запись без `type` | жёсткое |
| уступка detour | `detour_yields.dart` из `tls_transforms.dart` (`applyDetourYields`) и `probe_config.dart` | снимает `listen_port`, `tls.fragment`, `fragment_fallback_delay` | через точку правки |
| глобальные настройки TLS | `post_steps/tls_transforms.dart` (`applyTlsFragment`, `applyMixedCaseSni`) | дописывает фрагментацию, регистр SNI | не меняется (раздел 5) |
| страховка uTLS | `post_steps/heal_unknown_utls_fingerprints.dart` | отпечаток, снятие uTLS/REALITY на QUIC | через точку правки (`utls_fp_unknown`, `tls_not_applicable_quic`) |
| страховка REALITY | `post_steps/heal_invalid_reality.dart` | снимает блок REALITY, обнуляет `short_id` | через точку правки (`reality_pbk_invalid`, `reality_short_id_invalid`) |
| граф-санитайзер | `post_steps/sanitize_outbound_graph.dart` | висячий `detour`, члены групп | не тело узла: `detour` пишет сборка |
| DNS-ссылки узла | `post_steps/heal_detour_dropped_dns.dart` | `domain_resolver` на выпавший DNS-сервер | ссылка графа на сервер шаблона, не правило реестра |
| префикс тегов | `post_steps/heal_preset_tag_prefix.dart` | `tag` | не тело узла |
| проба: гард реестра | `probe/probe_config.dart` | как гард сборки | тело пробы — `emit()` модели, авторским не бывает |
| проба: `insecure_concurrency` | `probe/probe_config.dart` | снимает у naive | только проба, не правило реестра |

### Замер до правок

Санитайзер (вход `singbox`, без гейтов ядра) по кейсам `corpus/body/singbox/`
и `corpus/authored/` (контракт 1.1.89): 84 тела узлов, из них 51 санитайзер
меняет (8 снимает целиком). Коды у изменённых тел:

| Код | Число |
|---|---|
| `unknown_key` | 10 |
| `tls_field_unsupported_naive` | 9 |
| `masque_tls_field_ignored` | 6 |
| `tls_alpn_item_invalid`, `field_requires`, `tls_not_applicable_quic` | по 3 |
| `flow_deprecated`, `vless_encryption_invalid`, `wg_key_invalid`, `tailscale_default_route_advertised`, `tls_fragment_system_engine`, `reality_pbk_invalid`, `masque_tls_fragment_h3` | по 2 |
| `awg_headers_overlap`, `awg3_header_key_invalid`, `packet_encoding_unknown`, `reality_short_id_invalid`, `type_invalid`, `awg_header_invalid`, `awg3_padding_too_short`, `obfs_object_flattened`, `reality_fp_random_pinned`, `hysteria2_server_ports_item_invalid`, `field_conflict`, `reality_key_share_invalid`, `xhttp_param_reset`, `obfs_password_missing`, `ssh_user_default`, `fields_order_invalid`, `xhttp_mode_forced_packet_up`, `reality_utls_enabled`, `port_invalid` | по 1 |

Корпус — это тела с нарушениями нарочно; сохранённые состояния стенда не
замерялись.

## Решение

### 1. Свойство записи сборки

Запись сборки получает свойство «тело авторское». Его видят все шаги сборки
и пробы. Набор `verbatimEntries` заменяется этим свойством.

### 2. Одна точка правки

Правка тела узла по правилу реестра идёт через одну функцию. Поведение:

| Тело | Правило мягкое | Правило жёсткое |
|---|---|---|
| обычное | правка применяется, предупреждение | правка применяется, предупреждение |
| авторское | тело не меняется, предупреждение с признаком «не применено» | правка применяется, предупреждение |

Прямая запись в тело узла из шага сборки, минуя эту функцию, запрещена.
Проверяется тестом по исходникам: шаги из описи не содержат прямого
присваивания в карту тела.

### 3. Жёсткие правила

Действуют и на авторском теле:

1. запись без строкового непустого `type`: узел снимается;
2. `drop_node` по ядру (`build_tag`, `min_core`): узел снимается;
3. правило или связь реестра с признаком отказа ядра: правка применяется.

Третий пункт решает машинное поле `core_rejects` реестра (контракт 1.1.87,
перечень помеченных правил — TASKS_LXBOX §84 п.3; `vless.flow` — 1.1.88).
Перечень по прозе `impl` не составляется. Тихий `default_when` с
`core_rejects` (`hysteria.up_mbps`) пишется и в авторское тело.

### 4. Уступка detour на авторском теле

`tls.fragment` при назначенном `detour` не снимается, узел получает
предупреждение с признаком «не применено».

`listen_port` WireGuard при назначенном `detour`: ядро отказывает конфигу
(sing-box-lx `protocol/wireguard/endpoint.go`, NewEndpoint), правило жёсткое
(`core_rejects` у связи, контракт 1.1.87).

### 5. Глобальные настройки TLS

Поведение не меняется. Это настройки пользователя, а не правила реестра.

### 6. Разбор

Предупреждения реестра при разборе авторского узла получают тот же признак
«не применено». Тело при разборе не меняется и сейчас.

Коды, которые сегодня даёт только гейт сборки (`unknown_key`,
`flow_deprecated` и прочие), у авторского узла появляются и при разборе:
санитайзер прогоняется по дословному телу, берутся только предупреждения.

### 7. Предупреждение с признаком «не применено»

`NodeWarning` получает признак `applied` (по умолчанию `true`).

Показ в карточке узла при `applied: false`:

| Часть | Что показывается |
|---|---|
| заголовок | заголовок кода из реестра |
| что произошло | общая строка вместо текста реестра: узел написан вручную, приложение ничего не изменило |
| причина | из реестра |
| что можно сделать | из реестра |

Текст реестра «что произошло» не показывается: он утверждает, что поле
изменено. Парных кодов и вторых текстов в реестре не заводится.

Уровень предупреждения не меняется.

Debug API отдаёт признак `applied` в составе предупреждения.

### 8. Отчёт сборки

Строка отчёта для неприменённого правила получает пометку `not applied`.

## Запрос в контракт

| Что | Норма |
|---|---|
| авторское тело | четыре условия; реестр на нём сообщает, не правит |
| признак отказа ядра | машинное поле у правила или связи реестра: нарушение роняет старт конфига |
| признак предупреждения | `applied: false` |
| исключения по входу (`except_sources`) | теряют смысл для входа `singbox`: общее правило их покрывает; парный код `awg_mtu_high` остаётся как код, который отдаётся вместо `awg_mtu_clamped` |

## Риски и edge cases

- **Узлы, работающие благодаря починке.** После изменения ядро получает тело
  как написано. До реализации нужен замер по корпусу и по сохранённым
  состояниям стенда: сколько авторских тел реестр сейчас меняет и какими
  кодами. Замер делает Sonnet-агент, таблица вносится в спеку.
- **Отказ ядра всему конфигу** из-за авторского узла. Защита: `checkConfig`
  при сохранении и автоснятие узла после отказа ядра (фича 478). `checkConfig`
  недоступен без моста, тогда сохранение не блокируется.
- **Проба** собирает конфиг тем же гейтом. Поведение меняется и там.

## Верификация

Тесты (гонять только затронутые файлы):

- гейт реестра: авторское тело с мягким нарушением выходит без изменений,
  предупреждение есть, `applied: false`;
- гейт реестра: авторское тело с жёстким нарушением правится или снимается;
- уступка detour: авторское тело сохраняет `tls.fragment`;
- обычное тело: поведение прежнее, эталоны не меняются;
- тест по исходникам из раздела 2.

Критерии приёмки:

1. Авторское тело с мягкими нарушениями попадает в конфиг байт в байт, за
   вычетом `detour` и `tag`.
2. Конфиг для состояния без авторских узлов совпадает с прежним байт в байт.
3. Каждое неприменённое правило видно в карточке узла и в Debug API.

## Docs to update

| Файл | Что |
|---|---|
| `docs/GUARDS.md` | колонка «на авторском теле» для каждой защиты |
| `docs/ARCHITECTURE.md` | свойство записи сборки, точка правки |
| `docs/api/debug-api-reference.md` | поле `applied` |
| `CHANGELOG.md` | запись в Unreleased |

## Реализация

- Точка правки: `app/lib/services/contract/body_edit.dart` —
  `ruleCoreRejects` (признак `core_rejects` у правила поля, связи поля и связи
  тела; код из `forbidden_codes` мягкий), `decideBodyEdit`,
  `applyRegistryEdits` (обычное тело — итог целиком на месте; авторское —
  только пути жёстких кодов и `hardPaths`), `settleSanitized` (итог
  санитайзера; снятие узла у авторского тела только по жёсткому коду),
  `editBodyPath` (страховки сборки). Реестр не загружен — правило жёсткое,
  поведение прежнее.
- Санитайзер: `SanitizeResult.hardPaths` (тихий `default_when` с
  `core_rejects`), `dropFrom` (код снятия узла; код ставится до флага),
  `partial`.
- Раздел 1: `SingboxEntry.authored` ставит `ServerListBuild` там, где
  `verbatimBodyOf` подставил тело; `verbatimEntries`/`noteVerbatim` удалены.
  Шаги конфига получают identity-множество тел авторских записей.
- Раздел 2: гард реестра, уступка detour, страховки uTLS и REALITY пишут в
  тело только через точку правки; тест по исходникам
  `test/builder/body_edit_point_test.dart`.
- Раздел 6: `annotateFromRawBody` и `_sanitizedEntry` идут через
  `settleSanitized` при `parsingAuthoredBody`.
- Раздел 7: `NodeWarning.applied` (у `RegistryWarning` поле, в `props` только
  `false`); карточка узла при `applied: false` показывает общую строку «The
  node is written by hand, so the app changed nothing in it.» (ru, zh);
  Debug API — `applied` у каждой записи.
- Раздел 8: строка отчёта сборки — пометка `(not applied)` (гард и уступка
  detour).
- Корпус: раннер `corpus/authored/` в `node_edit_corpus_test.dart` (6 кейсов,
  строго, с `applied`); `node_edit` сверяет `applied`; `warningRecordOf` пишет
  `applied: false`.
- Изменённые ожидания (`registry_gate_test.dart`): дефолт `mtu: 1280`
  AmneziaWG авторскому телу больше не дописывается; узел с негодным
  `vless.encryption` на авторском теле не снимается (у правила нет
  `core_rejects`) — прежнее снятие проверяется на обычном теле.
- Бэкап: записи предупреждений узла в файл не пишутся (пересчитываются при
  импорте), `applied` там не нужен.

### Жёсткие правила контракта 1.1.91–1.1.92

Контракт 1.1.91 поставил `core_rejects` ещё 29 правилам: ядро отвергает их
нарушение при разборе конфига или создании узла (сверка по sing-box-lx —
TASKS_LXBOX §88). На авторском теле они теперь применяются:

- `vless.encryption` (`vless_encryption_invalid`, drop_node);
- `shadowsocks.method` (`ss_method_invalid`, drop_node);
- WireGuard: `private_key`, `peers[].public_key`, `peers[].pre_shared_key`
  (`wg_key_invalid`), `peers[].port` (`port_invalid`), `peers[].allowed_ips`,
  `header_protection_key` (`awg3_header_key_invalid`), `id`/`ip`/`ib`
  (`awg3_field_invalid`);
- REALITY: `public_key`, `short_id`, `key_share`;
- xhttp: `session_placement`, `seq_placement`, `x_padding_placement`,
  `x_padding_method` (`xhttp_param_reset`);
- `tuic.uuid`, `naive.quic_congestion_control`, `masque.profile`,
  `masque.private_key`, `masque.public_key`, `hysteria.obfs`,
  `server_ports` у hysteria и hysteria2, `tailscale.advertise_routes`.

Мягкими остались `server` и `peers[].address` (ядро принимает негодный адрес
как домен), `on_core_unsupported` и пароль shadowsocks 2022 (в реестре нет
правила). Точка правки `body_edit.dart` читает путь с индексом в скобках
(`peers[0].port`, `server_ports[0]`), правка элемента переносится массивом
целиком (контракт 1.1.92, то же в Go).

Расхождения движков, найденные корпусом 1.1.91 и оставленные открытыми
(кейсы сняты из корпуса в 1.1.92, TASKS_LXBOX §89): авторский узел с
негодным `tuic.uuid` или `peers[].allowed_ips` не снимается; мусорный
`reality.public_key` снимает объект `reality` с `field_missing`;
`reality.short_id` длиннее 16 не снимается; sing-box JSON hysteria v1 и masque
без ключей не читается (`protocol_unsupported`).

## Нерешённое / follow-up

- Контракт: `drop_node` без `core_rejects` при прозе «ядро отвергает конфиг»
  (`vless.encryption`, метод shadowsocks) и `tls.reality.public_key` /
  `short_id` («invalid public_key на весь конфиг») на авторском теле мягкие.
  Нужен запрос лаунчеру: пометить `core_rejects`, если отказ старта верен.
- Проба собирает тело из `emit()` модели, а не дословное тело: авторский
  узел проба проверяет в форме модели.

- Явное значение TLS в теле узла сильнее глобальной настройки. Отдельная
  задача, ждёт решения владельца.
