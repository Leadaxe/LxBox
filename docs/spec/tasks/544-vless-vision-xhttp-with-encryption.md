# 544 — VLESS: Vision у узла с encryption не снимается из-за транспорта

| Поле | Значение |
|------|----------|
| Статус | Open — ТЗ, ждёт контракт и ядро |
| Дата старта | 2026-09-25 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | контракт `registry/protocols/vless.json` (`flow.conflicts`), `schema/registry_body.schema.json` (`relation`); §335 (encryption), ядро SPEC 032 (VLESS encryption); ядро — [Leadaxe/sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29) (Vision поверх VLESS encryption) |

## Проблема

Подписка Assassin VPN отдаёт Xray-массив, в нём узел «Швеция (Прямая)»:
VLESS + Reality + **xhttp**, `flow: xtls-rprx-vision`,
`encryption: mlkem768x25519plus.native.0rtt.…`. У пользователя на сервере
включён Vision, поэтому запрос без `flow` сервер отклоняет: соединение
рвётся сразу после отправки. У Xray-инбаунда пустой flow при
vision-пользователе даёт отказ.

LxBox снимает `flow` с предупреждением `vision_with_transport` (info),
потому что правило контракта безусловное: «Vision несовместим с
транспортом». Для узла **с encryption** это неверно. В Xray Vision поверх
VLESS Encryption работает на слое шифрования (padding и фрейминг поверх
`CommonConn`), нижний TLS он не трогает, поэтому транспорт ему не важен,
xhttp в том числе. Панель выдаёт такую комбинацию штатно, автор подписки
подтверждает, что узел рабочий.

Итог сейчас: узел приезжает, но не поднимается (URLTest −1), и
пользователь не может понять почему. Предупреждение уровня info прямо
утверждает «снята бессмыслица, узел живёт», а узел как раз не живёт.

## Диагностика

Живой телефон (LxBox 2.25.1, core `1.14.1-lx.8`) через Debug API плюс
прогон ядра `v1.14.2-lx.2` с хоста на тех же реквизитах. Реквизиты лежат в
ядре, в `config.d/vision-over-vless-encryption/`: папка в gitignore, сюда их
не переносить.

| Узел | Транспорт | flow | encryption | Итог |
|---|---|---|---|---|
| Нейросети | tcp | vision | — | ✅ |
| Германия (Прямая) | xhttp | — | mlkem | ✅ |
| Польша [Игровой] | grpc | — | mlkem | ✅ |
| Швеция_MOBILE_GAMES | tcp | vision | mlkem | ❌ ядро: `vision: not a valid supported TLS connection: *encryption.CommonConn` |
| Швеция (Прямая), flow возвращён руками | xhttp | vision | mlkem | ❌ та же ошибка ядра |
| Швеция (Прямая), как собирает LxBox (flow снят) | xhttp | — | mlkem | ❌ сервер рвёт соединение (пользователь с vision) |

Выводы:

1. Корень в ядре: Vision не умеет работать поверх `encryption.CommonConn`
   (`sing-vmess v0.2.8` `vless/vision.go`, `tlsRegistry`). Это чинит ядро:
   [Leadaxe/sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29).
2. Даже после фикса ядра «Швеция (Прямая)» не заработает, пока LxBox
   снимает `flow`. Эта задача про это.
3. Ложный след: версия «потерялся flow» объясняет только xhttp-узел.
   MOBILE_GAMES (tcp) приходит с `flow` и падает в ядре.
4. Ложный след: `source_kind: uri_lines` у этой подписки в
   `GET /subs/{id}?warnings=true`. Вид считается по `entryRawText`, а для
   подписки это URL, а не тело (`debug/serializers/subs.dart`, `entryRawText`).
   Фактическое тело — Xray JSON (`content-type: application/json`).

## Решение (ТЗ)

### 1. Контракт (лаунчер, `contract/`), новая версия 1.1.x

1. **Схема `relation`** (`schema/registry_body.schema.json`,
   `definitions/relation`): добавить условие-исключение, при котором связь
   **не действует**. Предлагаемая форма:
   `"unless_set": ["encryption"]`. Это список путей от корня тела; связь
   пропускается, если задан ЛЮБОЙ из них. Семантика наличия та же, что у
   `any_set` в условиях правил значения: считается наличие ключа, а не
   непустота. Имя и форму решает лаунчер, лишь бы это было общее средство
   схемы, а не частный флаг у vless.
2. **`registry/protocols/vless.json`, `flow.conflicts`**:
   `{"with": "transport", "code": "vision_with_transport", "unless_set": ["encryption"]}`.
   Опора: запись `encryption` (§335) кладёт поле в тело только при
   непустом и не `none` значении (сравнение с `none` точное, с учётом
   регистра). Значит, «encryption есть в теле» совпадает с «слой
   шифрования есть», и отдельной проверки значения не нужно.
3. **`impl`/`desc` у `flow`**: переписать прозу. Vision несовместим с
   транспортом только без encryption; с encryption Vision идёт на слое
   шифрования и транспорту безразличен (Xray). Тело при этом валидно для
   ядра с фиксом Vision+encryption.
4. **`registry/warnings.json`, `vision_with_transport`**: уточнить текст:
   код срабатывает только у узла без encryption. Severity не меняется.
