# §131 — Impeller crash на старых GPU (Adreno 3xx, Android 10)

| Поле | Значение |
|------|----------|
| Статус | **Verified (тест-устройство)** — ждёт подтверждения на реальном Adreno 3xx |
| Дата | 2026-06-16 |
| Тип | bug-fix (Flutter render / GPU compat) |
| Связано | [§128 JNI callback crash](128-jni-callback-crash-android10.md) (та же жалоба, **другой** корень — опровергнут tombstone'ом), [ARCHITECTURE.md → Supported platforms](../../ARCHITECTURE.md) |

## Жалоба

> Андроид-версия не работает: открывается, но любое действие крашит приложение.
> Андроид 10, LineageOS + microG (без рута). v2raytun и clash mi работают.

Тот же пользователь и тот же симптом, что в §128. Устройство — **HTC One M8**
(Snapdragon 801, GPU **Adreno 330**), LineageOS 17.1 (Android 10 / API 29).

В отличие от §128, теперь **есть tombstone с устройства** (logcat + DEBUG-блок).

## Диагноз — подтверждён tombstone'ом

§128 диагностировал эту жалобу по коду как JNI-callback crash (Go `Runtime::Abort`).
Tombstone эту гипотезу **опровергает**: краш не в Go/JNI и не после connect, а в
графическом потоке Flutter сразу при работе с UI.

Цепочка из лога:

```
E flutter : [ERROR:.../pipeline_library_gles.cc(245)] Impeller validation: Could not link pipeline program.
F libc   : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x34 in tid 28024 (1.raster), pid 27968 (com.leadaxe.lxbox)
F DEBUG  : Cause: null pointer dereference
F DEBUG  : backtrace:
F DEBUG  :   #00 pc 000741a8  /system/vendor/lib/libsc-a3xx.so
F DEBUG  :   #01 pc 00073f59  /system/vendor/lib/libsc-a3xx.so
F DEBUG  :   #02 pc 00074127  /system/vendor/lib/libsc-a3xx.so
F DEBUG  :   #03 pc 001fd776  <anonymous>
```

| Признак | Значение |
|---|---|
| Поток | `1.raster` — поток **растеризации Flutter** (GPU-рендер), не Go-core, не VpnService |
| Сигнатура | `Impeller validation: Could not link pipeline program` — **Impeller** (GPU-рендерер Flutter), backend **GLES** не может слинковать шейдерную программу |
| Backtrace | весь в `libsc-a3xx.so` — системный **драйвер Adreno 3xx** Qualcomm (`sc-a3xx` = shader compiler Adreno 3xx) |
| Причина | `null pointer dereference` внутри драйвера при компиляции/линковке шейдера, который сгенерировал Impeller |

Воспроизводится дважды (`21:42:56`, `21:47:28`) — оба раза идентичная подпись,
оба до какого-либо connect (нет JNI-стека, нет трафика). То есть процесс умирает
в рендере, едва пользователь что-то трогает в UI → новая перерисовка → новый
шейдер → драйвер Adreno 3xx падает.

### Корень

Flutter (текущий stable, Dart SDK 3.11) по умолчанию использует **Impeller** как
GPU-рендерер на Android. Impeller компилирует свои шейдеры под GLES; **старые
драйверы Adreno 3xx** (Snapdragon 801-эпохи, устройства до ~Android 10) на этой
компиляции падают с SIGSEGV внутри `libsc-a3xx.so`. Известная несовместимость
Flutter Impeller со старыми Adreno — не баг нашего кода.

### Почему v2raytun / clash mi работают

Нативный Android-UI (или Flutter со Skia) — не задействуют Impeller-путь
шейдерной компиляции, который ломает драйвер Adreno 3xx.

### Почему совет «отключить графический драйвер» не помог

Проблема не в hardware-acceleration вообще (она нужна и Skia), а конкретно в
**Impeller**. Лечится переключением рендерера на проверенный **Skia**, а не
отключением GPU.

### Связь с §128

§128 — обоснованная гипотеза по коду (нарушение правила §050 о JNI try/catch),
но **жалобу решает не она**. Tombstone указывает на render-слой. §128-фикс
остаётся валидным сам по себе (дыры на JNI-границе закрыть надо по правилу §050),
но как фикс **этой** жалобы он не подтверждён — корень здесь Impeller, не JNI.

## Fix

Чистого рантайм-API «отключить Impeller только при плохом GPU» у Flutter нет:
надёжного детекта `GL_RENDERER` до старта UI без живого EGL-контекста не
сделать; manifest-флаг `EnableImpeller` — бинарный для всего приложения.

Выбран компромисс **гейт по версии Android** (см. развилку ниже): на старых
API создаём собственный `FlutterEngine` с отключённым Impeller (рендерер
откатывается на Skia), на новых — оставляем дефолтный движок с Impeller.

### Порог

`Build.VERSION.SDK_INT < 31` (Android 12). Обоснование:

- Adreno 3xx встречается на устройствах вплоть до Android 10 (API 29). Adreno
  4xx/5xx-эпохи (Snapdragon 6xx/8xx 2015–2017) тоже имеют известные проблемы с
  Impeller и живут на Android ≤ 11.
- `< 31` уводит на Skia весь best-effort-tier (API 26–30) с запасом, не трогая
  primary-tier (API 31+), где Impeller штатно работает на современных GPU.
- Гейт по версии Android, **не по GPU** — компромисс: на старом Android с
  нормальным GPU Impeller тоже отключится. Для VPN-клиента с простым UI
  (списки / тогглы / формы) визуальная разница Skia↔Impeller незначима.

### Механика

`MainActivity` наследует `FlutterActivity`. Дефолтно движок создаёт сам
фреймворк (с Impeller). Чтобы отключить Impeller условно:

1. `provideFlutterEngine(context)` — на API < 31 создаём `FlutterEngine` с
   shell-аргументом `--no-enable-impeller`, прогреваем entrypoint, возвращаем
   его. На API ≥ 31 возвращаем `null` → FlutterActivity создаёт дефолтный
   движок с Impeller (поведение не меняется).
2. `configureFlutterEngine(...)` вызывается FlutterActivity'ем в обоих случаях
   (после attach) — регистрация `VpnPlugin` и method/event-каналов не ломается.

Shell-аргумент передаётся через `FlutterShellArgs` (deprecated, но рабочий —
чистого замещения для opt-out пока нет). Создание движка обёрнуто в try/catch:
при любой неожиданности возвращаем `null` (fallback на дефолтный движок —
лучше Impeller-краш на редком устройстве, чем чёрный экран на всех старых).

## Files

| File | Change |
|---|---|
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt` | `provideFlutterEngine` override: на API < 31 — кастомный движок с `--no-enable-impeller` |

## Оговорка

Гейт по `SDK_INT`, не по реальному GPU — на старом Android с хорошим GPU
Impeller отключится «зря». Это осознанный размен простоты на точность: чистого
рантайм-детекта GPU у Flutter нет, а цена ошибки (Skia вместо Impeller) для
нашего UI пренебрежимо мала.

## Verification

- [x] Kotlin compile чисто — `build-local-apk.sh` (release, arm64) собрал
      `app-arm64-v8a-release.apk` (29.1MB) без ошибок
- [x] На тест-устройстве (Android 13, API 33 ≥ 31) — установлен и запущен, pid
      alive; в логе `Using the Impeller rendering backend (Vulkan)` (Impeller
      сохранён, ветка `<31` корректно пропущена — нашей строки `disabling
      Impeller` в логе нет); `configureFlutterEngine` отработал штатно
- [ ] (только у жалобщика — нет Adreno 3xx устройства) на Android 10 / Adreno
      3xx — pid alive при работе с UI, нет `1.raster` SIGSEGV, нет
      `Impeller validation` в логе
