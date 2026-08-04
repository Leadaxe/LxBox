# §373 — `ACTION_RELOAD` в `onReceive` держит main-поток → ANR

| | |
|---|---|
| Тип | bugfix (ANR, «Приложение не отвечает») |
| Статус | 🔧 Исправлено — DEVICE-PENDING |
| Дата | 2026-08-04 |
| Связанные | [`122 commandclient-migration`](../features/122%20commandclient-migration/spec.md) (инвариант: unary-RPC на main = ANR), [`361`](361-late-started-status-after-service-destroy.md) (тот же блокирующий `startOrReloadService`, другой симптом), [`263`](../features/) (`ACTION_CLEAR_DNS_CACHE` — второй пострадавший обработчик), [`182`](182-notification-action-buttons.md) (образец ухода с main через отдельный scope) |

## Симптом

Диалог «Приложение "L×Box" не отвечает» с работающим туннелем. Приходит от
юзера с большой подпиской; на типовых конфигах не воспроизводится.

`exit_info` из диагностического дампа (2026-08-04, Redmi sweet, Android 13):

```
reason: ANR
description: Input dispatching timed out (... MainActivity is not responding.
             Waited 5002ms for MotionEvent)
RssKb: 573192   RssHwmKb: 585436
```

Трейс главного потока — однозначный:

```
"main" prio=5 tid=1 Native
  at io.nekohasekai.libbox.CommandServer.startOrReloadService(Native method)
  at e0.B.serviceReload(SourceFile:76)
  at e0.s.onReceive(SourceFile:222)
  at android.app.LoadedApk$ReceiverDispatcher$Args.lambda$getRunnable$0
  ...
  at android.os.Looper.loop(Looper.java:367)
```

В Debug Store того же дампа виден источник: `act=com.leadaxe.lxbox.ACTION_RELOAD`.

## Root cause

`BroadcastReceiver.onReceive` Android всегда исполняет **на main-потоке**.
Обработчик `ACTION_RELOAD` в `BoxService.receiver` звал `serviceReload()`
синхронно, прямо в теле `onReceive`:

```kotlin
BoxVpnService.ACTION_RELOAD -> {
    runCatching { serviceReload() }        // ← main-поток
        .onFailure { ... }
}
```

`serviceReload()` внутри делает `cs.startOrReloadService(config, …)` — блокирующий
JNI-вызов, который закрывает старый box-инстанс и целиком поднимает новый
(парсинг конфига, построение всех outbound'ов, DNS, роутинг). Всё это время main
не обрабатывает ни ввод, ни отрисовку. Порог ANR по вводу — 5 секунд.

`runCatching` здесь не помогает: он ловит исключение, но не меняет поток.

### Почему проявляется не у всех

Дефект безусловный, а проявление — пороговое: **ANR = время reload > 5 с**.
На типовом конфиге reload укладывается в доли секунды, и подморозка main
незаметна. В пострадавшем дампе совпали три множителя:

| Фактор | Значение в дампе | Вклад |
|---|---|---|
| `config.outbounds` | 706 | reload пересобирает все, синхронно |
| `Detour removed: … referenced missing "🔥☁️ WARP"` | сотни подряд | резолв + откот detour'а + лог на каждый узел |
| RSS / HWM | 573 МБ / 585 МБ | GC-паузы поверх долгого вызова |

Плюс у юзера включён `auto_reload_on_change` — reload'ы прилетают автоматически
при изменениях, а не только по явному нажатию, то есть попыток пробить порог
кратно больше.

Вывод для будущих правок: ускорение reload проблему не закрывает — при мёртвой
ноде или подписке ещё большего размера вызов снова уползёт за 5 с. Лечится
только уходом с main.

## Что меняем

`BoxService.kt`, тело `receiver.onReceive` — два обработчика, которые доходят до
`startOrReloadService`:

- `ACTION_RELOAD` → `serviceReload()`;
- `ACTION_CLEAR_DNS_CACHE` (§263) → `deleteCacheDbFile()` + `serviceReload()`;

и третий, который делает unary-RPC в ядро:

- `ACTION_RESET_NETWORK` → `cs.resetNetwork()`.

Все три уходят в `serviceScope` (`Dispatchers.IO`) через `goAsync()`, чтобы
Android не считал broadcast обработанным до завершения работы и не понижал
приоритет процесса на время reload'а.

### Что НЕ трогаем

`override fun serviceReload()` остаётся синхронным. Это метод
`CommandServerHandler` — его вызывает **само ядро** уже с фонового Go-потока, и
там блокировка легальна. Уводить надо только ресиверный путь. По §122 менять
сигнатуру JNI-callback'а нельзя: он обязан оставаться no-throw и не должен
возвращать управление раньше, чем ядро отработает.

`ACTION_STOP` / `ACTION_FORCE_STOP` не трогаем: `doStop`/`doForceStop` уже сами
уводят teardown в `serviceScope`/`forceStopScope`.

## Верификация

1. Подписка на несколько сотен узлов с оборванным detour (ссылка на
   несуществующий узел) — воспроизводит исходные условия.
2. Включить `auto_reload_on_change`, изменить конфиг при работающем туннеле.
3. До фикса: ANR-диалог, в `exit_info` трейс с `startOrReloadService` в main.
4. После фикса: UI отзывчив во время reload'а, туннель дропается и поднимается
   как обычно (~3 с), ANR-записей в `exit_info` нет.
