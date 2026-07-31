# §327 — DNS Final / Default Resolver пусты на чистой установке

| | |
|---|---|
| Статус | ✅ Реализовано (device-pending) |
| Дата | 2026-07-31 |
| Связанные | [`312 dns-group`](../features/312%20dns-group/spec.md), [`263 resolve_enabled`](263-resolve-enabled-toggle.md), [`300 dns controller`](300-dns-controller.md), [`121 routing king`](121-routing-toggle-is-king.md) |

## Проблема

После чистой установки на экране «Настройки DNS» оба резолвера показывают
«выберите»: **DNS Final** и **Default Domain Resolver** пусты, хотя шаблон
задаёт им `default_value: "dns_shield"`. Соседнее поле «Стратегия» при этом
заполнено (`ipv4_only`).

Конфиг при этом собирается корректно и ядро стартует — расходится только то,
что показывает экран.

## Причина

`default_value` шаблона применялся **только билдером**
([build_config.dart:133](../../../app/lib/services/builder/build_config.dart:133)):

```dart
final raw = settings.userVars[v.name] ?? v.defaultValue;
```

Ключа в storage нет → в конфиг уходит `dns_shield`. Экран же читал storage
напрямую, без знания о шаблоне
([dns_controller.dart:213–214](../../../app/lib/services/dns/dns_controller.dart:213)):

```dart
var dnsFinal = vars['dns_final'] ?? '';
var defaultResolver = vars['dns_default_domain_resolver'] ?? '';
```

`vars` при первом запуске ничем не преднаполняется — там лежит только то, что
юзер сам сохранил ([vars.dart:11](../../../app/lib/services/settings_storage/vars.dart:11)).
Отсюда «выберите».

На одну переменную приходилось **три источника дефолта**:

| Источник | Значение | Где |
|---|---|---|
| шаблон | `dns_shield` | `wizard_template.json` — vars `dns_final` / `dns_default_domain_resolver` |
| автосброс §121 | `cloudflare_udp` | [dns_controller.dart:217,222](../../../app/lib/services/dns/dns_controller.dart:217) |
| экран | `''` (пусто) | там же, `:213–214` |

Стратегия страдала тем же в мягкой форме — дефолт был скопирован литералом
(`vars['dns_strategy'] ?? 'ipv4_only'`), поэтому поле выглядело заполненным,
но значение дублировало шаблон вручную.

Сам `dns_shield` до дропдауна доезжает — проверено прогоном по реальному
шаблону: тег есть в `templateByTag`, обёртка резолвится, `enabledServerTags`
его возвращает. Группа (`type: group`) нигде по пути не отсекается.

### Чем это грозило дальше

`stage()` пишет все три var разом
([dns_controller.dart:266–270](../../../app/lib/services/dns/dns_controller.dart:266)).
Стоило юзеру тронуть любую настройку DNS — в storage осело бы
`dns_final: ""`. Пустая строка это уже не «ключа нет», и `?? v.defaultValue`
билдера её не перехватывает: конфиг остался бы **без резолверов** (§263 —
именно та связка «два разных резолвера», где пустой `route.default_domain_resolver`
ломает разрешение имён в маршрутизации).

## Решение

Единственный источник дефолта — `default_value` шаблона. `template` в
`DnsController.load()` уже есть, `template.vars` — плоский список `WizardVar`
с `defaultValue`; новых зависимостей не потребовалось.

```dart
final templateDefaults = <String, String>{
  for (final v in template.vars) v.name: v.defaultValue,
};
String defaultOf(String name) => templateDefaults[name] ?? '';
```

| Было | Стало |
|---|---|
| `vars['dns_final'] ?? ''` | пусто **или отсутствие ключа** → `defaultOf('dns_final')` |
| `vars['dns_default_domain_resolver'] ?? ''` | то же → `defaultOf('dns_default_domain_resolver')` |
| автосброс → `'cloudflare_udp'` ×2 | → `defaultOf(...)` |
| `vars['dns_strategy'] ?? 'ipv4_only'` | → `defaultOf('dns_strategy')` |

Пустая строка трактуется как «не задано» наравне с отсутствием ключа — это
закрывает сценарий с осевшим `""` из `stage()`.

Дополнительно обеим переменным проставлен явный `required: true` в шаблоне:
парсер и так подставляет `true` по умолчанию
([parser_config.dart](../../../app/lib/models/parser_config.dart) — `json['required'] as bool? ?? true`),
так что поведение не меняется — флаг фиксирует намерение, чтобы backstop
билдера ([build_config.dart:141](../../../app/lib/services/builder/build_config.dart:141))
не отключился молча при будущей правке шаблона.

## Тултипы

Оба тултипа рекомендовали серверы, переставшие быть дефолтом, и не упоминали
`dns_shield` вовсе — юзер видел выбранным `dns_shield`, а в подсказке
«Recommended: cloudflare_udp, google_udp, or google_doh». Добавлена строка про
дефолт-группу; остальные рекомендации сохранены.

Тексты живут **в двух местах** и правились синхронно:

| Место | Что |
|---|---|
| `wizard_template.json` | `tooltip` у обеих vars |
| [dns_settings_screen.dart:649,666](../../../app/lib/screens/dns_settings_screen.dart:649) | `ResolverPicker.tooltip` (своя, более длинная редакция) |

