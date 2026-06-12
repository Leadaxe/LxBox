# 116 — Центральный banner-механизм + фикс ложного «config changed»

| Поле | Значение |
|------|----------|
| Статус | Code-complete в develop, девайс-смок pending (устройство offline) |
| Дата старта | 2026-06-12 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | tasks/113 (config-dirty mtime), features/076 (config lifecycle), features/107 (staging+автопересборка) |

## Проблема

Field report (MIUI): после правки настроек смахиваешь приложение из recents
(VPN жив — замочек), на следующем запуске висит «Config changed — restart
VPN», хотя ничего не менялось. §113 (mtime/`configDirty`) этот кейс не
закрыл.

Корень глубже одного флага. Баннер «Config changed» = `configChangedNeedRestart`,
который ставится в `saveParsedConfig` **без сравнения содержимого**:
`needRestart = tunnelUp || prev`. На старте с живым туннелем bootstrap
([home_screen.dart:293](../../app/lib/screens/home_screen.dart)) пересобирает
конфиг, если `entries.isNotEmpty && (configRaw.isEmpty || configDirty)` —
**две** независимые причины:

- `configDirty` — настройки новее конфига (mtime, §113);
- `configRaw.isEmpty` — `getConfig()` на старте не вернул конфиг (таймаут/
  гонка холодного старта на MIUI; это **не** диск, а in-memory load —
  `_loadSavedConfig` пишет `configRaw` только если ответ непустой и не `{}`).

Любая такая пересборка при `tunnelUp` зажигает баннер, даже если конфиг
байт-в-байт совпал с работающим. Прокси «save ⇒ change» сломался, когда
появилась авто-пересборка на старте (§107).

Вторая проблема — **разрозненность плашек**: три инлайн-баннера на home
(`configDirty`, `configChangedNeedRestart`, `lastError`) захардкожены
отдельными `if`-блоками с тремя разными механизмами гашения (таймер 15с в
`_onControllerChange`; снятие флага rebuild'ом; переход туннеля). Нет общей
модели — новый баннер плодит ещё один ad-hoc случай.

## Решение

Две части: единый banner-механизм + поведенческие правки.

### Часть 1 — центральный banner-механизм

**Принцип: баннер = чистая проекция наблюдаемого состояния.** Не отдельный
стор, не императивный контроллер с замыканиями (это плодит второй источник
правды и stale-captures). Источники правды — существующие notifier'ы
(`HomeState`/`SubscriptionController`/…), баннеры деривятся из них на каждый
rebuild.

Новый файл `home/widgets/app_banner.dart`:

```dart
enum BannerPalette { info, warning, error }   // primary/tertiary/error Container

class AppBanner {
  final String key;
  final String message;
  final IconData icon;
  final BannerPalette palette;
  final Duration? autoDismiss;   // null = persistent (живёт пока guard истинен)
  final VoidCallback? onTap;
  final VoidCallback? onDismiss; // вызывается, когда autoDismiss-таймер сработал
}

// Чистая функция: состояние → упорядоченный список. Guard'ы = условия.
List<AppBanner> activeBanners(HomeState s, SubscriptionController sub, BannerActions a);

// Единственная реальная машинерия — таймеры autoDismiss. StatefulWidget.
class BannerStack extends StatefulWidget { final List<AppBanner> banners; ... }
```

Упрощение модели (locked): **`autoDismiss: Duration?`**, не три режима.
`untilCondition`/`untilReload` механически идентичны — «живёт, пока guard в
`activeBanners` истинен; снимает владелец флага»; различие только в том,
какой флаг и кто его гасит, и это видно по коду guard'а. Реальный отдельный
механизм только у transient — централизованный таймер (переезжает из
`_onControllerChange` в `BannerStack`).

`BannerStack` (StatefulWidget): `Map<String,Timer> _timers`; в
`didUpdateWidget` для каждого баннера с `autoDismiss` и новым key — `Timer
(→onDismiss)`; для ключей, исчезнувших из списка — cancel. Рендер — Column
строк по нынешнему стилю (Container 8px, `Row[Icon16+Text13]`, палитра по
`BannerPalette`).

**Поток данных:**
```
HomeState / SubscriptionController / (UpdateChecker.latest …)   ← Listenable
        │  Listenable.merge([...])  →  AnimatedBuilder
        ▼
activeBanners(state, sub, actions)  →  BannerStack(banners)  →  строки + таймеры
```
Новый источник (напр. «новая версия») = его notifier в `merge` + строка-guard
в `activeBanners`. Больше ничего. **SnackBar'ы (низ, `ScaffoldMessenger`, 71
call-site) — вне скоупа**: иной UX (event vs state), Flutter их и так гоняет.

**Миграция трёх существующих** на `activeBanners`:
| key | guard | icon | palette | autoDismiss | onTap |
|---|---|---|---|---|---|
| `settings_changed` | `configDirty && !busy` | build_circle_outlined | info | — | rebuild |
| `restart` | `tunnelUp && configChangedNeedRestart && !configDirty` | info_outline | info | — | confirmStop |
| `last_error` | `lastError.isNotEmpty` | error_outline | error | 15s | clearError |

