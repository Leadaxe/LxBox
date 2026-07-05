# 242 — Stats: попап детализации памяти + tap-навигация чипов

## Проблема

На экране **Statistics → Stats** карточка сверху показывала 4 чипа
(Upload / Download / Connections / память). Две проблемы:

1. Подпись под цифрой памяти — `sing-box`, хотя цифра = RSS **всего процесса
   приложения**, а не ядра. Ядро sing-box работает в том же процессе
   (`BoxVpnService` без `android:process`), поэтому в RSS входят Flutter engine,
   Dart-хип, ART, графика и лишь потом Go-ядро. Подпись вводила в заблуждение.
2. Чипы были статичны — тап ничего не делал. Хотелось: Connections → вкладка
   Conns; иконка памяти → детализация по памяти.

## Решение

| Было | Стало |
|---|---|
| Подпись памяти `sing-box` | `LxBox` (это память всего приложения) |
| Connections-чип статичен | tap → вкладка Conns (`DefaultTabController.animateTo(1)`) |
| Иконка памяти статична | tap → bottom-sheet с разбивкой памяти |
| — | интерактивные чипы помечены `chevron_right` |

### Попап памяти (`memory_detail_sheet.dart`)

Bottom-sheet по образцу `traffic_event_detail_sheet` (grabber / header / группы
`label : value`, копирование по тапу). Секции:

- **Process** — RSS (из статуса ядра), Total PSS, Swap.
- **Breakdown** — категории `summary.*` из native `Debug.MemoryInfo`:
  native heap (несёт Go-память ядра), Java/Dalvik heap, graphics, code, stack,
  system, other.
- **Native heap** — прямые malloc-счётчики (allocated / reserved).
- **Core runtime** — goroutines, connections in/out (из CommandClient-статуса).

### Источник данных

Native-метод `getMemoryInfo` в `VpnPlugin.kt` → `Debug.getMemoryInfo` +
`getMemoryStat("summary.*")` (API 23, KB → ×1024) +
`getNativeHeapAllocatedSize/Size`. Прокинут через `BoxVpnClient.getMemoryInfo()
→ MemoryInfo?`. Goroutines/connections берутся из уже существующего
`CcStatus` (проброшены в `OverviewTab`).

## Ограничение (Go-inuse недоступен)

Цифры «inuse» Go-хипа (`HeapInuse+StackInuse+HeapIdle−HeapReleased` — то, что
отдаёт Clash API `/memory` и показывают некоторые панели) через CommandClient
**нет**: `StatusMessage` libbox экспортирует только RSS (проверено `javap` по
собранному `libbox.aar`), а Clash API в LxBox отключён. Ближайшая честная
замена в попапе — строка Native heap → Allocated (там Go-память ядра).
Отдельная строка Go-inuse потребует правки ядра (`memoryInuse` в `daemon.Status`
proto → libbox → Kotlin → Dart) + пересборки AAR — вынесено в TODO на релиз ядра.

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` — метод `getMemoryInfo`
- `app/lib/vpn/box_vpn_client/method_names.dart` — константа `getMemoryInfo`
- `app/lib/vpn/box_vpn_client.dart` — метод + модель `MemoryInfo`
- `app/lib/screens/stats_screen.dart` — проброс goroutines/connectionsIn/Out
- `app/lib/screens/stats_screen/overview_tab.dart` — tap-навигация чипов, подпись
- `app/lib/screens/stats_screen/memory_detail_sheet.dart` — попап (новый)
