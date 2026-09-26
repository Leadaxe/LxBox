# 573 — Xray `finalmask.tcp` fragment → `tls.fragment`; шум `tcpSettings` и `extra.mode`

| Поле | Значение |
|------|----------|
| Статус | Blocked — ждёт норму контракта (лаунчер) |
| Дата старта | 2026-09-27 |
| Дата завершения | — |
| Коммиты | — |
| Контракт | текущий 1.1.82 (`source_sha=99543beb`); норма ожидается следующей версией |
| Связанные spec'ы | [§488](488-xray-dialer-proxy-freedom-fragment.md) (та же фрагментация через `dialerProxy` → freedom), [§572](572-notifications-group-by-code.md), features/321 xray-json-parsing, features/480 registry-driven-mapper |

## Проблема

Xray задаёт фрагментацию TLS ClientHello двумя формами.

| Форма | Где записана | У нас |
|---|---|---|
| Старая | служебный outbound `freedom` с `settings.fragment`, узел ссылается на него через `streamSettings.sockopt.dialerProxy` | Работает с §488: узел получает `tls.fragment: true` |
| Новая | `streamSettings.finalmask.tcp[]`, элемент с `type: fragment` | **Не читается** |

Новая форма в теле узла:

```json
"streamSettings": {
  "finalmask": {
    "tcp": [
      { "type": "fragment",
        "settings": { "packets": "tlshello", "length": "20-40",
                      "delay": "3-10", "maxSplit": "3-6" } }
    ]
  }
}
```

Следствия:

1. Узел ходит без фрагментации, которую заложил провайдер.
2. Каждое поле даёт `json_field_unknown` — пять уведомлений на узел. Они
   выглядят как шум, хотя это сигнал: фрагментацию пытались включить.

Замер на устройстве 27.09.2026 (подписка из 19 узлов, Xray-JSON, LxBox 2.25.4):

| Путь | Узлов |
|---|---|
| `streamSettings.finalmask.tcp.0.*` (5 полей) | 14 |
| `streamSettings.tcpSettings` | 15 |
| `streamSettings.xhttpSettings.extra.mode` | 7 |

Два последних пути — шум другого рода: `tcpSettings` приходит пустым объектом
`{}`, `extra.mode` повторяет уже прочитанный `xhttpSettings.mode`.

## Диагностика

- `finalmask` — часть `streamSettings`, то есть транспортного слоя Xray. От
  протокола не зависит и встречается у любого outbound с `streamSettings`.
- В реестре `finalmask` читают только `hysteria` и `hysteria2`
  (`finalmask.udp.0`, salamander). У остальных xray-секций записей нет, а
  `unknown_key.nested_quiet` содержит один путь — `streamSettings.sockopt`.
- Старая форма записана в общем файле `registry/dialer.json` записью
  `fragment_via_dialer`: `when` требует `tls.enabled: true`, результат —
  `implies: {"tls.fragment": true}`, `maps_to: null`. Поле в модели узла и
  эмиссия `tls.fragment` в outbound уже есть.
- Реестр принадлежит лаунчеру. `app/assets/contract/registry/**` — зеркало,
  в этом репозитории не правится.

## Решение

Новая форма приводится к поведению §488. Нормы §488 переносятся без изменений:
предупреждение ставится только при реальной потере поведения; механика ядра
(`tls.fragment`) предпочтительнее переноса параметров Xray; кода вида
«фрагментация перенесена» нет.

### Часть A — норма контракта (лаунчер)

**A1. Чтение `finalmask.tcp`.** Запись рядом с `fragment_via_dialer`
(рабочее имя `fragment_via_finalmask`), действует во всех xray-секциях с
потоком TCP.

| Условие | Результат |
|---|---|
| В `streamSettings.finalmask.tcp[]` есть элемент с `type: fragment`, у узла `tls.enabled: true` | `tls.fragment: true` |
| То же, у узла TLS выключен | Флаг не ставится |
| То же, узел ходит через хоп (`dialerProxy` на прокси-узел) | Флаг не ставится: внутренний хоп DPI не видит |
| Элемент `finalmask.tcp[]` с другим `type` | Как сейчас: `json_field_unknown` по его полям |

