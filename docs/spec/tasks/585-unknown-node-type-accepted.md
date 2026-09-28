# 585 — Узел sing-box незнакомого приложению типа принимается

| Поле | Значение |
|------|----------|
| Статус | Implemented |
| Дата старта | 2026-09-28 |
| Дата завершения | 2026-09-28 |
| Коммиты | fcebe0c4 |
| Контракт | Не затрагивается (код предупреждения свой, per-app) |
| Связанные spec'ы | tasks/576, tasks/577, features/455 (дословное тело) |

## Проблема

Владелец на эмуляторе (ядро 1.14.2-lx.6): Add server → Paste JSON, вставлен
рабочий узел `"type": "openvpn-client"` с `detour`, `tls.certificate_path` и
комментарием `// United States Central` в строке `server`. Приложение отвечает
«No valid outbounds in JSON» (`ErrKey.noValidOutboundsInJson`). Ядро тип
знает (`constant/proxy.go`, тег сборки `with_openvpn` в пине), приложение — нет.

Норма владельца (27.09.2026, §576/§577): узел, написанный руками в форме ядра,
уходит в ядро как написан; приложение сообщает, но не правит и не запрещает.
Жёсткие случаи: запись без строкового непустого `type`; `drop_node` по ядру;
правила реестра с `core_rejects`. Незнакомый тип в жёсткие случаи не входит.

## Диагностика

Отказ дают **обе** причины, каждая по отдельности:

1. **Комментарий.** `decode` разбирает JSON строгим `jsonDecode`; на `//` он
   падает, текст уходит в ветку списка ссылок (`UriLines`), и `_addJsonNodes`
   передаёт его в `_addUriLines` → ноль узлов → `noValidOutboundsInJson`.
   Проверено: тело `vless` с одним `//` даёт `UriLines`, ноль узлов.
2. **Тип.** Без комментария `parseSingboxEntry` (`json_parsers.dart`) на типе
   вне своего `switch` отдаёт `null`, `_parseOne` (`singbox_config.dart`)
   пишет в `dropped[]` `protocol_unsupported` и узла не выпускает.

Место в конфиге: у известных типов его задаёт класс узла (`emitRaw` →
`Outbound`/`Endpoint`), перечня типов-endpoint в приложении не было. Ядро
lx.6 регистрирует `openvpn-client` как **endpoint**
(`include/openvpn.go` → `openvpn.RegisterEndpoint`,
`protocol/openvpn/endpoint.go`: `endpoint.Register[…](registry,
C.TypeOpenVPNClient, …)`); так же `openconnect`, `wireguard`, `tailscale`.

## Решение

Узел принимается, когда выполнены все условия:

1. вход — sing-box JSON: голое тело, документ с `outbounds`/`endpoints` или
   массив тел;
2. создаётся своя запись (Add server, вставка, файл) или член папки, либо
   правится узел в редакторе узла; узлы подписок — поведение прежнее;
3. у записи есть строковое непустое поле `type`;
4. тип не служебный (`direct`, `block`, `dns`) и не группа (`selector`,
   `urltest`) — для них поведение прежнее;
5. тип приложению незнаком (нет в `kAppSingboxNodeTypes`); известный тип с
   негодной формой (например `vless` без `server`) отбрасывается, как раньше.

Для такого узла:

- модель `UnknownTypeSpec` (`models/node_spec.dart`): тело записи целиком,
  `protocol` = `type`; `emitRaw` отдаёт тело (без `detour`, с тегом узла);
- источник записи — голое тело (вид `singbox_outbound`); в конфиг тело идёт
  дословно прежним путём `verbatimBodyOf` (`detour` снимается, пустой `tag`
  заполняется);
- одно предупреждение уровня info `UnknownNodeTypeWarning`: заголовок
  «Unknown node type», текст «The app does not know this node type and does
  not check it. The node goes to the core as written.» Подходящего кода в
  реестре нет: `protocol_unsupported` — уровня `error` и говорит «узел
  отброшен». Поэтому код свой, per-app: `unknown_node_type` в
  `kWarningCodes` (как `duplicate` §538), в `warnings.json` не заносится;
- проходы реестра по узлу (`annotateWithRegistry`, `annotateFromRawBody`)
  его пропускают: схемы типа нет, тело не проверяется;
- знак по умолчанию в теге — общий `_autoEmoji`, как у прочих узлов;
- место в конфиге: `endpoints[]`, если тип в `kCoreEndpointTypes`
  (`wireguard`, `tailscale`, `openvpn-client`, `openconnect` — по
  регистрациям ядра lx.6), иначе `outbounds[]`;
- в списки выбора (selector, автовыбор) узел входит как обычный;
- проба и замер задержки: проба строит тело из `emit()` узла, у
  `UnknownTypeSpec` это и есть дословное тело — узел пробуется как обычный.

