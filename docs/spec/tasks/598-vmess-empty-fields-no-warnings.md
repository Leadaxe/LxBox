# §598 — Пустые поля vmess-ссылки не дают предупреждений

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | D (сделано) |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.ru.md) |
| Дата | 2026-09-30 |
| Связанные | §597, корпус `73-github-full` |

## Проблема

v2rayN-ссылка `vmess://<base64 JSON>` по обычаю несёт все ключи, даже
пустые. Пример из подписки OVI-vpn (`73-github-full`):

```json
{"v":"2","ps":"🇪🇺 AetrisVPN","add":"45.32.57.118","port":"4433","id":"…",
 "aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"",
 "tls":"none","sni":"","alpn":"","cs":"","fp":"","insecure":""}
```

Эмит правильный (vmess, tcp, без TLS). Но на узле около 15 предупреждений:
`uri_param_unknown` и `unknown_key` на `host`, `path`, `sni`, `alpn`, `fp`,
`insecure`, `cs`. Каждый ключ назван дважды (оба кода), `cs` — трижды.
Второй узел той же подписки — то же, с `"insecure":"0"`, `"aid":"64"`,
`"tls":""`.

## Ожидаемое поведение

1. **Пустое значение = ключа нет.** Пустая строка у любого ключа v2rayN-JSON
   не даёт никакого предупреждения.
2. **Известный ключ v2rayN не бывает «неизвестным».** `host`, `path`, `sni`,
   `alpn`, `fp`, `insecure` объявлены в реестре vmess. Если такой ключ
   непуст, но неприменим (например, `sni` при `tls: none`, `path` при
   `net: tcp`), это не `uri_param_unknown`/`unknown_key`: значение молча не
   применяется. Если реестр для такого случая объявляет свой код, остаётся он.
3. `cs` (v2rayN: `client security` / шифр) при пустом значении молчит; при
   непустом — одно предупреждение, не три.
4. **Один ключ — не больше одного предупреждения.** Если оба кода
   (`uri_param_unknown` для ссылки и `unknown_key` для тела) выставляются на
   одну и ту же причину, остаётся один.

Найти, где это решается: реестр (`registry/protocols/vmess.json`, секция
`mappers.uri` формы v2rayn) или движок Dart (`interpreter.dart`,
санитайзер). Контракт (`app/assets/contract`, `app/contract`) не трогать;
если нужна правка контракта — остановиться и описать её.

## Критерии приёмки

1. Оба vmess-узла `73-github-full`: ноль предупреждений `uri_param_unknown` и
   `unknown_key`; эмит не меняется.
2. Непустой по-настоящему неизвестный ключ (`"zzz":"1"`) по-прежнему даёт
   ровно одно предупреждение.
3. Юнит-тест на пункты 1–4 ожидаемого поведения.
4. `expected.json` корпуса — отдельным коммитом оркестратора.

## Диагностика

Реестр ни при чём: `host`, `path`, `alpn`, `fp`, `insecure` объявлены
блоками `transports#uri` / `tls#uri` как `query.*`, `sni` и `host` — ещё и
записью `sni` формы v2rayn (`json.sni`, `json.host`). Дефект в
`_Run._reportUnknown` (`app/lib/services/parser/engine/interpreter.dart`).
Форма-контейнер раскладывается дважды: объектом (`space.json`) и плоским
слоем имён (`space.query`, `_flattenContainer`). Метод судил каждый скалярный
ключ обеими ветками по разным правилам:

- плоская ветка сверяла ключ с ОБЪЯВЛЕННЫМИ именами (`_declared`,
  `_declaredJson`, метка, `ignore`) — объявленные молчали, `cs` получал
  первый `uri_param_unknown`;
- объектная ветка сверяла ключ с ПРОЧИТАННЫМИ (`_consumed`). Запись,
  не применившаяся по `when` (`sni` при tls off, `path` при tcp) или с пустым
  значением, ключ не читала — и `host`/`path`/`sni`/`alpn`/`fp`/`insecure`/`cs`
  получали второй `uri_param_unknown`; при `action: keep` ключ уезжал в тело,
  а гейт тела давал третий код — `unknown_key`.

Пустое значение ключа контейнера не отличалось от заполненного ни в одной
ветке.

## Решение

`_reportUnknown` (только форма-контейнер: `space.json != null` и непустая
схема; объектный вход Xray/sing-box и строка запроса не затронуты):

1. Плоская ветка пропускает ключи контейнера с пустым значением.
2. Объектная ветка пропускает ключи, которые есть в плоском слое: их судит
   плоская ветка по объявленности, приговор один. Объектной ветке остаются
   вложенные объекты/списки.
3. `null` у ключа контейнера = ключа нет (в плоский слой он не попадает).

Следствие: необъявленный скалярный ключ контейнера (`"zzz":"1"`, непустой
`cs`) даёт ровно один `uri_param_unknown` и в тело больше не кладётся, как и
незнакомый параметр строки запроса. Контракт не менялся.

## Проверка

- `app/test/parser/task_598_vmess_empty_fields_test.dart` (новый): оба узла
  `73-github-full` — ноль `uri_param_unknown`/`unknown_key`, эмит прежний;
  `null`-ключи молчат; непустые `sni`/`path`/`host`/`alpn`/`fp`/`insecure` при
  tcp без TLS молчат и в тело не едут; непустой `cs` и `"zzz":"1"` — ровно
  одно `uri_param_unknown`. До правки на узле было 15 предупреждений.
- Прогнаны зелёными: `test/parser/task_514_contract_11152_test.dart`,
  `engine_primitives_test.dart`, `mapper_sections_w4_test.dart`,
  `vmess_pipeline_invariants_test.dart`, `vmess_security_test.dart`,
  `test/contract/parse_warnings_test.dart`, `node_edit_corpus_test.dart`,
  `contract_test.dart`, `body_contract_test.dart`,
  `test/screens/node_notifications_test.dart`,
  `test/models/body_delta_carry_test.dart`.
- `flutter analyze` — чисто.
- `expected.json` публичного корпуса (`73-github-full`) не обновлялся —
  отдельный коммит оркестратора.
