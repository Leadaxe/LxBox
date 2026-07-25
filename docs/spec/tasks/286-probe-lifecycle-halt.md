# §286 — Детерминированная остановка пробирования (URLTest) на stop/pause + батчинг UI

**Тип:** bug + UX · **Статус:** complete (коммиты `18a1111` fix + `ff25cdd` test, develop)

> **Поправка §307 (25.07.2026).** Исходное решение гасило на сворачивании **всё**
> пробирование, включая mass-ping. С форума (жалоба на v2.16.0): «процесс пинга
> останавливается, если просто свернуть окно» — запустить пинг списка и уйти в
> другое приложение оказалось штатным сценарием, а автоперезапуска на resume нет,
> так что пользователь возвращался к частичным результатам. Рычаг разделён:
> сворачивание гасит folder-probe + auto-ping-таймер, mass-ping доживает прогон.
> Детали — в разделе 2 ниже.

## Проблема

После снятия guard'а AWG-over-WireGuard (§130 / kernel SPEC 007, ядро lx.11) на
устройстве всплыл симптом «UI завис на остановке ядра»: при остановке VPN /
сворачивании приложения интерфейс подмерзал, а в logcat шёл флуд
`ccUrlTestOutbound` (сотни вызовов) — «молотит после остановки».

## Корень (по логам устройства + карте кода)

Флуд — **не** от mass-ping (`runMassUrltest`): тот защищён epoch +
`tunnelUp`-гейтом и явно отменяется на disconnect/revoked
(`home_controller.dart:323`) и на смерти туннеля (`heartbeat.dart:106`).

Настоящий источник — **проба папки** `FolderProbeRunner` (§236/§284, папка
«WARP GENERATOR» ~100 нод, `enabled:true`). При «Test» на живом VPN runner
пробует headless `probeStart`, получает «VPN is running» и **падает на боевое
ядро**, гоня `ccUrlTestOutbound` по всем членам пачками по 6
(`probe_runner.dart:79→113`). Отменяется этот sweep **только** флагом
`_cancelled`, который дёргает экран деталей папки
(`folder_detail_screen.dart:190/217`). **Ни stop VPN, ни сворачивание, ни смерть
туннеля его не трогают** → sweep продолжается после стопа.

Три дыры, вскрытые инцидентом:

- **A. `FolderProbeRunner` не привязан к lifecycle** — единственный источник
  этого флуда; отменяется лишь экраном папки.
- **B. `onAppPaused` не отменяет пробирование** (`home_controller.dart:1130`):
  гасит только status+screen CC-клиенты, оставляя pingClient, mass-ping и
  auto-ping-таймер живыми. Sweep переживает сворачивание.
- **C. Нет батчинга UI:** mass-ping-воркер и folder-probe шлют `_emit` /
  `setState` **на каждую ноду** → ~150 полных ребилдов пачкой (с deep-copy
  растущих map). Джанк на **любом** большом sweep, не только при стопе.
  (Нативные `ccUrlTestOutbound` — на `Dispatchers.IO`, fast-fail при disconnect;
  UI-фриз — от Dart-ребилдов, не от платформенных вызовов.)

## Решение

Единая точка отмены пробирования + батчинг.

### 1. `ProbeLifecycle` — реестр отменяемого пробирования

Новый синглтон `app/lib/services/probe/probe_lifecycle.dart`. Любой
`FolderProbeRunner` регистрирует свой `cancel` на старте `run()` и снимает в
`finally`. `haltAll()` дёргает все зарегистрированные `cancel` — независимо от
того, кто владеет runner'ом (экран папки, debug-handler `folders.dart:413`).

```
ProbeLifecycle.I.register(cancel) / .deregister(cancel) / .haltAll()
```

### 2. Два рычага остановки (§307 — было один)

**`haltAllProbing()`** — «сессия мертва», гасит ВСЁ:
- `cancelMassPing()` (epoch-bump + `_cc.cancelPing()` — уже есть),
- `_autoPingTimer?.cancel(); _autoPingTimer = null;`,
- `ProbeLifecycle.I.haltAll()` (folder-probe).

