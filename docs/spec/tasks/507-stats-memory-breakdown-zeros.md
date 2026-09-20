# 507 — Stats → Memory: Breakdown сплошные нули

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-09-20 |
| Повод | Приёмка v2.25.0: после перехода с 2.24 шторка Statistics → Stats → Memory показывает RSS, Allocated/Reserved и goroutines, а секция Breakdown — все `0 B` |
| Связанные | [§242](242-stats-memory-detail-popup.md) |

## Docs to update

- эта задача
- [§242](242-stats-memory-detail-popup.md) — источник данных: AMS, не `Debug.getMemoryInfo`
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Fixed

## Проблема

Шторка памяти (тап по чипу LxBox на Stats) рисует:

| Секция | На скрине |
|---|---|
| Process / RSS | 407.4 MB — из CommandClient `StatusMessage.getMemory()` |
| Breakdown (Native/Java/Graphics/Code/Stack/System/Other) | все `0 B` |
| Native heap Allocated / Reserved | 51.4 / 69.8 MB — `Debug.getNativeHeapAllocatedSize/Size` |
| Core runtime | goroutines / connections живые |

Total PSS в шапке Process скрыт (`totalPss > 0`) — тоже ноль. Карта native-метода `getMemoryInfo` доезжает: иначе Allocated не было бы. Нулями приходят только категории `summary.*`.

Код §242 не менялся между v2.24.4 и v2.25.0. Сломался не Dart и не ядро: на новых Android `Debug.getMemoryInfo()` больше не заполняет `otherStats`, из которых `getMemoryStat("summary.java-heap")` и соседи считают PSS. Документация `Debug.getMemoryInfo` прямо говорит: protected-аллокации (в том числе graphics) этому вызову не видны, полный снимок — `ActivityManager.getProcessMemoryInfo`.

Malloc-счётчики и RSS живут другими API, поэтому «половина шторки живая» — ожидаемая картина, не порча канала.

## Решение

`VpnPlugin.getMemoryInfo` берёт `MemoryInfo` у AMS по pid процесса (UI и VPN в одном процессе). Если AMS вернул пусто (rate-limit Android Q+, эмулятор без memtrack) — падаем на прежний `Debug.getMemoryInfo`. Для каждой `summary.*`-категории, если она ноль, подставляем грубое поле той же структуры (`totalPss` / `dalvikPss` / `nativePss` / `otherPss`). Swap — только `summary.total-swap`: `getTotalSwappedOut{,Pss}` скрыты в SDK.

Сбор на `Dispatchers.IO`: обход smaps на RSS ~400 MB занимает сотни мс, на main это ANR. Контракт карты для Dart не меняется — те же ключи, байты.

## Риски

- AMS на Q+ троттлит частые вызовы и отдаёт предыдущий снимок. Шторка открывается по тапу, не в тике — достаточно.
- Graphics/code/stack на эмуляторе без memtrack HAL могут остаться нулями даже у AMS. Java/native/total PSS при этом должны заполниться.
- Грубые fallback-поля шире одноимённых `summary.*` (dalvikPss ⊃ private Java heap). Это запасной путь, когда summary пуст, не замена нормы.

## Верификация

- `flutter analyze` — без новых issues.
- `flutter test test/vpn/box_vpn_client_test.dart` — контракт `getMemoryInfo` + разбор карты.
- Device: Stats → чип LxBox → Breakdown не все нули при RSS > 0. На эмуляторе `LxBox_test` и на телефоне, где снят скрин.