5. **Порядок судейства**: `encryption` должен быть уже в теле (или виден
   через `srcRoot`, как `transport` сейчас) в момент проверки связей
   `flow`. Сейчас связи читают исходное тело (pathPresent → srcRoot), так
   что условие видит `encryption` независимо от `body.order`. Проверить и
   зафиксировать это в `impl`.
6. **Корпус** (новые кейсы, `expected` для обеих сторон):
   - `uri/vless/flow_vision_xhttp_encryption_kept`: `vless://…?type=xhttp&security=reality&flow=xtls-rprx-vision&encryption=mlkem768x25519plus.native.0rtt.<ключ>`
     → `flow` в теле, `transport.type=xhttp`, `encryption` в теле, **без**
     `vision_with_transport`;
   - `body/xray/vless_vision_xhttp_encryption.body`: Xray-массив формы
     Assassin (`streamSettings.network: xhttp`, `users[0].flow`,
     `users[0].encryption`), результат тот же;
   - `body/singbox/…`: sing-box outbound с `flow` + `transport` +
     `encryption`, тот же;
   - регрессия: `encryption=none` (точное) + xhttp + flow → `flow` снят,
     `vision_with_transport` (как в `flow_vision_xhttp_suppressed`);
   - регрессия: `encryption=None` (другой регистр) + xhttp + flow → это
     настоящее значение (§335), `flow` сохраняется;
   - существующие `flow_vision_xhttp_suppressed`,
     `flow_vision_ws_suppressed`, `body/xray/vless_vision_with_transport`
     не меняются.
   Ключи и адреса в корпусе синтетические (`example-1.com`, выдуманный
   base64-ключ нужной длины), живые реквизиты из `config.d` не брать.
7. **`TASKS_LXBOX.md`**: раздел под новую версию. Что синкнуть и что
   сделать в Dart (п. 2 ниже).

### 2. LxBox

1. `bash app/tool/sync_contract.sh --to <sha лаунчера>`; зеркала
   `app/assets/contract`, `docs/contract` обновятся скриптом.
2. Dart-движок санитайзера связей (`conflicts` в
   `lib/services/contract/…`, найти по коду `vision_with_transport` /
   чтению `relation`): поддержать новое поле схемы. Если связь несёт
   `unless_set` и в исходном теле присутствует любой из путей, связь
   пропускается целиком: без снятия поля и без кода. Без новой логики
   синк-тест схемы (`registry_sync_test`) упадёт на незнакомом ключе, и это
   правильно.
3. `lib/services/parser/uri_parsers/vless_parser.dart:29` и
   `lib/models/node_warning.dart:174` упоминают `vision_with_transport`
   только в комментариях-ссылках на реестр, своего снятия `flow` там нет
   (проверено 25.09.2026). После правки проверить, что так и осталось:
   решение принимает только реестр.
4. Тесты: только затронутый файл
   (`test/contract/contract_test.dart` по новым кейсам корпуса, плюс
   файл теста движка связей, если он отдельный). Полный прогон — в CI.

### Что НЕ входит

- Фикс ядра: Vision поверх `CommonConn`. Это отдельная работа сессии ядра.
  После неё tcp-узлы вида MOBILE_GAMES заработают без правок в LxBox.
- UDP через Vision: поведение не меняется.

## Риски и edge cases

- **Порядок выката.** Пока ядро не умеет Vision+encryption, узел с
  сохранённым `flow` падает в ядре при дозвоне. Сейчас без `flow` он
  падает на сервере, так что пользователь ничего не теряет. Конфиг ядро
  принимает: `sing-box check` на `v1.14.2-lx.2` проходит, весь конфиг не
  валится. Выкатывать можно в любом порядке.
- **Тело меняется у существующих узлов** (появляется `flow`). Identity не
  меняется: в `docs/IDENTITY.md` контракта `flow` не упоминается (проверено
  25.09.2026 на 1.1.52). Узлы не пересоздаются, меняется только тело.
- **Сервер без Vision.** Узел с encryption + xhttp + `flow` у пользователя
  без Vision на сервере. В Xray сервер отвергает несовпадающий flow; тогда
  ошибся автор ссылки, и мы передаём ровно то, что он написал. Это
  поведение Xray-клиентов.
- **Лаунчер (десктоп)** получает тот же `flow` в теле. Его ядро должно
  иметь тот же фикс, иначе узел там тоже падает при дозвоне. Отметить в
  `TASKS_LXBOX.md` / на стороне лаунчера.

## Верификация

- Корпус из п. 1.6 зелёный в Go-раннере лаунчера и в
  `test/contract/contract_test.dart`.
- На устройстве после синка и после ядра с фиксом: подписка Assassin →
  у «Швеция (Прямая)» `GET /subs/{id}?warnings=true` без
  `vision_with_transport`, в `GET /config` у узла есть `flow`,
  `POST /action/urltest?tag=…` даёт задержку, а не −1.
- До фикса ядра: `flow` в конфиге есть, узел −1, ошибка ядра
  `vision: not a valid supported TLS connection` (подтверждает, что дело
  уже только в ядре).

## Нерешённое / follow-up

- `source_kind` для подписки в `/subs/{id}?warnings=true` считается по
  URL, а не по телу, и вводит в заблуждение при разборе. Отдельная мелкая
  задача Debug API.
- Hysteria2 `finalmask.udp[0]` salamander из той же подписки уже закрыт
  (§512, контракт 1.1.48, релиз 2.25.2). На телефоне стоит 2.25.1, отсюда
  там −1 у FAST_WIFI. Отдельная задача не нужна.
