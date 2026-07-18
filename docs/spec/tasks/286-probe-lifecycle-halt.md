# §286 — Детерминированная остановка пробирования (URLTest) на stop/pause + батчинг UI

**Тип:** bug + UX · **Статус:** complete (коммиты `18a1111` fix + `ff25cdd` test, develop)

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

### 2. `HomeController.haltAllProbing(reason)`

Один метод, гасящий ВСЁ пробирование:
- `cancelMassPing()` (epoch-bump + `_cc.cancelPing()` — уже есть),
- `_autoPingTimer?.cancel(); _autoPingTimer = null;`,
- `ProbeLifecycle.I.haltAll()` (folder-probe).

Зовётся из **всех** «активность пора гасить» переходов:
- `_handleStatusEvent` disconnected/revoked (заменяет текущие
  `cancelMassPing()` + timer-cancel, `home_controller.dart:323-325`);
- `_onTunnelDead` (heartbeat, `heartbeat.dart:106-108`);
- **`onAppPaused`** (НОВОЕ — дыра B; сворачивание отменяет пробы по решению
  юзера «при сворачивании отменить»).

Итог-инвариант: **stop VPN ∪ tunnel-dead ∪ app-background ⇒ всё пробирование
остановлено детерминированно** (не зависит от тайминга flip'а `tunnelUp`).

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
| `app/lib/controllers/home_controller.dart` | `haltAllProbing()`; вызов в disconnected/revoked + `onAppPaused` |
| `app/lib/controllers/home_controller/heartbeat.dart` | `_onTunnelDead` → `haltAllProbing()` |
| `app/lib/controllers/home_controller/ping_orchestration.dart` | батч-флаш mass-ping |
| `app/lib/screens/folder_detail_screen.dart` | батч-флаш `onResult` |
| `app/test/...` | §250-мост: massPingRunning==false после disconnect/revoked/pause; ProbeLifecycle unit |

## Вне скоупа (нота владельцу §284)

Страховка «создавать WARP GENERATOR `enabled:false` / меньший seed» — дизайн-выбор
фичи §284, не трогаю. Основной фикс (lifecycle-отмена + батчинг) решает проблему
и без неё.

## Приёмка

- Stop VPN во время sweep папки → `ccUrlTestOutbound` прекращается в пределах
  одного in-flight вызова (не проходит весь список).
- Сворачивание приложения во время sweep → то же (проба отменена, не переживает
  фон).
- Смерть туннеля → то же.
- Большой sweep (100+ нод) не даёт бёрста ~150 ребилдов — UI отзывчив.
- Существующие инварианты (§175 pingClient lazy lifecycle, §141 auto-ping,
  §122 CC-стримы) не регрессируют.
- `flutter analyze` + затронутые тесты зелёные.