Зовётся из переходов, после которых пробировать физически некуда:
- `_handleStatusEvent` disconnected/revoked (заменяет текущие
  `cancelMassPing()` + timer-cancel, `home_controller.dart:323-325`);
- `_onTunnelDead` (heartbeat, `heartbeat.dart:106-108`).

**`haltBackgroundProbing()`** — сворачивание приложения (`onAppPaused`, дыра B).
Гасит только то, что в фоне бессмысленно или вредно:
- `_autoPingTimer` — отложенный выстрел по невидимому UI;
- `ProbeLifecycle.I.haltAll()` — длинные folder-probe sweep'ы (100+ нод по
  живому ядру), ради которых §286 и заводился.

**mass-ping в фоне НЕ трогаем** (§307). Он короткий, epoch/tunnelUp-гейты его и
так защищают, а `_cc.cancelPing()` рвёт in-flight urltest'ы в ядре (§175) —
сворачивание посреди прогона списка давало частичные результаты на resume.
Сессию mass-ping всё равно закрывает `haltAllProbing` через stop/tunnel-dead.

Итог-инвариант: **stop VPN ∪ tunnel-dead ⇒ всё пробирование остановлено
детерминированно** (не зависит от тайминга flip'а `tunnelUp`); **app-background
⇒ остановлены folder-probe и auto-ping-таймер, mass-ping доживает прогон**.

### 3. Батчинг per-node emit

- **mass-ping** (`ping_orchestration.dart` worker): копим результаты в рабочие
  map, флашим периодически (~120 мс) + финальный флаш; epoch/tunnelUp-гейты
  сохраняются. ~150 ребилдов → единицы.
- **folder-probe** (`folder_detail_screen.dart` `onResult`): та же коалесценция
  для per-member `setState`.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/services/probe/probe_lifecycle.dart` | НОВЫЙ — реестр + `haltAll()` |
| `app/lib/services/probe/probe_runner.dart` | register/deregister `cancel` в `run()` |
| `app/lib/controllers/home_controller.dart` | `haltAllProbing()` в disconnected/revoked; `haltBackgroundProbing()` в `onAppPaused` (§307) |
| `app/lib/controllers/home_controller/heartbeat.dart` | `_onTunnelDead` → `haltAllProbing()` |
| `app/lib/controllers/home_controller/ping_orchestration.dart` | батч-флаш mass-ping; оба рычага остановки (§307) |
| `app/lib/screens/folder_detail_screen.dart` | батч-флаш `onResult` |
| `app/test/...` | §250-мост: massPingRunning==false после disconnect/revoked; НЕ сброшен после pause (§307); ProbeLifecycle unit |

## Вне скоупа (нота владельцу §284)

Страховка «создавать WARP GENERATOR `enabled:false` / меньший seed» — дизайн-выбор
фичи §284, не трогаю. Основной фикс (lifecycle-отмена + батчинг) решает проблему
и без неё.

## Приёмка

- Stop VPN во время sweep папки → `ccUrlTestOutbound` прекращается в пределах
  одного in-flight вызова (не проходит весь список).
- Сворачивание приложения во время sweep папки → то же (проба отменена, не
  переживает фон).
- Смерть туннеля → то же.
- **§307:** запустить mass-ping списка → свернуть окно на ~30с → вернуться:
  прогон продолжался в фоне, результаты полные (кнопка пинга всё время в
  состоянии «идёт»/Stop, а не сброшена).
- **§307:** свернуть окно во время mass-ping → Stop VPN из шторки → прогон
  остановлен (`haltAllProbing` через disconnected).
- Большой sweep (100+ нод) не даёт бёрста ~150 ребилдов — UI отзывчив.
- Существующие инварианты (§175 pingClient lazy lifecycle, §141 auto-ping,
  §122 CC-стримы) не регрессируют.
- `flutter analyze` + затронутые тесты зелёные.
