# §289 — Per-subscription fetch identity (Default / Custom override)

**Тип:** feature (расширение §118) · **Статус:** in progress (develop)

## Проблема

Идентичность HTTP-фетча подписок (§118: User-Agent + HWID `x-hwid` + device-meta
`x-device-os`/`x-ver-os`/`x-device-model`) сейчас **глобальная** — один набор на
всё приложение (`SubscriptionIdentity`, static holder, экран
`app_settings_screen` → таб Subscriptions). Один HWID уходит во **все** подписки.

Панели (Remnawave/Marzban) лимитируют клиентов по HWID (device-limit) и по UA
(формат ответа). Когда подписок несколько (разные панели), одного глобального
HWID/UA мало — нужна возможность задать **свою** идентичность на конкретную
подписку.

## Решение — режим Default / Custom на подписку

У каждой подписки — переключатель идентичности:

- **Default** (по умолчанию) — подписка использует **глобальный**
  `SubscriptionIdentity`, как сейчас. Поведение §118 не меняется.
- **Custom** — подписка несёт **полный слепок** всех 6 переменных и фетчится
  ТОЛЬКО ими; глобальные значения игнорируются (не каскад, не пофайловый
  fallback — либо весь глобальный набор, либо весь локальный).

Переходы:
- **Default → Custom**: слепок инициализируется **копией текущих глобальных**
  значений (UA override, sendHwid, hwid, effective device-os/ver-os/model), чтобы
  юзер стартовал не с нуля. Дальше правит что нужно (обычно Regenerate HWID).
- **Custom → Default**: слепок **отбрасывается** (`identity = null`). Повторное
  включение Custom → снова свежая копия глобальных (скрытого состояния нет).

Глобальный экран и `SubscriptionIdentity` **остаются** (глобальный default +
источник копии для Custom). Обратная совместимость значений не требуется —
ничего не мигрируем, старые глобальные значения продолжают жить как есть.

## Модель данных

### Новый подобъект `SubscriptionIdentityOverride` (nullable) в `SubscriptionServers`

`app/lib/models/server_list.dart`:

```dart
class SubscriptionIdentityOverride {
  final String userAgent;      // '' = дефолт из глобала (брендированный LxBox-android)
  final bool sendHwid;
  final String hwid;           // UUIDv4
  final String deviceOs;       // '' → заголовок не кладём
  final String verOs;
  final String deviceModel;
  // toJson / fromJson (толерантный) / copyWith
}
```

В `SubscriptionServers` — поле `final SubscriptionIdentityOverride? identity;`
(`null` = Default). **§283-паттерн**: поле обязано жить в трио
`toJson`/`fromJson`/`copyWith` (JSON-ключ `identity`), иначе merge-импорт бэкапа
(`fromJson→toJson`) молча его потеряет. `copyWith` — со «стиранием» до null:
использовать sentinel или отдельный флаг (Dart `?? this` не даёт выставить null),
см. как это делается для nullable-полей в проекте, либо через
`bool clearIdentity`.

### Резолв в фетче

```
sub.identity == null → глобальный SubscriptionIdentity (как §118)
sub.identity != null → только поля sub.identity
```
Заголовки `x-*` кладутся только если итоговый `sendHwid == true` И `hwid`
непустой (форма — как в `SubscriptionIdentity.fetchHeaders`).

## Транспорт до `_fetch`

Точка сборки заголовков — единственная: `_fetch`, кейс `UrlSource` в
`app/lib/services/subscription/sources.dart:170-180`.

`UrlSource` уже несёт `userAgent?` (§118 №5, но нигде не проставлялся) и
`timeout`. Расширяем его подобъектом идентичности:

```dart
final class UrlSource extends SubscriptionSource {
  final String url;
  final String? userAgent;          // существующий (оставляем)
  final SubscriptionIdentityOverride? identity; // NEW: per-sub слепок; null → глоб.
  final Duration timeout;
}
```

`_fetch` (строки 174-180) переписать:
```dart
final id = source.identity;               // null → глобальный
final effectiveUa = id != null
    ? (id.userAgent.isNotEmpty ? id.userAgent : resolveSubscriptionUserAgent())
    : (ua ?? (SubscriptionIdentity.userAgentOverride.isNotEmpty
        ? SubscriptionIdentity.userAgentOverride
        : resolveSubscriptionUserAgent()));
final reqHeaders = {
  'User-Agent': effectiveUa,
  ...(id != null ? _overrideHeaders(id) : SubscriptionIdentity.fetchHeaders()),
};
```
`_overrideHeaders(id)` — та же форма, что `SubscriptionIdentity.fetchHeaders`
(gate по `sendHwid && hwid.isNotEmpty`, effective device-meta), но из слепка.
Вынести форму в общий хелпер, чтобы не дублировать (напр. статический
`SubscriptionIdentity.headersFrom({sendHwid, hwid, deviceOs, verOs, model})`).

### Call-sites `UrlSource(...)` — проставить `identity`

| Файл:строка | Контекст | identity |
|---|---|---|
| `subscription_controller.dart:1654` | auto/manual refresh (в скоупе `list: SubscriptionServers`) | `list.identity` |
| `subscription_controller.dart:817` | смена источника (edit) | `entry.list` identity, если это SubscriptionServers |
| `subscription_controller.dart:1139` | `addUrlSnapshotToFolder` (разовый импорт, URL не хранится) | `null` (идентичность не применима) |
| `subscription_detail_screen.dart:181` | «показать сырой ответ» (Source-таб) | `widget.entry.list` identity |

