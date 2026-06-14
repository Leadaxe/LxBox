# 124 — Allow-list / per-app: self-package, protect, allowBypass (investigation)

| Поле | Значение |
|------|----------|
| Статус | **Code-complete + девайс-смок ✅ (OnePlus CPH2411, Android 15, vc=2542, 2026-06-14).** self-инъекция в `BoxService.kt` (helper `buildOverrideOptions`). Все 3 проверки пройдены на устройстве (см. «Девайс-смок»). autoRedirect-проброс — отложен (root-фича, отдельно). Репро на Samsung-репортёрах НЕ проводилось (нет устройства), но механика подтверждена на нашем. |
| Дата старта | 2026-06-14 |
| Триггер | Форум: на двух Samsung (Android 10/11) «Allow-list — всё те же проблемы». Юзер: на части устройств (Android 12/13) ручное добавление `com.leadaxe.lxbox` в allow-list **чинит** туннель. Связь с upstream [SagerNet/sing-box#3715](https://github.com/SagerNet/sing-box/issues/3715) (fix в `1.13.0-rc.7`) и [#3387](https://github.com/SagerNet/sing-box/issues/3387). |
| Связанные | [§046](../features/046%20tunnel%20apps%20split-tunneling/spec.md) (tunnel apps), [§069](069-current-session-allow-bypass.md) (allowBypass snapshot), [§075](075-tun-apps-restart-regen-config.md), [§048](048-perapp-trace-attribution-gaps.md), [§049](049-singbox-wrapper-deep-audit/spec.md) (wrapper audit), [§119/§120](119-default-network-not-vpn.md) (defaultNetwork) |

> **Назначение документа:** зафиксировать всё, что прочитано и подтверждено по коду в этой сессии, чтобы НЕ перечитывать заново. Все факты ниже — с `file:line`. Где факт не из кода (Android-семантика, эталон без локального клона) — помечено.

---

## TL;DR

1. **Версия ядра:** мы на форке `sing-box-lx` **v1.13.13-lx.6** (пин), клон на диске `v1.13.13-lx.7+2`. Это **на 13 минорных новее** `1.13.0-rc.7`, где CoolMask видел fix → **upstream-fix rc.7 у нас уже есть** (релизы накопительные). Жалоба ≠ тот баг.
2. **Утверждено:** юзерский список → конфиг (явное, диагностируемо), тени (`self` только-allow + `autoRedirect`) → OverrideOptions (runtime-only). См. [«Утверждённое решение»](#утверждённое-решение-архитектура-фикса). `protect(fd)` оставляем (мы строже эталона).
3. **allowBypass, protect(fd), self-в-allowlist — ОРТОГОНАЛЬНЫ** (workflow + 3 adversarial-скептика, все `holds:true`). self-фикс **не** влияет на allowBypass и **не** обессмысливает его.
4. **self-фикс ≠ доказанный фикс жалобы.** В дефолте (allow, self НЕ в списке) egress ядра прикрыт **дважды** (UID вне whitelist + `protect(fd)`). self-фикс = **паритет с SFA + defense-in-depth**, а не подтверждённое лечение Samsung-бага. Вероятный корень жалобы — **lockdown/always-on VPN** или **SDK-различия** (см. [открытые вопросы](#открытые-вопросы)).

---

## Утверждённое решение (архитектура фикса)

**Принцип:** разделить «явное» (выбор юзера → в конфиг, диагностируемо в `GET /config`) и «тень» (наши авто-докрутки → OverrideOptions, runtime-only, мимо снапшота/конфига).

```
tun_apps (storage, выбор юзера)  — backup_tun.dart
   │
   ├──► ЯВНОЕ: post-step → config            (как сейчас ✓, виден в GET /config, диагностируемо)
   │      tun_packages.dart
   │      allow → include_package = [список юзера]
   │      deny  → exclude_package = [список юзера]
   │
   └──► ТЕНЬ: → OverrideOptions               (runtime-only, daemon/instance.go:75-89 НЕ трогает profileContent)
          BoxService.kt:254 (старт) + :424 (reload)
          • self  → includePackage = [com.leadaxe.lxbox]   ⚠️ ТОЛЬКО allow
          • autoRedirect = <настройка>                     (root-only фича)
   │
   └─► сходятся в ядре: append (instance.go:84-85) → Android addAllowedApplication/addDisallowedApplication
```

**Что возвращаем в OverrideOptions:** `self` (per-app тень) + `autoRedirect`.

**Матрица (защита от краша):**

| Режим | config (явное) | OverrideOptions (тень) | append-результат | примечание |
|---|---|---|---|---|
| off | — | self: нет | full tunnel | |
| **allow** | `include_package=[юзер]` | `includePackage=[self]` | `include=[юзер, self]` ✅ | self в tun, protect уводит сокеты ядра |
| **deny** | `exclude_package=[юзер]` | **self: НЕ добавлять** ⛔ | `exclude=[юзер]` ✅ | в deny наш UID и так в tun; self не нужен |

> ⛔ **КРИТИЧНО — не класть self в override при deny.** Иначе после append в одном tun окажутся И `include_package` (self) И `exclude_package` (юзер) → Kotlin вызовет и `addAllowedApplication`, и `addDisallowedApplication` на одном `Builder` → **`UnsupportedOperationException` → краш VPN** (Android: «only allowed OR disallowed, not both»). `autoRedirect` от режима НЕ зависит — шлём всегда (по настройке).

**Почему так, а не «self прямо в include_package» (вар. A):** A загрязняет конфиг — в `GET /config`/snapshot не отличить юзерский выбор от нашей докрутки. OverrideOptions модифицирует только in-memory parsed options (`instance.go:75-89`), сохранённый конфиг чист. Юзерский приоритет = чистота конфига → тень в override.

**Почему юзерский список оставляем в конфиге (НЕ переносим весь per-app в override, т.е. не B2):** конфигурный путь явный и диагностируемый (виден в `GET /config`) — это ценно. Переносить незачем; разделяем по природе: явное в конфиг, тень в override. Это гибрид по дизайну (осознанный), не по случайности.

**autoRedirect:** root-only tproxy-фича (работает на рутированном Android — `redirect_linux.go:69,84`). Эталон пробрасывает, мы — нет. Возвращаем в OverrideOptions. Полноценная поддержка требует ещё UI-тоггл + `auto_route` (детали в разделе «ВТОРОЙ пропуск»). MVP: пробросить значение; UI — отдельно.

### Как Kotlin узнаёт режим (allow/deny) — РЕШЕНО

**Не прокидываем. Выводим из config'а, который Kotlin УЖЕ читает.**

Ключевой факт: `BoxService` грузит config сам через `ConfigManager.load()` (`BoxService.kt:232` старт, `:419` reload) — это полный JSON-строка с уже подставленными `include_package`/`exclude_package` (их пишет наш post-step). Режим **физически присутствует** в этих данных:
- tun имеет `include_package` → **allow** → кладём self в `OverrideOptions.includePackage`
- tun имеет `exclude_package` → **deny** → self НЕ трогаем
- ни того ни другого → **off** → self НЕ трогаем

```kotlin
// helper, общий для старта (:254) и reload (:424); config уже загружен ConfigManager.load()
val tun = findTunInbound(JSONObject(config))      // org.json — встроен в Android
if (tun?.has("include_package") == true) {
    includePackage = StringArray(listOf(applicationContext.packageName).iterator())  // self-тень, ТОЛЬКО allow
}
autoRedirect = <настройка>   // от режима НЕ зависит
```

**Почему это, а не MethodChannel/чтение storage:**
- **Единый источник истины** — режим = то, что реально в config'е. Нет второго канала → нет рассинхрона.
- **⛔-правило выполняется ПО КОНСТРУКЦИИ** — self кладётся ровно при `has("include_package")`. В deny этого поля в config'е нет → self физически не попадёт в deny → краш `UnsupportedOperationException` (include+exclude в одном tun) **исключён by design**, без отдельной проверки режима.
- MethodChannel создал бы 2 источника режима (config + аргумент) → риск рассинхрона = ровно тот краш-кейс. Отвергнут.
- Чтение Dart-storage из Kotlin — нарушает слои, хрупко. Отвергнут.

**Файлы под реализацию:**
- `BoxService.kt:254` + `:424` — наполнить `OverrideOptions` (self для allow + autoRedirect) через общий helper (DRY, два места); helper берёт `config`-строку аргументом, парсит, ищет tun-инбаунд.
- `packageName` — `applicationContext.packageName` (flavor-safe, без хардкода).
- `tun_packages.dart` — **НЕ трогаем** (юзерский список как есть).
- тест: self НЕ попадает в deny/off-путь (по `has(include_package)`).
- §046 spec.md:167 — поправить ложную посылку.

**Под-вопрос autoRedirect-настройки:** откуда Kotlin берёт значение autoRedirect — отдельный вопрос (нужен UI-тоггл + storage, как `allowBypass` в §069). MVP self-фикса может слать `autoRedirect = false` (текущее эффективное поведение), а root-поддержку autoRedirect делать отдельной таской. НЕ блокирует self.

---

## Версии (single source of truth)

| Что | Значение | Где |
|---|---|---|
| Пин ядра | `v1.13.13-lx.6` | `app/android/libbox.version`, `app/android/app/libs/.libbox.version` |
| Клон форка на диске | `v1.13.13-lx.7-2-gfc1db4d2` | `/Users/macbook/projects/sing-box-lx` (`git describe`) |
| sing-tun | `v0.8.10` | `sing-box-lx/go.mod`; кэш `~/go/pkg/mod/github.com/sagernet/sing-tun@v0.8.10` |
| upstream fix (CoolMask) | `1.13.0-rc.7` (~конец фев 2026) | [#3715](https://github.com/SagerNet/sing-box/issues/3715) |

**Эталон (SFA) на диске НЕТ.** Скачан в `/tmp/sfa_*.kt` через `gh api` (без sandbox) / jsdelivr с `SagerNet/sing-box-for-android@main`. github.com/api режутся **только в sandbox** — `dangerouslyDisableSandbox:true` обходит.

---

## Цепочка `include_package`: config → Android (подтверждено по исходникам)

```
tun_apps storage (lxbox_settings.json)
   { mode: off|allow|deny, packages: [...] }
        │  app/lib/services/builder/post_steps/tun_packages.dart:18-35
        ▼  allow → tun.include_package = packages   (as-is, БЕЗ self)
        ▼  deny  → tun.exclude_package = packages   (as-is, БЕЗ self)
   sing-box JSON config
        │  parseConfig
        ▼
   option.TunInboundOptions.IncludePackage   (option/tun.go:40)
        │  protocol/tun/inbound.go:198  IncludePackage: options.IncludePackage  (копия 1:1)
        ▼
   tun.Options.IncludePackage   (sing-tun tun.go:103)
        │  experimental/libbox/tun.go:139-141  GetIncludePackage(){ newIterator(o.IncludePackage) }  ← AS-IS, self НЕ добавляется
        ▼
   libbox TunOptions.includePackage  (JNI)
        │  BoxVpnService.kt:208-209  while(incl.hasNext()) builder.addAllowedApplication(incl.next())  ← self НЕ добавляется
        ▼
   VpnService.Builder  →  establish()  →  per-UID kernel whitelist
```

**Вывод цепочки:** на всём пути self-пакет (`com.leadaxe.lxbox`) **не добавляется нигде** — ни в Dart, ни в Go/libbox, ни в Kotlin. Подтверждено чтением каждого звена.

> `OverrideOptions` (альтернативный путь) **append'ит**, не заменяет: `daemon/instance.go:84-85` — `IncludePackage = append(tunInboundOptions.IncludePackage, overrideOptions.IncludePackage...)`. У нас `OverrideOptions()` пустой (`BoxService.kt:254` старт, `:424` reload).
> `sing-tun/tun_rules.go:22 BuildAndroidRules()` (package→UID) — это **root/non-VpnService** путь, для нашего VpnService-режима фильтрацию делает Android, не он. Тоже self не добавляет. `common.Uniq` на строках 52/72 → дубли self безопасны.

---

## Разница реализаций: два сквозных потока side-by-side

Главное различие — **где и в каком слое вычисляется и доставляется per-app список**. Это два разных конвейера, ведущих к одному и тому же `addAllowedApplication` в Android.

### Поток LxBox (per-app живёт в JSON-конфиге)

```
UI: TunAppsTab (3 режима off/allow/deny, picker)
   app/lib/screens/tun_apps_tab.dart
        ▼  setTunApps(cfg)
Storage: lxbox_settings.json → "tun_apps": {mode, packages}
   app/lib/services/settings_storage/backup_tun.dart  (TunAppsConfig)
        ▼  buildConfig() pipeline
Builder post-step: applyTunPackages()
   app/lib/services/builder/post_steps/tun_packages.dart:18-35
   allow → tun.include_package = packages          ← self НЕ добавляется
   deny  → tun.exclude_package = packages          ← self НЕ убирается
        ▼  пишется прямо в JSON профиля
sing-box config JSON  (per-app — ЧАСТЬ конфига)
        ▼  startService(content), OverrideOptions() ПУСТОЙ
   BoxService.kt:254 (старт) / :424 (reload)
        ▼  Go: config → option → tun.Options (как в цепочке выше)
        ▼  libbox TunOptions.includePackage (AS-IS)
Kotlin openTun: while(incl.hasNext()) addAllowedApplication(incl.next())
   BoxVpnService.kt:208-211                          ← self НЕ добавляется
        ▼
VpnService.Builder.establish()
```

### Поток SFA / эталон (per-app живёт в OverrideOptions, конфиг не трогается)

```
UI: PerAppProxy activity (+ managed/MDM mode)
        ▼
Storage: DataStore (НЕ в JSON-конфиге профиля)
   Settings.kt:78-82  perAppProxyEnabled / perAppProxyMode / perAppProxyList
   Settings.kt:88-97  getEffectivePerAppProxy{Mode,List}()  (managed override)
        ▼  при старте И при reload — ОДИНАКОВО:
OverrideOptions().apply {
   if (Vendor.isPerAppProxyAvailable() && Settings.perAppProxyEnabled) {
     appList = getEffectivePerAppProxyList()
     INCLUDE → includePackage = appList + packageName     ← +self ВСЕГДА
     EXCLUDE → excludePackage = appList − packageName     ← −self ВСЕГДА
   }
}
   старт BoxService.kt:138-148 / reload :220-227
        ▼  commandServer.startOrReloadService(content, overrideOptions)
        ▼  Go: daemon/instance.go:84-85  append(config.IncludePackage, override...)
           (конфиг профиля по include_package обычно ПУСТ → override = весь список)
        ▼  libbox TunOptions.includePackage
Kotlin openTun: while(...) addAllowedApplication(...)  (тот же код, что у нас)
   VPNService.kt:134-145
        ▼
VpnService.Builder.establish()
```

### Пофайловое соответствие слоёв

| Слой | LxBox | SFA (эталон) | Совпадает? |
|---|---|---|---|
| UI | `tun_apps_tab.dart` (вкладка в RoutingScreen) | PerAppProxy activity | разные, эквивалентны |
| Storage | `lxbox_settings.json` `tun_apps` (`backup_tun.dart`) | DataStore `perAppProxy*` (`Settings.kt:78-82`) | разные места |
| Managed/MDM режим | ❌ нет | ✅ `getEffective*` (`Settings.kt:88-97`) | **только у SFA** |
| Гейт «включено» | mode≠off && packages≠∅ (`tun_packages.dart:19`) | `Vendor.isPerAppProxyAvailable() && perAppProxyEnabled` | разные условия |
| Вычисление списка | post-step Dart, пишет в **config** | Kotlin, кладёт в **OverrideOptions** | **разные слои** |
| **self-инъекция** | ❌ отсутствует | ✅ `appList ± packageName`, старт+reload | **ключевое отличие** |
| Доставка в ядро | через JSON `include_package` | через `OverrideOptions` (append) | разные, обе валидны |
| Go-слияние | n/a (уже в конфиге) | `instance.go:84-85` append | — |
| libbox→Kotlin | `tun.go:139-141` AS-IS | то же | идентично |
| addAllowedApplication | `BoxVpnService.kt:208-211` | `VPNService.kt:134-145` | **код идентичен** (портирован) |
| protect(fd) | ✅ `BoxVpnService.kt:159-161` | ❌ PIW-дефолт пуст | **мы строже** |

**Суть различия одной фразой:** SFA держит per-app **оверлеем поверх конфига** (Kotlin/OverrideOptions, конфиг профиля чист) и **всегда подмешивает self**; LxBox **впечатывает per-app в сам конфиг** (Dart post-step) и **self не трогает**. Конвейеры разные, сходятся в одном `addAllowedApplication`. Оба способны на `±self` — отличие не в способе доставки, а в том, что мы шаг self **пропустили**.

---

## Таблица расхождений LxBox vs SFA

| # | Расхождение | SFA (эталон) | LxBox | К референсу? |
|---|---|---|---|---|
| 1 | **self-инъекция** | ✅ `include = appList + packageName`; `exclude = appList − packageName` — старт `BoxService.kt:142-148`, reload `:220-227` | ❌ нигде (`tun_packages.dart:33-34`, `BoxVpnService.kt:208-211`) | **ДА (поведенчески)** — реальный пробел |
| 2 | **где живёт per-app** | OverrideOptions (Kotlin), конфиг профиля не трогается; per-app в `Settings` DataStore (`Settings.kt:73-97`) | в JSON-конфиге (post-step §046) | **ПЕРЕСМОТРЕНО — см. ниже** «Критерий чистоты конфига». По поведению равноценно, но по наблюдаемости SFA чище. |
| 3 | **`protect(fd)`** | ❌ `autoDetectInterfaceControl(fd){}` ПУСТОЙ (`PlatformInterfaceWrapper.kt:32-33`, `VPNService.kt:50-52` зовёт protect но PIW-дефолт пуст) | ✅ `autoDetectInterfaceControl(fd){ protect(fd) }` (`BoxVpnService.kt:159-161`), `usePlatformAutoDetectInterfaceControl()=true` (`PlatformInterfaceWrapper.kt:27`) | **НЕТ** — мы строже, это страховка egress, оставляем |
| 4 | **findConnectionOwner try/catch** | ✅ обёрнут в try/catch+log+rethrow (`PlatformInterfaceWrapper.kt:49-67`) | ❌ без обёртки (`PlatformInterfaceWrapper.kt:36-60`) | мелочь, только диагностика — опционально |

**Итог:** требуется привести к референсу **поведение #1 (self-инъекция)**. КАК доставлять — см. раздел «Критерий чистоты конфига» (решение пересмотрено).

> ⚠️ §046 spec.md:167 содержит **ложную посылку**: «наш process сам не зависит от tun». Эталон считает иначе (`±packageName`). При фиксе #1 — поправить строку 167.

---

## Критерий чистоты конфига (РАЗВОРОТ решения по #2)

> Изначально (выше) я писал «механизм OverrideOptions возвращать не нужно, равноценно». **Это было верно только по критерию ПОВЕДЕНИЯ** (доходит ли трафик). Юзер ввёл другой критерий — **наблюдаемость / чистота конфига**, и по нему вывод обратный.

**Претензия юзера (верная):** если впечатать self прямо в `include_package`, то в сохранённом/отдаваемом конфиге **нельзя отличить** выбор юзера от нашей докрутки — `["org.telegram.messenger","com.leadaxe.lxbox"]` без признака, кто что положил.

**Где конфиг наблюдаем:** Debug API `GET /config` + `/config/pretty` (`config.dart:25-26`), snapshot `lxbox-diag.sh`, ручная отладка JSON.

**Ключевой факт (Go):** `OverrideOptions` модифицирует **только in-memory parsed `options`**, НЕ `profileContent` — `daemon/instance.go:75-89` (`parseConfig(profileContent)` → override append-ит в `options`, файл не трогается). Значит self через OverrideOptions = **виден только в рантайме ядра, в сохранённом конфиге его нет**. Это ровно «чистый конфиг».

**Round-trip:** сейчас риска нет — конфиг обратно НЕ парсим, источник правды = `tun_apps` storage (`backup_tun.dart`), Debug API читает storage не конфиг. Но self в `include_package` — мина на будущее (если начнём парсить).

| Критерий | self в `include_package` (вар. A) | self через OverrideOptions (вар. B) |
|---|---|---|
| Поведение (egress) | ✅ | ✅ |
| Конфиг на диске / `GET /config` / snapshot | загрязнён | **чист — только юзерское** |
| Отличить наше от юзерского | ❌ | ✅ |
| Round-trip мина | есть | нет |

**Приоритет юзера = чистота конфига → правильный путь B (OverrideOptions).** Объём НЕ решён:
- **B1:** только self через OverrideOptions, юзерский список остаётся в конфиге. Конфиг чист в allow-сценарии. `deny−self` через append НЕ решается (append только добавляет, `instance.go:84-85`) — но это редкий патологичный кейс (юзер сам внёс LxBox в exclude), protect подстрахует. Дёшево, но гибрид (per-app в двух местах).
- **B2:** весь per-app → OverrideOptions (как эталон), post-step `applyTunPackages` удаляется, storage остаётся. Конфиг чист ВСЕГДА (и deny). `−self` работает. Дорого — переписать доставку §046.

**Статус:** объём (B1 vs B2) за юзером. Поведенческая часть (#1 self) и критерий (чистый конфиг → B) — зафиксированы.

---

## ВТОРОЙ пропуск в OverrideOptions: `autoRedirect` (root-only фича)

Наш `OverrideOptions()` пустой → мы НЕ шлём `autoRedirect`. Эталон шлёт: `OverrideOptions().apply { autoRedirect = Settings.autoRedirect }` (`BoxService.kt:139`, дефолт false).

**Что это:** Linux tproxy-перенаправление через nftables/iptables (firewall-уровень вместо gVisor-стека) — для bypass-by-routing-rule, быстрее userspace-стека.

**КРИТИЧНО — работает ли на Android:** ✅ **ДА, на рутированном Android.** (Сначала был ошибочный вывод «нет, stub» — НЕВЕРНО.)
- Авторитетная проверка: `GOOS=android GOARCH=arm64 go list -f '{{.GoFiles}}' github.com/sagernet/sing-tun` → компилируются `redirect_iptables.go`, `redirect_nftables.go`, `redirect_linux.go` — **те же, что для linux**. `redirect_stub.go` (`//go:build !linux`) в android-сборку НЕ попадает: в Go тулчейне `GOOS=android` удовлетворяет build-constraint `linux`.
- Android-специфика прямо в коде: `redirect_linux.go:69` → `/system/bin/iptables` (андроидный путь).
- **root обязателен:** `redirect_linux.go:84` → `"root permission is required for auto redirect"` (ищет `su`). Без root → ошибка.
- Доп. условия: `auto_route` обязателен (`inbound.go:223`); ветка `if !C.IsAndroid` (`inbound.go:243`) пропускает mark-mode на Android, но НЕ отключает фичу.
- changelog: «This feature requires Linux with auto_redirect enabled» — Android = Linux-kernel → подпадает.

**Вывод:**
- Не-root юзеры (большинство): auto_redirect неприменим (нет `su` → ошибка) → пустой OverrideOptions для них корректен.
- **Root-юзеры (существуют!):** это РАБОЧАЯ фича, которую мы НЕ пробрасываем → **реальный пропущенный функционал**, не «нерелевантный параметр».

**Статус:** ✅ **проброс реализован** (2026-06-14). `BootReceiver.isAutoRedirect`/`setAutoRedirect` (persistent-флаг `auto_redirect`, default false, зеркало `allowBypass`); helper `buildOverrideOptions` шлёт `options.autoRedirect = BootReceiver.isAutoRedirect(service)`. **UI-тоггла пока НЕТ** — флаг управляется через prefs/adb; default false безопасен (на не-root ядро вернёт ошибку). Остаётся отдельной таской: UI-тоггл + `auto_route`-зависимость + девайс-тест на рутованном.

---

## Реализация (что сделано) — 2026-06-14

**self-инъекция реализована.** Файл `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt`:

- Новый helper `buildOverrideOptions(config: String): OverrideOptions` — парсит config (`org.json.JSONObject`), ищет tun-инбаунд, и если в нём есть `include_package` (= allow-режим) → кладёт `service.packageName` в `OverrideOptions.includePackage` через `singleStringIterator`. В deny/off self НЕ кладётся (поля `include_package` нет → `has()` = false).
- `singleStringIterator(value)` — минимальный `StringIterator` на 1 элемент (`hasNext`/`len`/`next`). Сигнатура сверена с libbox.aar (`javap`).
- Подключён в обоих call-site: старт `cs.startOrReloadService(config, buildOverrideOptions(config))` (бывш. `:254`) + reload (бывш. `:424`). Раньше там был пустой `OverrideOptions()`.
- `autoRedirect` оставлен дефолтным (`false`) — эквивалентно прежнему пустому `OverrideOptions()`, без регрессии. Проброс root-значения — отдельная таска.
- `packageName` = `service.packageName` (динамически, flavor-safe, без хардкода).
- `tun_packages.dart` НЕ тронут — юзерский список как был, конфиг чист.

**Верификация:**
- ✅ `./gradlew :app:compileDebugKotlin` — EXIT 0 (типы/импорты/синтаксис сходятся).
- ✅ Сигнатуры `StringIterator`/`OverrideOptions` сверены с реальным `libbox.aar` через `javap`.
- ⚠️ **Юнит-тест НЕ добавлен** — в проекте НЕТ Kotlin-тест-инфраструктуры (`src/test`, `testImplementation`, JUnit отсутствуют; вся тестируемая логика на Dart). Заводить ради одного теста несоразмерно. Логику «self только в allow» защищает конструкция (`has("include_package")`), не тест.
- ✅ **Девайс-смок ПРОЙДЕН** — OnePlus CPH2411 (Android 15), vc=2542, USB, через Debug API, 2026-06-14:
  1. **allow** (1 приложение `org.telegram.messenger`) → VPN поднялся (`tun0 UP`); монитор logcat поймал live:
     `D BoxService: [vpn] override: +self (com.leadaxe.lxbox) — allow-mode` ✅ — **helper сработал, self долетел в ядро через OverrideOptions**.
  2. `GET /config` (allow) → `include_package = ['org.telegram.messenger']`, `com.leadaxe.lxbox` **ОТСУТСТВУЕТ** в файле ✅ — тень мимо снапшота, как задумано.
  3. **deny** (3 юзерских пакета) → VPN поднялся, краша `UnsupportedOperationException` **НЕТ** ✅; `GET /config` → `exclude_package` = только юзерские, self НИ в include НИ в exclude ✅.
  - Исходная конфигурация юзера (deny+3) восстановлена после теста.
  - НЕ проверено: репро на самих Samsung-репортёрах (нет их устройств) — механика подтверждена на нашем. Если у них не чинит → корень в lockdown/SDK (см. открытые вопросы), не в self.

---

## Матрица взаимодействия (allowBypass × self × protect → egress ядра)

Подтверждено workflow `wbgstdou1` (8 агентов, 3 adversarial-скептика — все `holds:true`). «works/broken» = доходит ли трафик ядра sing-box до прокси-сервера.

| allowBypass | self в allow-list | наш protect | egress ядра | примечание |
|:-:|:-:|:-:|---|---|
| off | no | **yes** | ✅ works | **дефолт LxBox.** Спасён ДВАЖДЫ: UID вне whitelist ⇒ «as if VPN off» + protect(fd). |
| off | no | no | ✅ works* | теоретич. (protect у нас всегда on); UID вне whitelist и так вне tun |
| off | **yes** | **yes** | ✅ works | self в tun, но protect уводит сокеты ядра — **ради этого protect и есть** |
| off | yes | no | ❌ broken | self в tun + нет bypass ⇒ circular/loopback. **У нас недостижимо** (self не кладём, protect on) |
| on | no | yes | ✅ works | allowBypass=on НИЧЕГО не меняет для ядра (ядро не зовёт bindProcessToNetwork) |
| on | yes | yes | ✅ works | allowBypass для ядра избыточен |
| on | yes | no | ⚠️ likely broken | allowBypass=on даёт *право*, но без явного bind не спасает. Доказывает: **allowBypass ≠ protect** |

**Ключевые инварианты:**
- `bindProcessToNetwork` = **0 вызовов** в LxBox-core И в SFA (grep). Единственный реальный bypass egress ядра = **`protect(fd)`**.
- В Go-ядре слово `allowBypass` = **0 совпадений** — это чисто Android-Builder флаг, ядром не читается.
- `protect(fd)` per-socket, **безусловен** (без guard по allowBypass): `BoxVpnService.kt:159-161`. Цепочка Go: `common/dialer/default.go:116 ProtectFunc()` → `route/network.go:368-377` → `AutoDetectInterfaceControl(fd)` → Kotlin protect. (Скептик: для Android берётся `ProtectFunc`, не `AutoDetectInterfaceFunc`/`:340-346` — это близнец из ветки `platformInterface==nil`; результат идентичен.)

---

## Прямые ответы (то, что выясняли)

**Q: «влияет ли self-фикс на Allow VPN Bypass?»**
НЕТ. Ортогональны. allowBypass = *право СТОРОННИХ приложений* добровольно обойти tun через bindProcessToNetwork. self-фикс = маршрут *СОБСТВЕННОГО UID*. Разные субъекты, пустое пересечение. self-фикс не обессмыслит allowBypass (тот про трафик, до которого ни protect, ни include/exclude не дотягиваются). Оговорка: ортогональность **условна** — держится на факте «никто не зовёт bindProcessToNetwork»; если LxBox когда-нибудь сам вызовет — инвариант сломается.

**Q: избыточность есть?**
Между **self-фиксом и protect(fd)** — да, частичная. protect спасает ТОЛЬКО сокеты go-dialer'а ядра. НЕ спасает трафик собственного Android-процесса мимо sing-box (OS-соединения процесса, telemetry). Вот эту узкую щель закрывает self (отсутствие нашего UID в tun). Между **self и allowBypass** избыточности НЕТ.

**Q: «почему у меня работает, а у части — нет?»**
В дефолте egress ядра прикрыт дважды → drop не из-за отсутствия self. self-фикс функц. нужен ТОЛЬКО в узком сценарии: allow + юзер ВРУЧНУЮ добавил LxBox в свой whitelist + ломается не-dialer трафик. «Ручное добавление чинит на Samsung» — факт, но механизм может быть тоньше (см. ниже).

---

## Открытые вопросы (проверять на устройстве через `lxbox-diag.sh`)

1. **lockdown / always-on VPN** (наиболее вероятный корень): при нём UID вне whitelist может **дропаться** отдельной Android-политикой поверх tun (не следствие addAllowedApplication). Protected-сокеты могут/не могут быть исключением — **официальный javadoc не фиксирует**, зависит от версии/прошивки. Это объяснило бы и «Samsung», и «у части».
2. **SDK-различия 12/13:** `addRoute`/`excludeRoute`/UID-range ветвятся по `Build.VERSION_CODES.TIRAMISU` (`BoxVpnService.kt:188`). До/после 13 поведение могло отличаться.
3. **Не теряется ли self именно у тех, кто сам добавил LxBox в allow-список** — единственный сценарий, где self-фикс реально функционален.
4. Делает ли core доп. self-exclude вне Android Builder — **не верифицировано** (предполагается нет; SFA делает в Kotlin, не в core).

---

## Что НЕ делать (из памяти/правил)

- Первое действие при репро бага = `./scripts/lxbox-diag.sh` (snapshot), НЕ reset/reload/restart (уничтожает evidence) — [feedback_no_destructive_diagnostics].
- ~~НЕ переезжать per-app на OverrideOptions — равноценно~~ → **ПЕРЕСМОТРЕНО:** по критерию чистоты конфига OverrideOptions правильнее (см. раздел «Критерий чистоты конфига»). Объём B1/B2 за юзером.
- НЕ убирать наш `protect(fd)` ради паритета (#3) — мы намеренно строже эталона.
- При self-фиксе (#1): только include — добавлять self; для deny — убирать self; НЕ хардкодить если есть flavor'ы с разными applicationId.

---

## Решение по реализации (за юзером)

- **(а)** self-фикс (#1) сейчас как паритет+defense-in-depth (заведомо безопасен — ортогонален allowBypass). Правка `tun_packages.dart` + тест + поправить §046:167.
- **(б)** сначала диагностика на устройстве (lockdown/SDK), потом фикс — чтобы не выдать паритет за лечение бага.
- Рекомендация: **(б) → (а)**.
