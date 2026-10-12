# §620 — XHTTP: `?query` в `path` уходит дословно, не срезается

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | Implemented — код LxBox, контракт 1.1.115 (синк `4c995c41`), ядро `v1.14.3-lx.14`; ждёт полевой проверки |
| Фича | [016-DPI_HARDENING](../features/016-DPI_HARDENING/FEATURE.ru.md), функция [xhttp-params](../features/016-DPI_HARDENING/FUNCTIONS/xhttp-params.ru.md) |
| Дата | 2026-10-09 |
| Связанные | заявка [Leadaxe/sing-box-lx#36](https://github.com/Leadaxe/sing-box-lx/issues/36); ядро sing-box-lx SPEC 119 `XHTTP_PATH_QUERY` (коммит `f2b121796`); §127F (прежнее правило среза), §303 (early data ws), §399 (общий `xhttpFromMap`) |

## Проблема

Узел VLESS+XHTTP за релеем Cloudflare Worker (edgetunnel) несёт
`path=/?proxyip=149.56.109.62`. Worker читает `proxyip` из query запроса;
без него он не открывает сокеты к адресам самого Cloudflare, и сайты за
Cloudflare отвечают 502 через 20–60 с.

Контракт Xray (`transport/internet/splithttp/config.go`,
`GetNormalizedPath`/`GetNormalizedQuery`): всё после первого `?` в `path` —
query запроса, байт в байт. Ядро sing-box-lx с SPEC 119 делает так же.
LxBox срезал хвост раньше, на разборе: в конфиг уходил `path: "/"`, и до
ядра `proxyip` не доходил ни с одного входа.

## Где срезалось

Разбор идёт двумя слоями, и хвост снимал каждый:

| Слой | Входы | Чем срезалось |
|------|-------|---------------|
| Реестр контракта, записи `blocks.uri.xhttp.path` и `blocks.xray.xhttp.path` (`transports.json`) | ссылка, Xray-JSON | `extract.re = ^(?P<path>[^?]*)` |
| `xhttpFromMap` (`app/lib/services/parser/transport.dart`) | все три: ссылку и Xray-JSON движок приводит к sing-box-карте, и она идёт через `parseSingboxEntry` → `_transportFromSingbox` → `xhttpFromMap`; sing-box JSON — напрямую | `splitEarlyDataPath` |

`parseTransport` (рукописный разбор query) в `lib` больше не вызывается —
только из тестов; ссылку разбирает движок по реестру.

Хвост `?ed=N` — соглашение early data у ws (§303). У xhttp early data нет,
поэтому и `?ed=2048` по контракту Xray — query запроса.

## Решение

- `xhttpFromMap`: `path` берётся дословно, с `?…`. Правила, не связанные
  с хвостом, те же: нет ключа `path` → путь не задан (не эмитится);
  явный пустой `path=` → `/`. `decodeResidualPercent` у xhttp на стороне
  LxBox не применялся и не применяется — остаточное декодирование ссылки
  делает реестр (`decode_extra`, 2 прохода).
- `splitEarlyDataPath` остаётся за ws и httpupgrade; её комментарий больше
  не говорит «для всех транспортов».
- Реестр — правка в контракте лаунчера (`blocks.uri.xhttp.path`,
  `blocks.xray.xhttp.path`: снять срез хвоста). В LxBox его копии
  (`app/assets/contract/`, `app/contract/`) не правятся — они приходят
  синком (`app/tool/sync_contract.sh`).
- Экспорт ссылки уже корректен: движок кодирует значение параметра,
  `/?a=1&b=2` уходит как `path=%2F%3Fa%3D1%26b%3D2`. Тестом закреплено.

## Риски и края

- **Ядро без SPEC 119.** SPEC 119 есть с `v1.14.3-lx.14` (пин LxBox с
  того же дня); в `v1.14.2-lx.13-rc.1` и раньше его нет. Старое ядро кладёт
  весь `path` в путь и кодирует `?`: `/x?ed=2048` превращается в
  `/x%3Fed=2048/…`, и обычный Xray-сервер, который раньше получал `/x`,
  отвечает 404. После синка контракта (ссылка, Xray-JSON) так сломаются
  xhttp-узлы с любым `?`-хвостом. Выпускать вместе с ядром, где есть
  SPEC 119, не раньше.
- **Дедуп.** Подпись дедупа — эмиссия узла, `transport.path` в неё входит.
  Узлы одного сервера, различные только query пути (варианты релея с разными
  `proxyip`), больше не схлопываются в один. Это и есть исправление.
- **Идентичность.** Идентичность узла подписки = сырой тег провайдера
  (`node_hash.dart`), путь в неё не входит — отметки выключения не
  теряются. Контент-хеш (`legacyNodeIdentityHash`, отпечаток состава) у
  узлов с хвостом сменится — один раз пометит конфиг изменившимся.
- **Коды.** `_guardUrlPath` (`type_invalid`) на xhttp не вызывается;
  `urlPathOk` смотрит только `%`-последовательности, `?`, `=`, `&` его не
  задевают. Узел `/?proxyip=…` проходит без кодов (тест).
- ws/httpupgrade не менялись: `?ed=N` по-прежнему срезается и раскладывается.

## Проверка

- `test/parser/xhttp_path_query_test.dart` (новый):
  - карта ссылки `path=%2F%3Fproxyip%3D149.56.109.62` → `/?proxyip=149.56.109.62`,
    без кодов; `/base?x=1&y=2` — дословно; путь без `?` не меняется;
    нет ключа → `''`, пустой → `/`;
  - карта Xray-JSON (`xhttpScalarsFromJson`) — дословно;
  - sing-box JSON сквозь `parseSingboxConfigs` до тела — дословно; два
    узла, различные только `proxyip`, оба выживают дедуп;
  - экспорт: `?` и `&` кодируются внутри `path=`;
  - регрессия ws: `?ed=2048` срезан и стал `max_early_data`, в т. ч. через
    `parseUri`; httpupgrade — чужой query срезан;
  - сквозные ссылка / Xray-JSON / круг `parseUri(toUri)` — через реестр.
    До синка стояли под гейтом (зеркало срезало хвост); после синка
    контракта 1.1.115 гейт удалён, чтобы откат реестра ронял тесты, а не
    пропускал их. 15/15 зелёные.
- `test/parser/xhttp_test.dart`: тест «path с ?-хвостом обрезается»
  перевёрнут — хвост остаётся.

## Не закрыто

- [x] Синк контракта 1.1.115 (`singbox-launcher` `4c995c41`): записи
  `blocks.uri|xray.xhttp.path` берут путь дословно; кейсы корпуса
  переименованы в `xhttp_path_ed_tail_kept` / `xhttp_path_query_tail_kept`,
  добавлены `uri/vless/xhttp_path_proxyip_query_kept` и
  `body/xray/xhttp_path_query_kept`. В снимках `test/fixtures/vless/`
  ключи кейсов переименованы; в `pipeline_identity_before.json` пересняты
  хеши двух узлов с `?ed=2048` (ожидаемо: хвост вошёл в тело), остальные
  не сдвинулись. `emit_before480.json` — снимок удалённого рукописного
  эмита, переснять его нечем: переименованы только ключи. Гейт в
  `xhttp_path_query_test.dart` удалён.
- [x] Пин ядра — `v1.14.3-lx.14` (первый релиз sing-box-lx с SPEC 119).
- [ ] Полевая проверка: узел из #36 открывает сайты за Cloudflare.

## Документация

- [`xhttp-params`](../features/016-DPI_HARDENING/FUNCTIONS/xhttp-params.ru.md) (+ EN):
  правило `path`, ревизия §620.
- `CHANGELOG.md` → `Unreleased`.
- `docs/ARCHITECTURE.md` — не требуется.
