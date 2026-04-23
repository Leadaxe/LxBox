# 036 — Update check (GitHub Releases)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-04-23 |
| Зависимости | [`022 app settings`](../022%20app%20settings/spec.md), [`027 subscription auto update`](../027%20subscription%20auto%20update/spec.md) (паттерны spam-gate) |
| Лэндинг | v1.5.0 |

---

## Цель

Юзер sideload'ит APK с GitHub Releases — нет Play Store auto-update. Он не знает что вышла новая версия пока не зайдёт на GitHub руками. В результате:
- Live баги в старых версиях не получают фикс'ы.
- Security-фиксы (URL leak, broken DPI bypass) не применяются.
- Юзеры ловят стабилизированные баги «ой, у нас это уже починено в 1.4.x».

Цель — **тактично уведомлять** о новой версии. Не auto-install (sideload-флоу + INSTALL_PACKAGES permission = слишком много трения), а snackbar / banner + ссылка на release page. Юзер решает когда обновляться.

### Не в скопе

- **Auto-install APK** (`REQUEST_INSTALL_PACKAGES` + content provider). Слишком много поверхности атаки и user-friction. Юзер в браузере → скачивает APK → устанавливает руками — стандартный sideload flow.
- **Play Store** или F-Droid integration. Будет позже отдельной спекой.
- **Beta / nightly канал**. Только stable releases.
- **Forced upgrade** (block app пока не обновишься). VPN — критичный tool, никогда не блокировать запуск.
- **Background fetch когда app свёрнут**. Только on launch.

---

## Архитектура

### Lifecycle

```
App launch
  ├─ HomeController.init() финиширует
  ├─ (после 5s, чтобы не мешать запуску VPN)
  ├─ UpdateChecker.maybeCheck()
  │   ├─ if !auto_check_updates → skip (юзер выключил)
  │   ├─ if last_update_check_at <24h → skip (cap)
  │   ├─ if not on wifi/cellular → skip (offline)
  │   ├─ GET https://api.github.com/repos/Leadaxe/LxBox/releases/latest
  │   ├─ parse `tag_name` → semver compare с _version
  │   └─ if newer → emit notification event
  └─ HomeScreen subscribes → показывает SnackBar
       "L×Box v1.4.3 available · [View] [Dismiss]"
```

### Триггеры

- **Auto on launch** (default ON): через 5 сек после `HomeController.init`. 24h cap.
- **Manual** в About screen: кнопка «Check for updates» — bypass cap, force-fetch.
- **Manual в Update settings** (если выделим в App Settings → Updates): то же что в About.

### Throttling и spam-gates (учтены инварианты §027)

| Gate | Значение | Где |
|------|----------|-----|
| `auto_check_updates` toggle | `true` default | `SettingsStorage.vars['auto_check_updates']` |
| `last_update_check_at` | ISO timestamp | `SettingsStorage.vars` |
| `min_check_interval` | **24h** | const |
| `last_known_version` | например `"v1.4.2"` | `SettingsStorage.vars` (cache → не дёргать GitHub после ребута) |
| `dismissed_version` | `"v1.4.3"` если юзер dismiss'нул баннер для этой версии | `SettingsStorage.vars` |
| Manual button → force | bypass cap+dismissed | UI |

Network failure (offline / rate-limit / 500) — silently skip, лог в AppLog. Никаких retry-loop'ов. Следующий launch — следующая попытка.

### Network — primary + fallback

**Primary**: `GET https://api.github.com/repos/Leadaxe/LxBox/releases/latest`. Возвращает canonical JSON с `tag_name`, `name`, `html_url`, `published_at`, `body`.

```jsonc
{
  "tag_name": "v1.5.0",
  "name": "L×Box v1.5.0",
  "html_url": "https://github.com/Leadaxe/LxBox/releases/tag/v1.5.0",
  "published_at": "2026-04-23T14:00:00Z",
  "body": "..."  // markdown release notes (опционально для preview)
}
```

**Fallback**: `GET https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/latest.json`. Используется когда primary даёт 4xx/5xx/timeout/network error. CDN-кэширован GitHub'ом — anti-abuse намного лояльнее API.

```jsonc
// own schema, контролируем сами; обновляется CI'ем при каждом release tag push
{
  "tag": "v1.5.0",
  "name": "L×Box v1.5.0",
  "published_at": "2026-04-23T14:00:00Z",
  "html_url": "https://github.com/Leadaxe/LxBox/releases/tag/v1.5.0",
  "apk_url": "https://github.com/Leadaxe/LxBox/releases/download/v1.5.0/LxBox-v1.5.0.apk",
  "min_supported": "1.0.0"
}
```

