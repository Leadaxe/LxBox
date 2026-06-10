# 109 — Tunnel apps: установленные приложения помечаются «uninstalled, auto-skipped»

| Поле | Значение |
|------|----------|
| Статус | In progress — код и тесты готовы, девайс-smoke pending (телефон offline) |
| Дата старта | 2026-06-10 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/046 (tunnel apps), features/044 (AppInfoCache унификация), tasks/060 (getAppInfo typed wrapper) |

## Проблема

Field report (4PDA, v2.0.x): на табе Routing → Tunnel apps часть приложений
помечена `<pkg> — uninstalled, auto-skipped`, хотя они установлены и
работают (репортер сидел в `ru.fourpda.client` в момент скриншота).
Не воспроизводится на тестовом устройстве — один репорт.

User-impact двойной:

1. Ложная метка пугает и провоцирует «чинить» рабочую конфигурацию.
2. Текст «auto-skipped» внушает, что приложение выпало из туннеля, и
   уводит диагностику реальных сетевых проблем в ложный след (у репортера
   реальная проблема — трафик 4PDA мимо туннеля — имеет другую причину).

## Диагностика

Root cause подтверждён построчным чтением, без устройства:

1. UI-условие метки — `info == null && _ensured.contains(pkg)`
   (`tun_apps_tab.dart:332`). Оно не различает три состояния: «ещё
   грузится», «проверка сорвалась» и «реально удалён».
2. `BoxVpnClient.getAppInfo` возвращал `null` и при честном «не
   установлено», и при **timeout 5s** (`onTimeoutValue: null`,
   `box_vpn_client.dart:293`, `timeouts.dart:37`).
3. `AppInfoCache._fetch` писал `null` в кэш ещё и на **любом exception**
   (`app_info_cache.dart:108-109`), а контракт кэша — «null = не
   установлено, повторно не дёргаем» (`ensure`, case 2). Одна неудача =
   метка до конца сессии, без ретраев.
4. Усилитель: при открытии таба `ensure()` стреляет по всему списку
   разом (fire-and-forget), а native-хендлеры сериализуются на main
   thread, и каждый `getAppInfo` тащил PNG-encode иконки. Таймаут у всех
   тикает от момента вызова → хвост очереди выбивается за общий
   5-секундный бюджет на медленном девайсе / длинном списке / занятом
   main thread (например, таб открыт сразу после холодного старта).

Скриншот репортера сходится с теорией очереди: в порядке обстрела
(список хранится отсортированным по package name, `tun_apps_tab.dart:95`)
`cc.relive…` и `ch.protonmail…` успели, а хвост
`proton.android.authenticator` / `proton.android.pass` /
`ru.fourpda.client` — помечен.

Почему метка **косметическая**: builder кладёт в конфиг весь список без
фильтрации по кэшу (`tun_packages.dart:34`), native добавляет пакеты в
tun через реальный PackageManager и скипает только настоящий
`NameNotFoundException` (`BoxVpnService.kt:209`). `QUERY_ALL_PACKAGES`
в манифесте с v1.1.1.

Ложные следы: root / скрытие приложений / package visibility —
не требуются и не при чём; вся гонка внутри нашего процесса.

## Решение

Три слоя, контракт «not found ≠ не удалось проверить» прокинут насквозь:

1. **Native** (`VpnPlugin.kt`, `getAppInfo`):
   - ловим только `PackageManager.NameNotFoundException` → отвечаем
     явным маркером `{"notFound": true}`;
   - прочие исключения → `result.error("APP_INFO_ERROR", …)` — Dart
     трактует как retryable;
   - иконка из ответа **убрана** (метаданные ~мгновенные; иконку UI и
     так умеет дотягивать отдельным `getAppIcon`) — это устраняет сам
     источник таймаутов, PNG-encode больше не сериализует очередь.
2. **`BoxVpnClient.getAppInfo`**: timeout больше не маскируется под
   null — маркерное `onTimeoutValue` конвертится в `TimeoutException`.
   Семантика: `AppInfo` = установлен; `null` = **подтверждённый**
   not-found; throw = не удалось проверить (retryable).
3. **`AppInfoCache`**:
   - `_cache[pkg] == null` теперь означает только подтверждённый
     not-found; сорвавшаяся проверка ничего не кэширует;
   - retry с нарастающей задержкой (2s / 5s / 15s, max 3 попытки на
     сессию; ручной `ensure()` после исчерпания даёт ещё попытку);
   - после успешных метаданных иконка дотягивается вторым вызовом
     (`getAppIcon`) — имя появляется сразу, иконка следом;
   - новый `isNotFound(pkg)` для UI; `resetForTest()` для тестов.
4. **UI** (`tun_apps_tab.dart`): метка «uninstalled, auto-skipped»
   показывается только при `AppInfoCache.isNotFound(pkg)`. Состояния
   «грузится» / «не удалось проверить» рендерятся как обычный tile без
   метки. Set `_ensured` удалён (жил только ради старого условия).

Текст «auto-skipped» оставлен: для подтверждённо удалённого пакета он
корректен (native скипает его в `addAllowedApplication`).

## Риски и edge cases

- `loadAllApps()` (открытие любого app-picker'а) перезаписывает записи
  кэша и «лечит» хвосты — поведение прежнее, осознанно сохранено.
- Намеренно НЕ покрыто: репортерская проблема «4PDA мимо туннеля» — это
  отдельный кейс (вероятно, Deny-list mode или порядок routing-правил),
  ждём ответов с форума.
- Старые билды native + новый Dart невозможны (шипятся вместе), маркер
  `notFound` несовместимости не создаёт.
- Если native-ответ внезапно `null` (нарушение контракта) — трактуем
  как retryable, не как «удалён».

## Верификация

- Unit: `test/services/app_info_cache_test.dart` (новый) — not-found
  кэшируется без ретраев; metadata + икон-цепочка; timeout/ошибка канала
  не дают метку и ретраятся; исчерпание ретраев = unknown; ручной
  `ensure()` после исчерпания пробует снова. ✅
- Unit: `test/vpn/box_vpn_client_test.dart` — контракт `getAppInfo`
  (notFound→null, metadata→AppInfo, timeout→TimeoutException,
  PlatformException пробрасывается). ✅
- `flutter analyze` чистый, полный `flutter test` — 926 passed. ✅
- Release arm64 APK собран локально (build-local-apk.sh). ✅
- Smoke на устройстве: таб Tunnel apps — установленные приложения без
  меток, иконки подгружаются; реально удалённый пакет в списке — с меткой.
  **Pending** — тестовый телефон offline (wifi-adb не отвечает, USB не
  подключён); поставить через `./scripts/install-apk.sh` когда появится.

## Нерешённое / follow-up

- Сетевой кейс репортера (трафик 4PDA мимо туннеля) — отдельная
  диагностика после ответов: режим таба (Allow/Deny), порядок правил,
  экспорт конфига.
- Идея на потом: батч-вариант `getAppInfoBatch(packages)` одним
  round-trip'ом — сейчас не нужен (метаданные стали дешёвыми).
