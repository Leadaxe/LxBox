# 153 — Connections: подсветка однобоких (зависших) TCP-соединений

| Field | Value |
|------|----------|
| Status | Done |
| Started | 2026-06-21 |
| Trigger | Сигнатура зависшего потока (напр. WhatsApp `↑517 ↓0` — TLS ClientHello ушёл, ответа нет; либо `↑0 ↓xxx`). В списке Stats→Conns такие соединения визуально неотличимы от здоровых. Нужно подсвечивать их розовым, чтобы сразу видеть проблемные. |
| Related | [connections_screen.dart](../../../app/lib/screens/connections_screen.dart) (`_buildTile` — рендер тайла); [connection_detail_sheet.dart](../../../app/lib/screens/connections_screen/connection_detail_sheet.dart) (§152 detail sheet); [[152-conn-detail-sheet]] |
| Files touched | `app/lib/screens/connections_screen.dart`, `app/lib/screens/connections_screen/connection_detail_sheet.dart`, `app/test/services/connections_oneway_test.dart` (new), `app/test/fixtures/clash_api/connections_oneway_live.json` (new) |

## Что сделано

### 1. Детекция «однобокого» соединения (`isOneWayStuck`)

Чистая top-level функция в [connections_screen.dart](../../../app/lib/screens/connections_screen.dart)
(без BuildContext, `now` инъектируется для тестов):

```dart
bool isOneWayStuck({network, upload, download, startTime, closed, now}) {
  if (closed) return false;
  if (network != 'tcp') return false;
  if (startTime == null) return false;
  if ((now ?? DateTime.now()).difference(startTime) < oneWayMinAge) return false;
  return (upload > 0 && download == 0) || (upload == 0 && download > 0);
}
```

- **TCP only** — для UDP однобокость нормальна (DNS, медиа, QUIC-пробы).
- **возраст ≥ 3с** — отсекает свежие conns в процессе handshake (иначе
  каждый новый conn мигал бы розовым). Используется уже вычисленный
  `duration` (от `start`).
- **перекос трафика** — трафик строго в одну сторону.
- `!closed` — закрытые не маркируем (у них своя 0.45-opacity).

### 2. Розовый фон тайла

Тайл обёрнут в `Container(color: …)`. Розовый = `Color.alphaBlend(
Colors.pink @ 0.16, cs.surface)` — приглушённый, читаемый в light/dark,
не перебивает текст. Оборачивает существующий `Opacity` (closed-логика
не затронута).

### 3. Badge + плашка в detail sheet

`showConnectionDetailSheet(..., oneWay: oneWay)` прокидывает флаг. В sheet:

- **badge «One-way»** в заголовке (рядом с `closed`), розовый.
- **плашка-пояснение** первым элементом списка: иконка ⚠ + текст с учётом
  направления перекоса:
  - `↑>0 ↓0` → «Данные ушли (↑), ответа нет (↓0) — поток, похоже, завис.»
  - `↑0 ↓>0` → «Данные приходят (↓), исходящих нет (↑0) — поток, похоже, завис.»

## Почему так, а не иначе

- **Порог 3с + TCP-only** — без них правило `download==0` красит здоровые
  свежие/однонаправленные соединения (keep-alive, маяки, DNS-over-TCP),
  сигнал тонет. Порог согласован с юзером.
- **Фон, не цвет текста** — видно при скролле, текст остаётся читаемым.
- **Фон под `Opacity`/`InkWell`** — closed-dimming и tap-to-sheet (§152)
  работают поверх, не конфликтуют.
- Чисто клиентская эвристика по Clash-снимку — НЕ диагноз корня (см.
  обсуждение зависаний WhatsApp: вероятно TCP coalescing/GRO split-brain
  по аналогии с §010, либо залип forwarding в gVisor-стеке). Подсветка —
  только индикатор для юзера/диагностики, ядро не трогает.

## Проверка на живых данных

Снято с устройства по Debug API (`/clash/connections`), пока WhatsApp
держал залип. В снимке из 15 соединений эвристика подсветила **ровно 1**:

```
tcp ec2-54-179-142-217.ap-southeast-1...  up=517 dn=0  age=64s  >>> PINK
```

Ноль ложных срабатываний: `129.227.192.8 up=763 dn=4` (dn≠0) и
двусторонние (`mtalk.google.com 1055/6934`) корректно пропущены. Снимок
сохранён фикстурой `connections_oneway_live.json`, прогон закреплён тестом
([connections_oneway_test.dart](../../../app/test/services/connections_oneway_test.dart),
10 кейсов, все green).

## Acceptance

- [x] TCP-соединение возрастом ≥3с с трафиком в одну сторону → розовый фон.
- [x] Свежие (<3с) и UDP-соединения не подсвечиваются.
- [x] Закрытые соединения не маркируются как one-way.
- [x] В detail sheet — badge «One-way» + плашка с пояснением по направлению.
- [x] §152 (detail sheet, close, copy) и closed-opacity не затронуты.
- [x] Логика — чистая `isOneWayStuck`, покрыта юнит-тестом + живой фикстурой.
- [x] Проверено на устройстве: реальный WhatsApp ↑517 ↓0 подсвечен, остальные нет.