**Зачем fallback**:
- Анонимный rate-limit api.github.com — **60 req/h на IP**.
- Юзер сидит на VPN; trafic выходит через **shared exit IP** провайдера (Финляндия, Нидерланды, и т.п.).
- Этот IP делят сотни подписчиков, каждый из них может делать запросы к GitHub API (другие apps, скрипты, бэкап-тулзы).
- 60 req/h на shared IP исчерпывается **за минуты** → 403 на легитимные запросы у всех на этом exit'е.
- `raw.githubusercontent.com` сервит статические файлы из CDN — лимит на запросы у конкретного файла существенно лояльнее (фактически unlimited для small JSON').

**Без auth** — оба endpoint'а public.
**User-Agent**: `LxBox/1.x` (статичный — не утекаем точную версию).
**Schema мы контролируем** в `docs/latest.json` — можем добавить `min_supported`, urgent flag, и т.п. без дёрганий GitHub schema.

### CI integration

`.github/workflows/ci.yml` job `publish-manifest` (запускается после `release` job, gated на `is_release == true`):
1. Checkout `main` с write-доступом.
2. Генерит свежий `docs/latest.json` с tag/version/timestamp/URL'ами.
3. `git commit` с suffix'ом `[skip ci]` (чтобы не триггерить новый CI run на собственный коммит) → `git push origin HEAD:main`.

В результате `https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/latest.json` обновляется автоматически в течение ~30 сек после того как release появился на GitHub.

### Comparison logic

```dart
bool isNewer(String remote, String local) {
  // Strip 'v' prefix; split on '.'; compare numeric per part.
  // remote="v1.4.3", local="1.4.2" → true (3>2)
  // remote="v1.4.3", local="1.4.3" → false (equal)
  // Anything malformed → false (don't notify on bad data)
}
```

Pre-release / draft (когда `tag_name` содержит `-rc1`, `-beta`) — игнорируем (используем `/latest` который и так возвращает только stable).

### Hidden version compare

`local` = `_version` const из `about_screen.dart` (single source of truth). Не из pubspec — он не доступен в runtime без `package_info_plus` package. `_version` уже используется в About → переиспользуем.

---

## UI

### SnackBar (главный disclosure-канал)

После `init()` через 5s, если `isNewer`:

```
┌──────────────────────────────────────────────────┐
│  ↑ L×Box v1.4.3 доступна (у вас v1.4.2)          │
│                              [View]  [Не сейчас] │
└──────────────────────────────────────────────────┘
```

Кнопки:
- **View** — `url_launcher`-аем `html_url` (страница релиза). После этого на устройстве: юзер качает APK и устанавливает.
- **Не сейчас** — записывает `dismissed_version=v1.4.3`, snackbar исчезает. Не показываем для этой версии до следующего релиза.

Snackbar НЕ показывается:
- Если уже был для этой версии в этой сессии.
- Если для этой версии установлен `dismissed_version`.
- Если juser сейчас в setup-flow (нет ни одной подписки) — фокус on getting started, не отвлекать.

### About screen

Под текущей версией добавляется блок:

```
Current version: v1.4.2 (build 10)
[Local build · 0 commits since v1.4.2]   ← если local

Latest available: v1.4.3                  ← если auto-check выключен / нет данных: "[Check for updates]"
              Released 2 days ago
              [View release]              ← открывает html_url
```

Если `local == latest` → «You're up to date ✓».
Если `last_update_check_at` пуст или старше 24h и auto-off → «Last check: never · [Check now]».

### App Settings

Новая мини-секция «Updates» (in General tab или после Subscriptions section):

```
Updates
  Check for updates on launch  [☑]
  Last check: 2h ago
  [Check now]
```

`[Check now]` → forced check + сразу snackbar / about-update.

### Disclosure

Toggle default ON. **Single-line disclosure под toggle** — «Pings github.com once a day to check for new releases». Юзер знает что app дёргает наружу.

Memory rule `feedback_no_unplanned_autoupdates` (изначально про SRS) — здесь expectations задокументированы: 1 запрос в сутки на латест-релиз = explicit disclosure + opt-out toggle.

---

## Storage keys (`SettingsStorage.vars`)

| Ключ | Тип | Default | Назначение |
|------|-----|---------|-----------|
| `auto_check_updates` | String | `"true"` | Toggle |
| `last_update_check_at` | String (ISO) | `""` | Throttle (24h cap) |
| `last_known_version` | String | `""` | Cached latest tag, чтобы snackbar показывать сразу при следующем запуске без сетевого запроса |
| `dismissed_version` | String | `""` | Юзер сказал «Не сейчас» для этого тега |

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `lib/services/update_checker.dart` | Singleton: `maybeCheck()`, `forceCheck()`, `latestKnown()`, `dismiss(tag)`. Парсит GitHub API, semver compare, throttle. |
| `lib/services/settings_storage.dart` | Keys + getters/setters: `getAutoCheckUpdates`, `getLastUpdateCheck`, `getLastKnownVersion`, `getDismissedVersion`. |
| `lib/screens/home_screen.dart` | После `init()` через 5s: вызывает `UpdateChecker.maybeCheck()`. SnackBar handler. |
| `lib/screens/about_screen.dart` | Блок «Latest available» + кнопка `Check now`. |
| `lib/screens/app_settings_screen.dart` | Добавить «Updates» секцию в General tab. |
| `test/services/update_checker_test.dart` | semver compare unit-тесты + throttle / dismissed-version logic. Без сетевых запросов (моки). |
| `docs/spec/features/036 update check/spec.md` | Этот файл. |

Pure-function `isNewer(remote, local)` + `shouldNotify(latest, dismissed, lastShown)` — testable в изоляции, без сетевых mock'ов.

---

## Acceptance

- [ ] Через 5s после launch'а, при `auto_check_updates=true` и валидной сети — `GET /releases/latest` уходит на github.com.
- [ ] `last_update_check_at` сохраняется после успеха.
- [ ] Повторный launch в течение 24h — без сетевого запроса (видно по логам / network monitor).
- [ ] Если `tag_name` newer → SnackBar с двумя кнопками. View → открывает `html_url` в браузере.
- [ ] «Не сейчас» → `dismissed_version` set; SnackBar не появляется до следующего релиза.
- [ ] Manual `Check now` в About / Settings → bypass cap, fetch немедленно.
- [ ] Toggle OFF → ни на launch, ни автоматически нигде не дёргаемся к github.com. Manual всё равно работает.
- [ ] Network fail (offline, rate-limit, 5xx) — silent skip + AppLog warning.
- [ ] About screen показывает «Latest available» + age + кнопку View.
- [ ] App Settings General → секция Updates с toggle + last-check + manual button.
- [ ] Тесты `update_checker_test.dart` покрывают: semver compare, 24h cap, dismissed-version skip, malformed-input return false.

---

## Риски и mitigation

| Риск | Mitigation |
|------|-----------|
| GitHub rate-limit (60/h) при популярном app'е с миллионами установок | 24h cap per user → реальная нагрузка <<60/h global. Если когда-то нужна шкала — переключиться на CDN-cached endpoint (e.g. через GitHub Pages-published `latest.json`). |
| `tag_name` нестандартный (`v1.4.3-rc1`, без `v` prefix) | Semver-compare returns false for malformed → не уведомляем. Лог warning. |
| Юзер в РФ, github.com блокируется ISP | Fallback: skip silently, не назойливые retry'ы. Опционально (next iteration) — fetch через активный VPN tunnel'ent если он up. |
| Spam-banner после dismiss-каскада новых релизов | `dismissed_version` per tag, не «не показывать никогда». Каждый новый релиз — новый shot. Юзер dismiss'нул `1.4.3`, релизнули `1.4.4` → банер показывается заново. |
| Auto-check ломает offline-first сценарий | 5s delay + skip при offline. Не блокирует UI thread, не задерживает HomeScreen render. |
| Privacy concern «приложение пингует google» | Сразу под toggle disclosure: «Pings github.com once a day». Юзер может выключить в один тап. |
| Local builds показывают «update available» при старшей версии | `_version` = `1.4.2`, latest `v1.4.2` → не newer → ok. Local build с suffix вроде `1.4.3-dirty` → мы парсим только числовые `1.4.3` → ok. |

---

## Out of scope / future iterations

- **In-app APK download + install** через `REQUEST_INSTALL_PACKAGES`. Большая работа на native-сторону, отдельный spec если будет нужно.
- **Selectable update channel** (stable / beta / nightly). Сейчас только stable через `/releases/latest`.
- **Release notes preview** в диалоге перед View — markdown render внутри app'а. Откладываем; release page в браузере содержит то же.
- **Update via tunnel** — для юзеров где github.com ISP-blocked: `download_detour` через активную VPN-группу. Требует осторожной интеграции с tunnel lifecycle.
- **Notification (system tray)** при доступности обновления — только если app не запущен. Foreground service уже есть, можно прикрутить, но spam-риск.