## UI

### Экран подписки — секция «Fetch identity» (NEW)

`app/lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart`
— добавить секцию рядом с блоком «Subscription» (после строки 250), видимую при
`entry.list is SubscriptionServers`. Заголовок «Fetch identity» (по образцу
«Detour servers» / «Subscription»), затем:

- `SwitchListTile` **Custom identity** (off = Default).
  - `value = entry.identity != null`.
  - `onChanged(true)` → колбэк `onEnableCustomIdentity`: собрать слепок из
    текущих глобальных (`SubscriptionIdentity.userAgentOverride`/`sendHwid`/`hwid`/
    `effectiveDeviceOs`/`effectiveVerOs`/`effectiveDeviceModel`) → записать в
    `entry.identity` → persist.
  - `onChanged(false)` → `onDisableCustomIdentity`: `entry.identity = null` →
    persist.
- При Custom — полный блок полей (как глобальный сейчас, но пишет в
  `entry.identity`): Custom User-Agent (edit-dialog), Send HWID (switch), при
  sendHwid — HWID (edit + Regenerate ↻), x-device-os, x-ver-os, x-device-model.
  Переиспользовать паттерн `_editRow` из глобального таба и edit-диалоги
  (`onEditSource`-стиль колбэков).

Мутации — через колбэки из родителя `subscription_detail_screen.dart` (как
`onTagPrefixChanged`/`onShowIntervalPicker`): каждый пишет в `entry.identity` (или
его поле через `copyWith` слепка) + `controller.persistSources()`.

`SubscriptionEntry` (`controllers/subscription_controller/subscription_entry.dart`)
— добавить геттер `identity` и сеттеры-мутаторы по образцу существующих
(`copyWith` списка + `_replaceList`).

### Глобальный экран — БЕЗ изменений

`app_settings_screen.dart` + `subscriptions_tab.dart` (блок Fetch identity,
строки 79-142) — **остаются** как глобальный default. Ничего не удаляем.

## Хранилище / бэкап / диагностика

- Per-sub `identity` живёт внутри JSON подписки (ключ `identity` в
  `SubscriptionServers.toJson`) → внутри top-level `server_lists`, который **уже**
  и в export, и в import-allowlist (`allowedTopLevelKeys`). Отдельный
  backup-ключ НЕ нужен (в отличие от глобальных vars, §221).
- Глобальные 6 ключей (`subscription_*`) и их allowlist-запись
  (`_appFeatureFlagVars`) — **не трогаем** (глобальное остаётся).
- `docs/STORAGE.md` — дополнить схему `server_lists` полем `identity`; строки
  §118 про глобальные ключи оставить.
- **Диагностика/дамп** (`dump_builder.dart:74`, `_sanitizeList`): пишет
  `l.toJson()` как есть, **URL не маскируется** (дамп — read-by-design
  диагностика, уже содержит секретный URL-токен). `identity.hwid` поедет так же,
  без маскировки — консистентно с URL (маскировать HWID, оставляя токен в URL,
  было бы непоследовательно). Правок в `dump_builder.dart` НЕ требуется.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/server_list.dart` | `SubscriptionIdentityOverride` + поле `identity?` в трио toJson/fromJson/copyWith |
| `app/lib/services/subscription/sources.dart` | `UrlSource.identity` + резолв в `_fetch` (глоб. vs слепок) |
| `app/lib/services/subscription/subscription_identity.dart` | вынести общий хелпер формы заголовков (`headersFrom`) для переиспользования |
| `app/lib/controllers/subscription_controller.dart` | проставить `identity` в 2 call-site (`:1654`, `:817`) |
| `app/lib/controllers/subscription_controller/subscription_entry.dart` | геттер/сеттеры `identity` |
| `app/lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart` | секция «Fetch identity» (Custom-тумблер + блок полей) |
| `app/lib/screens/subscription_detail_screen.dart` | колбэки мутаций identity |
| `app/lib/screens/subscription_detail_screen/widgets/*` или общий | edit-строки/диалоги (переиспользовать глоб. `_editRow`) |
| `app/lib/services/dump_builder.dart` | маскировка `identity.hwid` при необходимости |
| `docs/STORAGE.md` | поле `identity` в схеме `server_lists` |
| l10n `assets/l10n/ru/ui.json` | новые строки: «Custom identity», «Fetch identity», переиспользовать существующие HWID-строки |

## Вне скоупа

- Миграция глобального HWID в подписки (обратная совместимость не нужна).
- Пофайловый каскадный fallback (решили: Custom = полный слепок, не микс).

## Приёмка

- У подписки в настройках — тумблер Custom identity (off по умолчанию).
- Включение → поля заполнены копией глобальных; правки (Regenerate HWID) пишутся
  в подписку; выключение → слепок отброшен.
- Default-подписка фетчится глобальной идентичностью (регресса §118 нет).
- Custom-подписка шлёт свой UA/x-hwid/device-meta; глобальные игнорирует.
- Слепок переживает рестарт и merge-импорт бэкапа (в трио toJson/fromJson/copyWith).
- `flutter analyze` + `flutter test` зелёные; `ui_check --strict` без новых orphan.