### Часть 2 — поведенческие правки

1. **`saveParsedConfig` (config_io.dart) — дифф.** Сравнить canonical(новый)
   с canonical(работающего `configRaw`):
   - равно → **не** ставить `configChangedNeedRestart`, не бампать
     `pingBatchGen`, `configDirty=false`, **touch** конфига (mtime ≥ settings,
     старт не перепроверит). Ложный баннер убит для **обоих** триггеров.
   - отличается → как сейчас (`tunnelUp` → restart).
2. **`HomeState.configLoadError`** (новый bool) + новый баннер:
   | key | guard | icon | palette | autoDismiss | onTap |
   |---|---|---|---|---|---|
   | `config_load_error` | `configLoadError` | restart_alt | error | — (untilReload) | **restart VPN** |
   Гаснет, когда `configRaw` стал непустым (успешный load/save → сбросить флаг).
3. **bootstrap (home_screen) разбить по `tunnelUp`:**
   - `configRaw.isEmpty && !tunnelUp` → собрать **молча** (рестартовать
     нечего, баннера нет);
   - `configRaw.isEmpty && tunnelUp` → `configLoadError=true`, **не**
     пересобирать (туннель уже несёт рабочий конфиг);
   - `configDirty` → пересобрать (дифф снимет ложный баннер).
4. **Лог триггера** в bootstrap: какой путь (`configRaw.isEmpty`/`configDirty`)
   + равен ли пересобранный конфиг работающему — для смока на устройстве.

## Затронутые файлы

| Файл | Что |
|---|---|
| `home/widgets/app_banner.dart` (new) | `AppBanner`/`BannerPalette`/`BannerActions` + `activeBanners` + `BannerStack` |
| `home/widgets/home_controls.dart` | три инлайн-блока (96-175) → `BannerStack(activeBanners(...))` |
| `home_screen.dart` | merge-listenables вокруг controls; lastError-таймер убрать (в `BannerStack`); bootstrap split; restart-action для `config_load_error` |
| `models/home_state.dart` | `configLoadError` (поле + copyWith) |
| `controllers/home_controller/config_io.dart` | дифф+touch в `saveParsedConfig`; сброс `configLoadError` при непустом `configRaw` |

## Locked decisions

1. Декларативная проекция, не императивный banner-controller (один источник
   правды = состояние; без замыканий-предикатов и stale-captures).
2. Модель — `autoDismiss: Duration?`, не три режима (механика одна).
3. SnackBar'ы вне скоупа.
4. `config_load_error` тап = **рестарт VPN** (значок `restart_alt`); не retry,
   не молчаливая пересборка.
5. Без content-diff в самой `isDirty` (§113-решение сохраняется); дифф —
   только в `saveParsedConfig` для `configChangedNeedRestart`.

## Риски и edge cases

- Дифф формата: `configRaw` (от `getConfig`) и canonical(новый) могут
  отличаться форматированием → сравнивать **canonical-to-canonical**
  (`canonicalJsonForSingbox` или decode→re-encode), не сырые строки.
- `config_load_error` не должен залипать: гасится при любом непустом
  `configRaw` (load/save) — обязательно сбросить в `saveParsedConfig` и в
  `_loadSavedConfig` на успехе.
- `BannerStack` таймеры — отменять в `dispose` и при исчезновении ключа
  (утечки/`setState after dispose`).
- Порядок баннеров стабильный (errors внизу/вверху — сохранить нынешний
  визуальный порядок, без «прыжков»).

## Верификация (тест-устройство — одно)

- Unit [app_banner_test.dart](../../app/test/screens/app_banner_test.dart)
  (9 кейсов): `activeBanners` — маппинг state→список каждого guard'а +
  взаимные исключения (restart перебивается configDirty/выкл. туннелем) +
  стабильный порядок + свойства `config_load_error`/`last_error`. ✅
- `flutter analyze` чистый, полный `flutter test` — 985 passed. ✅
- Дифф `saveParsedConfig` / bootstrap-ветки — без VPN-мока в тест-харнессе
  юнитом не покрыты; проверяются девайс-смоком.
- Девайс-смок: правка Tunnel apps → kill recents (VPN жив) → старт → нет
  «config changed»; реальная правка → баннер есть; `lastError` гаснет за
  15с; смоделировать пустой `configRaw`+tunnelUp → «Config loading error» с
  рестартом; три старых баннера работают через `BannerStack`.

## Нерешённое / follow-up

- Единый facade поверх инлайн-баннеров и SnackBar'ов — отдельная большая
  таска, польза спорная; не сейчас.
- Причина `configRaw.isEmpty` при tunnelUp (таймаут `getConfig` 5s на
  файловом read vs гонка готовности канала) — подтвердить логом на
  устройстве; при подтверждении таймаута — отдельно поднять timeout/retry
  загрузки (не в этой таске).