- Значение `packets` на результат не влияет: флаг ставится при любом.
- `packets`, `length`, `delay`, `maxSplit` отбрасываются без кода.
- Поля элемента с `type: fragment` не дают `json_field_unknown` ни в одном из
  случаев таблицы, включая узел без TLS.
- `record_fragment` этой записью не включается.
- Если у узла есть и старая, и новая форма — результат тот же, флаг один.

**A2. Пустой `tcpSettings`.** `streamSettings.tcpSettings`, равный `{}`, не даёт
`json_field_unknown`. Непустой обрабатывается как сейчас.

**A3. Дубль `extra.mode`.** `streamSettings.xhttpSettings.extra.mode` не даёт
`json_field_unknown`, когда значение совпадает с прочитанным
`xhttpSettings.mode`. Случаи «основного `mode` нет» и «значения расходятся»
определяет лаунчер по поведению Xray и записывает в норму.

**A4. Кейсы корпуса** (`body/xray/`):

| Кейс | Ожидание |
|---|---|
| `finalmask_tcp_fragment` — vless + xhttp + reality | `tls.fragment: true`, предупреждений нет |
| `finalmask_tcp_fragment_no_tls` | флага нет, предупреждений нет |
| `finalmask_tcp_fragment_with_hop` | флага нет, цепочка как раньше |
| `finalmask_tcp_other_type` | `json_field_unknown` по полям элемента |
| `tcp_settings_empty` | предупреждений нет |
| `xhttp_extra_mode_duplicate` | предупреждений нет |

Расположение записей (общий файл или каждая xray-секция) — решение лаунчера.

### Часть B — LxBox

Выполняется после выхода нормы.

1. Синк контракта на коммит лаунчера с нормой: `app/tool/sync_contract.sh --to <sha>`,
   сверка `app/contract.lock`, обновление зеркал `app/assets/contract/` и
   `docs/contract/`.
2. Движок (`app/lib/services/parser/engine/interpreter.dart`): проверить, что
   он исполняет формы, которыми лаунчер записал A1–A3 (поиск элемента массива
   по `type`, условное заглушение пути). Дописывать только недостающее.
3. Тесты: `app/test/parser/json_parsers_test.dart` — кейсы по таблице A4 рядом
   с группой §488; фикстура `app/test/fixtures/xray/finalmask_tcp_fragment.json`.
   Тесты, читающие корпус, — под `corpusTestSkip`.
4. Документация: строка в `docs/GUARDS.md` (слой JSON-веток, рядом с записью
   про `finalmask.quicParams`), раздел Xray в `docs/PROTOCOLS.md`, ссылка на
   эту задачу в §488.

## Риски и edge cases

- **Параметры Xray не переносятся.** У ядра `tls.fragment` — флаг без размеров
  и задержек. Принято в §488.
- **Узел с REALITY и uTLS.** Реестр фрагментацию разрешает, тест §488 проверяет
  попадание флага в конфиг. Замер на стенде не делается — решение владельца
  27.09.2026.
- **`finalmask.tcp` у QUIC-узлов** (hysteria, hysteria2) не применим; их записи
  `finalmask.udp` не затрагиваются.
- **Глобальная настройка фрагментации** остаётся: она включает флаг всем узлам
  без `detour`, правило этой задачи — только узлу, который её запросил.

## Верификация

- Кейсы корпуса A4 зелёные на обеих сторонах.
- Регрессия §488: кейс `dialer_proxy_freedom_fragment` без изменений.
- Приёмка на устройстве: у узла «Германия» той же подписки во вкладке JSON
  есть `tls.fragment: true`; в Diagnostics нет записей про `finalmask.tcp.*`,
  `tcpSettings`, `extra.mode`.

## Нерешённое / follow-up

Нет.