Сведение тултипа к одному источнику — отдельная задача (меняет слой), здесь
намеренно не делалось.

## Второй случай той же болезни — seed auto-канала

Поиск по коду («нет ли этого ещё где-то») дал **второй реальный баг**, не
мёртвый код.

`group_templates.auto.options` в шаблоне несёт `@urltest_*`-плейсхолдеры —
var-substitution идёт позже, в билдере. Сид каналов на первом запуске
(`_seedAutoFromTemplate`) их резолвить не умел и падал на литералы в коде:

```dart
url: str(opts['url']) ?? 'https://cp.cloudflare.com/generate_204',
interval: str(opts['interval']) ?? '5m',
tolerance: toInt(opts['tolerance']) ?? 50,
```

Литералы разошлись с шаблоном (`urltest_tolerance: 30`,
`urltest_interval: 15m`), и в `channels[]` на чистой установке оседало
чужое значение. Проверено прогоном до фикса:

```
vpn-1: tolerance=50 interval=5m     ← шаблон: 30 / 15m
vpn-2: tolerance=50 interval=5m
```

Решение — `varDefaults` (имя var → `default_value`) пробрасывается в
`migrateChannelsIfNeeded` из обоих вызывающих ([main.dart](../../../app/lib/main.dart),
[routing_srs_cache.dart](../../../app/lib/screens/routing_screen/routing_srs_cache.dart)),
и `@var` резолвится по нему. Порядок: значение из `options` → `default_value`
его var → дефолт `ChannelAuto` (последний рубеж, если var исчезнет из шаблона).
После фикса — `tolerance=30 interval=15m`, как в шаблоне.

### Мёртвый код рядом

В `_channelsFromTemplate` билдера ([build_config.dart:744](../../../app/lib/services/builder/build_config.dart:744))
стояли те же литералы (`'50'`, `'15m'`), но **недостижимые**: `vars` в
`buildConfig` уже наполнен `userVars[name] ?? defaultValue`, поэтому
`resolve()` там никогда не возвращает `null`. Проверено прогоном настоящего
билда — в конфиг приходит `tolerance=30` и при пустой, и при отсутствующей
переменной. Литералы убраны: остались только дефолты `ChannelAuto`.

### Что проверено и НЕ является багом

| Место | Вердикт |
|---|---|
| `getVar(name, 'литерал')` по всем 43 vars шаблона | расхождений нет (`ipv6_enabled` совпадает) |
| остальные 6 мест `getAllVars()` | берут `v.defaultValue` либо не про дефолты |
| `ChannelAuto.fromJson` — `?? '5m'`, `?? 50` | **не дубль**: `toJson` пишет ключи всегда, значит `??` срабатывает только для каналов, сохранённых до §272 — законная граница совместимости (см. комментарий §272 в [channel.dart:97](../../../app/lib/models/channel.dart:97)) |
| `wizard_ui: "fix"` vars | ровно две — обе из этой таски |

## Файлы

| Файл | Изменение |
|---|---|
| [`dns_controller.dart`](../../../app/lib/services/dns/dns_controller.dart) | `templateDefaults`/`defaultOf`; дефолты Final/Resolver/Strategy + автосброс из шаблона |
| [`wizard_template.json`](../../../app/assets/wizard_template.json) | тултипы обеих vars; явный `required: true` |
| [`dns_settings_screen.dart`](../../../app/lib/screens/dns_settings_screen.dart) | тултипы обоих `ResolverPicker` |
| [`dns_controller_test.dart`](../../../app/test/services/dns_controller_test.dart) | регрессия: дефолты из шаблона, а не из литералов |
| [`channels.dart`](../../../app/lib/services/settings_storage/channels.dart) | `varDefaults` в seed'е auto-канала; `@var` → `default_value` |
| [`settings_storage.dart`](../../../app/lib/services/settings_storage.dart) | `migrateChannelsIfNeeded(gt, {varDefaults})` |
| [`main.dart`](../../../app/lib/main.dart), [`routing_srs_cache.dart`](../../../app/lib/screens/routing_screen/routing_srs_cache.dart) | проброс `varDefaults` из шаблона |
| [`build_config.dart`](../../../app/lib/services/builder/build_config.dart) | убраны недостижимые литералы в `_channelsFromTemplate` |
| [`channels_migration_test.dart`](../../../app/test/migration/channels_migration_test.dart) | регрессия seed'а по `@var`; обновлён тест dev.91 |

## Проверка

- [x] `flutter test` — вся сьюта (2589)
- [x] `flutter analyze` — весь проект (§CI: не только `lib/`)
- [x] 4 l10n-чекера `--strict` (тултипы = ключи перевода → ru-словари)
- [x] seed каналов на реальном шаблоне: `tolerance=30 interval=15m` (было 50/5m)
- [ ] **device**: чистая установка → экран DNS показывает `dns_shield` в обоих
      полях; тронуть любую настройку → `stage()` не пишет `""`
- [ ] **device**: чистая установка → auto-канал в Routing показывает
      tolerance 30 / interval 15m
