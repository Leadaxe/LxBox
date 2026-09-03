# 410 — XHTTP: пустое значение в `extra` не перекрывает плоский параметр

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-03 |
| Дата завершения | 2026-09-03 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [tasks/399](399-xhttp-fields-lost-in-json-branches.md), [SPEC 103 корпус](../../../app/contract/corpus/README.md), [tasks/217](217-xhttp-normalize-invalid-params.md) |

Регрессия v2.21.0, 4PDA #1740…#1765 (HubbyBubby, ark.sergo, cumirum,
rammsteinz, gridan): сервис не стартует, если в подписке есть хоть один
XHTTP-узел определённой формы. Откат на v2.20.12 «лечит».

## Симптом

```
Failed to start service: start or reload service: initialize outbound[487]:
create client transport: xhttp: v2ray-xhttp:
uplink_data_placement can be header only in packet-up mode
```

Ссылка узла (cumirum #1755, сокращено) несёт **оба** слоя Xray-формы:

```
vless://…?type=xhttp&mode=packet-up&host=media.morphai.cc&path=/hls/…
  &extra={"host":"","path":"/","mode":"","uplinkDataPlacement":"header",
          "uplinkHTTPMethod":"GET","sessionIDPlacement":"cookie",…}
```

Плоский `mode=packet-up` и `"mode": ""` внутри `extra`.

## Причина

`mergeXhttpExtra` (§399) накладывал `extra` на плоские параметры без
разбора: любой скаляр, включая пустую строку, попадал в карту поверх плоского
значения. `mode` становился пустым, эмиттер ключ не писал, ядро брало дефолт
`auto`, и `normalizeMeta` (transport/v2rayxhttp/meta.go) отвергал
`header`-placement вне packet-up — fatal на весь конфиг.

Эталон Go (singbox-launcher `node_parser_transport.go`, `xhttpLookup`) читает
`extra` первым и **при пустом значении откатывается к плоскому параметру**.
Dart-порт этот откат потерял.

Почему v2.20.12 стартовала: там `extra` затирал `mode` точно так же (слияние
существует с §127, v2.18.2), но парсер ещё сбрасывал `uplink_data_placement`
на дефолт с жёлтой плашкой (§217, `placementRequiresPacketUp`) — узел
собирался неправильно, зато конфиг жил. SPEC 103 перевёл поле в passthrough
по эталону Go, и затёртый `mode` стал фатальным. Плашки исчезли по той же
причине: сбрасывать стало нечего.

Проверка ядра `uplink_data_placement … only in packet-up mode` существует с
`v1.14.0-lx.1`; гипотеза «ядро lx.27 против lx.28» неверна.

## Что стало

- `mergeXhttpExtra`: пустой скаляр из `extra` (и из вложенного `xmux`) карту
  не трогает — плоское значение остаётся. Непустое по-прежнему побеждает
  (Xray-приоритет, кейс корпуса `xhttp_v2_extra_wins_over_flat`).
- Узел cumirum собирается как `mode: packet-up` +
  `uplink_data_placement: header` + `uplink_http_method: GET` — то, что
  сервер и ждёт. Это лучше v2.20.12, где placement сбрасывался.
- **(2) `host`, `path`, `mode` читаются только из плоских параметров, значения
  из `extra` для этих трёх ключей отбрасываются.** Так делает сам Xray:
  `SplitHTTPConfig.Build()` (infra/conf/transport_method.go) при наличии
  `extra` берёт его за основу, но `Host`, `Path`, `Mode` перезаписывает
  полями внешнего объекта. Device-verified на эмуляторе: у узла cumirum с
  `path: "/"` (из `extra`) сервер отвечал `unexpected upload status: 404`;
  с плоским `/hls/v2/track/8e31c750/` 404 исчез (дальше сервер рвёт
  соединения — чужой узел, проверить нельзя).

  Здесь LxBox расходится с Go-эталоном лаунчера: `xhttpLookup` там читает
  `extra` первым и для этих ключей, то есть собирает тот же неверный `/`.
  Кейс корпуса `xhttp_v2_extra_wins_over_flat` (xPaddingBytes) остаётся в
  силе — Xray-приоритет `extra` для всех прочих полей не тронут.

## Тесты

`test/parser/xhttp_test.dart`, группа §399:
- пустые `mode`/`xPaddingBytes`/`host` в `extra` не перекрывают плоские;
- пустой член `extra.xmux` не перекрывает плоский `xmux`;
- ссылка #1755 дословно → `mode: packet-up`, placement `header`, GET, без
  предупреждений.

## Вне задачи

- **Страховка в ядре.** Один узел подписки с `header`-placement и режимом
  не packet-up по-прежнему роняет весь конфиг. Прецедент уже есть: для
  `uplink_http_method=GET` вне packet-up ядро откатывается на POST с варнингом
  (sing-box-lx c0bbb1c55). Та же деградация нужна для placement — предложение
  в ядро, здесь не делается.
- **Корпус контракта.** Два кейса на сторону лаунчера: «пустое в extra +
  плоский mode» (Go уже проходит) и «непустые host/path/mode в extra
  игнорируются». Сессия лаунчера приняла: решение **D-097**, патч контракта
  **0.12.7**, кейсы `vless/xhttp_extra_empty_mode_keeps_flat` и
  `vless/xhttp_extra_host_path_mode_ignored`. После публикации хеша —
  `tool/sync_contract.sh` и lock на 0.12.7.
- `sessionIDPlacement`/`sessionIDKey` из `extra` не читает ни одна сторона
  (контракт знает `session_placement`/`sessionPlacement`). Не регрессия;
  отдельный вопрос к контракту.
- Probe подписки строит один конфиг на все узлы; отказ ядра на одном узле
  валит весь прогон (жалоба HubbyBubby #1758 «пингуются и отключённые»).
  После фикса не воспроизводится; устойчивость probe к одному битому узлу —
  отдельная задача.
