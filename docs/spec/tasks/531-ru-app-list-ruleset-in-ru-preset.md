# 531 — rule-set российских приложений (legiz-ru) в пресете «Ru internet segment»

| Поле | Значение |
|------|----------|
| Статус | **Done** (реализовано) |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Issue | [#116](https://github.com/Leadaxe/LxBox/issues/116) «Select Russian apps» — просили кнопку в пикере приложений, которая одним нажатием отмечает российские приложения |
| Коммиты | ветка `task-531` |
| Связанные spec'ы | §045 (geoip-ru fallback в том же пресете — образец четвёртого набора и гейта `#enable`), §011 (remote rule_set → локальный кэш `.srs`), §107 (гейт фрагмента `#enable`), §128 (`findConnectionOwner` — путь package name), §279/§285/§452 (l10n: ключ = английский текст), §439 (golden-эталоны хранения) |

---

## Контекст и решение владельца

Issue #116 просит кнопку «Select Russian apps» в пикере per-app — то есть
разовую операцию над списком отметок. Такая кнопка **отклонена**: список
приложений меняется, отметки пришлось бы держать и обновлять вручную, а
per-app-режим в Android работает на уровне всего туннеля (VpnService
`addAllowedApplication`/`addDisallowedApplication`), то есть он не умеет
«направить приложение напрямую, а остальное — в туннель» — он умеет только
полностью исключить приложение из туннеля.

Решение владельца: то же самое сделать **маршрутизацией**, добавив готовый
rule-set российских приложений четвёртым набором в пресет РФ (`ru-direct`).
Тогда трафик российских приложений идёт `direct` по тому же правилу, по
которому уже идут домены и IP-диапазоны из наборов runetfreedom, — и список
приложений обновляется сам, вместе с набором.

Источник набора: `https://raw.githubusercontent.com/legiz-ru/sb-rule-sets/main/ru-app-list.srs`
(автор legiz-ru, репозиторий [legiz-ru/sb-rule-sets](https://github.com/legiz-ru/sb-rule-sets)).

---

## Факты разведки

### 1. Как пресет `ru-direct` подключает наборы runetfreedom

`app/assets/wizard_template.json`, пресет `ru-direct` (с `"preset_id":
"ru-direct"`). Наборы в `rule_set[]`:

| Тег | Форма | Гейт |
|-----|-------|------|
| `ru-domains` | `type: inline` (домены в теле) | всегда |
| `ru-services` | `type: inline` (домены сервисов в теле) | всегда |
| `geoip-ru` | `type: remote`, `format: binary`, `update_interval: 168h`, url runetfreedom `rule-set-geoip/geoip-ru.srs` | `"#enable": ["@geoip_enabled"]` |

Сюда же относятся `ads-all` в пресете `block-ads` (строка url ~1248 до правки)
и `ru-inside` в пресете `ru-inside` — та же форма remote-набора.

Терминальное правило пресета — **одно**, со списком тегов:

```json
{ "rule_set": ["ru-domains", "ru-services", "geoip-ru"], "outbound": "@outbound" }
```

**`download_detour` в шаблоне не используется ни у одного набора** (`grep
download_detour app/assets/wizard_template.json` — ноль совпадений): remote-набор
никогда не скачивается ядром. Его забирает приложение
(`app/lib/services/rule_set_downloader.dart`) в дисковый кэш
`$docs/rule_sets/preset__<presetId>__<tag>.srs`, а `preset_expand` подменяет
`type: remote` на `type: local` + `path`
(`app/lib/services/builder/preset_expand.dart:189-206`). Поэтому вопрос
«raw.githubusercontent.com блокируется в РФ» решается не полем
`download_detour`, а тем же путём, что у соседей, — см. «Риски».

### 2. Как `package_name` поддержан ядром и что отдаёт LxBox

- Опция headless-правила: `/Users/macbook/projects/sing-box-lx/option/rule_set.go:267`
  — `PackageName badoption.Listable[string]` (`json:"package_name,omitempty"`),
  рядом `PackageNameRegex` (:268).
- Сборка правила из набора: `route/rule/rule_headless.go:147-148` —
  `NewPackageNameItem(options.PackageName)`.
- Матч: `route/rule/rule_item_package_name.go:26-36` — сверяет
  `metadata.ProcessInfo.AndroidPackageNames` с map тегов набора.
- Источник `ProcessInfo` на Android — платформенный искатель, а не procfs:
  `route/platform_searcher.go:21-43` (`FindProcessInfo` → `platform.FindConnectionOwner`),
  результат раскладывается в `AndroidPackageNames` в
  `experimental/libbox/service.go:229`; поле объявлено в `adapter/platform.go:102`.
- **LxBox действительно отдаёт ядру имена пакетов:**
  `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt:36-79`
  — `findConnectionOwner` берёт uid через
  `ConnectivityManager.getConnectionOwnerUid`, затем
  `PackageManager.getPackagesForUid(uid)` и отдаёт список в
  `setAndroidPackageNames(StringArray(packages.iterator()))` (строка 78). Вызов
  включён глобально — в шаблоне стоит `find_process: true`, см. комментарий
  §128/F12.3 там же.

Итог: `package_name` в headless-наборе на Android матчится, и путь uid → пакеты
в LxBox уже рабочий; задача 531 не требует ни правок ядра, ни правок Kotlin.

### 3. Проверка самого `.srs`

Файл скачан в scratchpad (в репозиторий **не положен**), 4443 байта.
Первые байты — `53 52 53 01` (`SRS\x01`, магия sing-box rule-set) далее
zlib-поток (`78 da`). Формат и содержимое (headless-правила с `package_name`)
соответствуют README репозитория legiz-ru. Бинарь ядра с
`sing-box rule-set decompile` в дереве не собран, поэтому распаковка не
выполнялась — достаточно магии формата и заявленного состава набора.

---

## Что сделано

Всё — в `app/assets/wizard_template.json`, пресет `ru-direct`, плюс зеркала
строк в l10n и доках.

### Четвёртый набор

```json
{
  "tag": "ru-apps",
  "#enable": ["@apps_enabled"],
  "type": "remote",
  "format": "binary",
  "update_interval": "168h",
  "url": "https://raw.githubusercontent.com/legiz-ru/sb-rule-sets/main/ru-app-list.srs"
}
```

Форма — копия `geoip-ru`: тот же `format`, тот же `update_interval`, тот же
гейт `#enable` (§107), тот же путь скачивания. `download_detour` не задан — как
у всех наборов шаблона.

### Новая галка пресета

В `vars` после `geoip_enabled`:

```json
{
  "name": "apps_enabled",
  "type": "bool",
  "default_value": "true",
  "title": "Russian apps by package",
  "tooltip": "Route Android apps from the legiz-ru list (banks, marketplaces, government services, Yandex/VK and others) by package name, regardless of the domains they use. Auto-downloads ru-app-list.srs (~4 KB) on first use."
}
```

Размер в подсказке — реальный (4443 байта ≈ 4 КБ), формулировка по образцу
`geoip_enabled` («~150 KB»).

### Правило

Терминальное правило пресета получило четвёртый тег:

```json
{ "rule_set": ["ru-domains", "ru-services", "geoip-ru", "ru-apps"], "outbound": "@outbound" }
```

### Переименование пресета

`ui.label`: «Russian domains & IPs» → **«Ru internet segment»** — метка больше
не описывает состав (он теперь шире доменов и IP).
`ui.description` дополнена одной фразой: «…Russian IP ranges and Russian apps
(by package name) directly.»

### `dns_rules` — НЕ тронуты (обоснование)

У доменных наборов `ru-domains`/`ru-services` есть парные DNS-правила (`server:
dns_ru` + AAAA-предикат под `@force_ipv4`). Для `ru-apps` пары **нет и быть не
может**:

1. DNS-запрос идёт не от приложения напрямую, а от системного резолвера
   (`netd` на Android). Владелец DNS-соединения, который увидит
   `findConnectionOwner`, — резолвер системы, а не приложение, чей домен
   резолвится. `package_name` в DNS-правиле матчил бы пакет резолвера.
2. `geoip-ru` — тот же случай и та же причина: набор в DNS-правилах пресета
   отсутствует (IP-набор нечего матчить на этапе запроса имени).

Поэтому маршрутизация по пакету работает на уровне route-правила, а DNS
приложения продолжает идти по обычным правилам (по домену — если домен попал в
`ru-domains`/`ru-services`, иначе по дефолтному серверу). Практический эффект:
соединение приложения уйдёт `direct` независимо от того, как разрешилось имя.

### Зеркала строк

По правилам `docs/l10n.md` (§279/§285: **ключ = английский текст**; смена текста
= смена ключа, старый ключ становится unknown → падение `template_check`)
обновлены обе локали:

- `app/assets/l10n/ru/template.json` и `app/assets/l10n/zh/template.json` —
  переименованы ключи метки и описания, добавлены два новых ключа
  (`title`/`tooltip` галки) сразу после блока `GeoIP IP-range fallback`.
- `app/assets/contract/registry/presets.json` — метка `ru-direct` и заметки о
  РАЗРЫВЕ N2 (пара `russian` на desktop) приведены к новой метке и составу.
- `README.md` / `README.ru.md` (строка 197, §354) и `docs/USER_GUIDE.md` /
  `docs/USER_GUIDE.ru.md` — упоминание метки обновлено. Исторические записи в
  `CHANGELOG.md` и `docs/releases/*` оставлены как есть: они описывают прошлое
  состояние.

### Golden

`app/test/fixtures/storage/golden/rich_v0.config_warnings.json` — **+1 строка**:

```
"preset \"ru-direct\": remote rule_set \"ru-apps\" skipped — no cached file (download first)"
```

`rich_v0.config.json` **не изменился** — и это правильно. Фикстура `rich_v0`
держит пресет как `kind: preset` с одними `varsValues`, то есть тело
разворачивается из живого шаблона на каждой сборке; но в кэше
`test/fixtures/storage/rule_sets/rich_v0/` файла для `ru-apps` нет, поэтому
набор выпадает (`preset_expand.dart:189-197`), а dangling-guard того же
конвейера вычищает недоступный тег из списка `rule_set` правила
(`preset_expand.dart:213-215` и разбор route-правил ниже). Ровно так же в
эталоне отсутствует `geoip-ru`. Диффа `avd_v0` нет — там ru-direct не включён.

---

## Что НЕ сделано (осознанно)

- **Кнопка «Select Russian apps» в пикере приложений — отклонена** (решение
  владельца). Причины: per-app в Android — это allow/deny-list всего туннеля, а
  не маршрутизация; разовая отметка застывает и требует ручного обновления;
  список приложений уже поддерживается внешним набором.
- **Парные DNS-правила для `ru-apps`** — не добавлены, см. обоснование выше.
- **`download_detour`** — не добавлен: в шаблоне его нет ни у одного набора,
  скачиванием занимается приложение, а не ядро.
- **Файл `.srs` в репозиторий не положен** — набор remote, кэшируется на
  устройстве.
- **Правок ядра и Kotlin нет** — путь `package_name` уже рабочий (см. факты §2).

---

## Риски

1. **`raw.githubusercontent.com` блокируется в РФ.** Ровно тот же риск, что у
   трёх существующих наборов пресета (runetfreedom лежит там же), и решается тем
   же механизмом: скачивает приложение через свой HTTP-слой, а не ядро, поэтому
   загрузка идёт по текущему состоянию туннеля. Без кэша набор просто выпадает с
   предупреждением, а правило продолжает работать по остальным тегам — ядро не
   падает (dangling-guard, `preset_expand.dart:213`). Отдельной настройки пути
   загрузки задача не вводит: это общий вопрос ко всем наборам шаблона.
2. **Лицензия набора.** Условия распространения `ru-app-list.srs` определяет
   репозиторий автора — [legiz-ru/sb-rule-sets](https://github.com/legiz-ru/sb-rule-sets)
   (см. его README/LICENSE). LxBox не встраивает файл и не перераспространяет
   его: в шаблоне только URL, скачивание — на устройстве пользователя, как у
   наборов runetfreedom.
3. **Ложноположительные срабатывания.** Набор ведёт сторонний автор; попадание в
   него приложения, которое пользователь хочет гнать через туннель, лечится
   снятием новой галки (`apps_enabled`) — набор целиком отключается, а домены и
   IP продолжают работать.
4. **Смена метки пресета.** Метка — отображаемая строка, `preset_id` не менялся,
   поэтому сохранённые правила пользователей продолжают разворачиваться. Риск
   только текстовый: расхождение метки со старыми скриншотами и с историческими
   записями CHANGELOG.

### Замечание на будущее (дефект НЕ задачи 531)

Гейт фрагмента читается двумя разными путями, и они разошлись:

- **сборка** — `fragmentGateSatisfied` (`app/lib/services/builder/preset_expand.dart:682-707`)
  понимает и легаси `enabled`, и канонический `#enable` (`enableKey`);
- **скачивание и UI** — `isRuleSetEnabledFor` (`app/lib/models/preset_rule_set.dart:84-101`)
  читает **только** `rs['enabled']` и про `#enable` не знает; отсутствие поля
  трактуется как always-on (`raw == null → true`).

Следствие: у набора с гейтом только в форме `#enable` экран Routing считает его
всегда включённым — то есть скачивает `.srs` и требует его наличия даже при
снятой галке. Это **ровно то же поведение, что у `geoip-ru`** сегодня на
`develop` (единственный гейтованный набор в шаблоне до этой задачи; проверено:
`enabled` у него отсутствует, стоит `#enable: ["@geoip_enabled"]`). Задача 531
идёт по образцу соседа и ничего не меняет в этом поведении — поэтому правка
вынесена отдельно, а не сделана здесь: она затрагивает `geoip-ru` тоже и требует
своего решения владельца (унифицировать `isRuleSetEnabledFor` на `#enable` либо
дублировать гейт обеими формами в шаблоне).

---

## Приёмка

1. `app/assets/wizard_template.json`: пресет `ru-direct` содержит четыре
   `rule_set` (`ru-domains`, `ru-services`, `geoip-ru`, `ru-apps`), у `ru-apps`
   стоят `#enable: ["@apps_enabled"]`, `type: remote`, `format: binary`,
   `update_interval: 168h`, url legiz-ru; `vars` содержит `apps_enabled`
   (bool, default `true`); терминальное правило перечисляет четыре тега;
   `dns_rules` без `ru-apps`. ✅
2. `ui.label` = `Ru internet segment`, `ui.description` упоминает Russian apps
   by package name. ✅
3. `dart tool/l10n/template_check.dart` — `failures: 0, warnings: 0`. ✅
4. Точечные прогоны зелёные: `test/builder/if_engine_test.dart`,
   `test/builder/enable_load_validation_test.dart`,
   `test/builder/registry_gate_test.dart`,
   `test/services/builder/preset_expand_test.dart`,
   `test/services/rule_set_auto_updater_test.dart`,
   `test/services/preset_on_change_test.dart`, `test/services/l10n/`,
   `test/storage_migration/` (goldens). ✅
5. Golden-дифф ровно +1 предупреждение о некэшированном `ru-apps`; `config.json`
   обоих фикстур без изменений. ✅
6. На устройстве (ручная проверка вне CI): включённый пресет с галкой «Russian
   apps by package» скачивает `preset__ru-direct__ru-apps.srs`, и в
   `running config` у правила пресета виден тег `ru-direct:ru-apps`; трафик
   приложения из списка уходит в `@outbound` (по умолчанию `direct-out`).