Где решается «своя запись»: флаг разбора `parsingOwnSource`
(`authored_scope.dart`) ставит `parseAll(own: true)` — им разбираются
источники своих серверов, членов папок и редактора. Вставка (`_addJsonNodes`)
сначала разбирает текст обычным путём; не вышло ни одного узла — спрашивает
`acceptsOwnUnknownType` (`parse_all.dart`): разбор как своего источника дал
ровно один узел незнакомого типа → запись своего сервера с ним. Многоузловая
вставка становится файловой подпиской, и незнакомый тип в ней отбрасывается,
как в любой подписке. Превью буфера обмена (`clipboard_analysis.dart`)
спрашивает тот же гейт и отбраковки не показывает.

Комментарии: `uncommentedJson` (`services/parser/json_comments.dart`) снимает
`//` и `/* */` вне строковых литералов, когда выполнены все условия: текст
начинается с `{` или `[`; строгий JSON-разбор исходного текста падает;
комментарий есть; текст без комментариев — строгий JSON. Прочие байты не
меняются. Места: `addFromInput` (Add server, вставка в строку списка, буфер
обмена), превью буфера, Save вкладки Source в редакторе узла
(`prepareNodeDocumentForSave`). В источник пишется текст без комментариев;
пользователю одно сообщение «Comments were removed.» (вместо «Added» /
«Saved»). Проверка ядром на Save редактора (`checkPayloadFor`) разбирает текст
как свой источник, так что узел незнакомого типа тоже проверяется ядром.

## Риски и edge cases

- Вставка документа из двух записей, одна из которых незнакомого типа:
  известный узел становится своим сервером, незнакомый отбрасывается с
  причиной в `dropped[]` (обычный разбор дал узел, гейт не спрашивается).
- `nodeIdentityKey` узла незнакомого типа: `type|server|port|username` из
  тела.
- `kCoreEndpointTypes` — перечень из исходников ядра; новый endpoint-тип ядра
  до правки перечня уйдёт в `outbounds[]`, и ядро отвергнет конфиг на Save
  (`CheckConfig`).

## Верификация

`test/subscription/unknown_node_type_test.dart`: вставка тела незнакомого типа
создаёт запись с источником `singbox_outbound`, одним info-предупреждением и
знаком в теге; тело в конфиге дословное, в `endpoints` для `openvpn-client` и
в `outbounds` для прочего типа; проба строит тело; тело без `type`
отклоняется; служебные типы и группы узла не создают; известный тип с
негодной формой отбрасывается; вход с комментариями принимается, источник без
комментариев, строка с `https://` внутри значения не тронута; узел подписки
незнакомого типа не создаётся. Прогнаны также `test/models/node_warning_test.dart`,
`test/models/node_spec_test.dart`, `test/builder/verbatim_body_test.dart`,
`test/contract/node_edit_corpus_test.dart`; `hardcoded_check`, `ui_check --strict`
— 0/0; `flutter analyze` чистый.

## Реализация

Коммит fcebe0c4; изменения задачи 586 — 707d118d.

- `models/node_spec.dart` — `UnknownTypeSpec`, `kCoreEndpointTypes`.
- `models/node_warning.dart` — `UnknownNodeTypeWarning`;
  `services/contract/warning_codes.dart` — код `unknown_node_type`.
- `services/parser/json_parsers.dart` — `kAppSingboxNodeTypes`;
  `singbox_config.dart` — `_ownUnknownTypeNode`; `authored_scope.dart` —
  `parsingOwnSource`; `parse_all.dart` — флаг в `parseAll`,
  `acceptsOwnUnknownType`; `contract/parse_warnings.dart` — пропуск узла.
- `services/parser/json_comments.dart` — снятие комментариев.
- `controllers/subscription_controller.dart` — гейт вставки,
  `lastCommentsRemoved`; экраны `add_server_wizard_screen.dart`,
  `subscriptions_screen.dart`, `clipboard_analysis.dart`,
  `node_settings/node_document.dart`, `node_settings_screen.dart`,
  `node_notifications_view.dart` (текст карточки).
- l10n: три строки в `ru`/`zh`.

### Изменено задачей 586 (контракт 1.1.99)

- `kCoreEndpointTypes` убран: раздел конфига узла `UnknownTypeSpec` берётся
  из `kind` записи реестра (`ContractRegistry.isEndpointType`); тип вне
  реестра пишется в `outbounds[]`. Риск «новый endpoint-тип ядра до правки
  перечня» перешёл в реестр контракта.
- `openvpn-client` стал типом реестра (`fields_unchecked`): принимается из
  любого источника без предупреждения. Незнакомый тип в тестах этой задачи —
  выдуманный `future-proto`. Подробно —
  [586](586-endpoint-types-from-registry.md).

## Нерешённое / follow-up

- Предупреждение без кода реестра: у лаунчера аналога нет; если лаунчер
  заведёт код для незнакомого типа, класс заменить на `RegistryWarning`.
