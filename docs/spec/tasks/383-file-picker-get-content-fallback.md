# §383 — Импорт файла: сторонний менеджер отвечает только на GET_CONTENT

| Поле | Значение |
|------|----------|
| Статус | Done (код), PENDING-DEVICE на реальном 7.1.1 |
| Дата старта | 2026-08-06 |
| Дата завершения | 2026-08-06 |
| Коммиты | не закоммичено — по команде юзера |
| Связанные spec'ы | [§372](372-android-tv-support.md) — детект пикера, которому эта таска чинит ложно-отрицательный случай |

## Проблема

Пользователь 4PDA (Android TV, 7.1.1 / API 25), продолжение репорта из
[§372](372-android-tv-support.md):

> пишет что на этом устройстве нет файлового менеджера
>
> хотя стоит тотал коммандер

До §372 кнопка импорта была немой («ничего не происходит»). После §372
симптом сменился: приложение показывает подсказку `noFileManager` —
детект честно отработал, но **дал ложное «нет менеджера» при
установленном файловом менеджере**.

User-impact: импорт конфига из файла недоступен в принципе. Обходные пути
(буфер обмена, импорт по URL) в подсказке названы и работают, но сам
сценарий «взять файл с диска» закрыт.

## Диагностика

### `hasRealFilePicker` спрашивает только про OPEN_DOCUMENT

[`MainActivity.kt:313`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)
(введён §372):

```kotlin
val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
    .addCategory(Intent.CATEGORY_OPENABLE)
    .setType("*/*")
val candidates = packageManager.queryIntentActivities(intent, 0)
return candidates.any { !isStubHandler(it.activityInfo?.packageName) }
```

`ACTION_OPEN_DOCUMENT` — часть SAF (Storage Access Framework, API 19+).
Регистрироваться на него обязаны **DocumentsProvider**-приложения; обычные
файловые менеджеры старой школы (Total Commander и аналоги, массово
распространённые на 7.x) объявляют себя обработчиками
`ACTION_GET_CONTENT` и на `OPEN_DOCUMENT` не отвечают.

Итог на устройстве пользователя: у `OPEN_DOCUMENT` реальных кандидатов
нет (на TV — только `frameworkpackagestubs`, который §372 корректно
отбрасывает) → `hasRealFilePicker` = false → `pickFileSafely`
([`file_import.dart:80`](../../../app/lib/services/file_import.dart))
возвращает `PickNoPicker`, **не запуская пик**. Total Commander при этом
установлен и `GET_CONTENT` обслуживает.

### Плагин тоже жёстко привязан к OPEN_DOCUMENT

`file_picker` 11.0.2,
`FileUtils.kt:202` — ветка `else` (в неё попадает `FileType.any`, которым
зовут все 8 наших call-site'ов):

```kotlin
intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply { ... }
```

`GET_CONTENT` в плагине используется только для `image/*`, `audio/*`,
`video/*`, `media` (строки 158–199). **Параметра, переключающего action
для `FileType.any`, у плагина нет** — то есть починить это подбором
аргументов `FilePicker.pickFiles` невозможно, даже если детект научить
правде.

### Что показал стенд

`cmd package query-activities`, оба эмулятора:

| Стенд | OPEN_DOCUMENT | GET_CONTENT |
|---|---|---|
| TV API 31 (`LxBox_TV31`, arm64), голый образ | только `frameworkpackagestubs` (`DocumentsStub`) | только `frameworkpackagestubs` (`DocumentsStub`, `MediaStub`) |
| Телефон API 34 (`sdk_gphone64_arm64`) | `com.google.android.documentsui` | `documentsui`, `apps.docs`, `apps.photos`, `providers.media.module` |

Голый TV-образ случай пользователя не воспроизводит: там нет стороннего
менеджера. Воспроизведение требует установки на эмулятор менеджера,
объявляющего `GET_CONTENT` (см. Верификация).

### Ложные следы

- **«Нужен `READ_EXTERNAL_STORAGE` для API ≤25»** — предположение
  пользователя, повторно отвергнуто. SAF/`GET_CONTENT` отдают `content://`
  Uri, чтение идёт через `ContentResolver` и storage-разрешения не
  требует. §372 отверг это же для `OPEN_DOCUMENT`.
- **«Это TV-специфика»** — нет. Корень в связке «менеджер отвечает только
  на `GET_CONTENT`», которая встречается на любых старых Android; TV лишь
  добавляет заглушку поверх.

## Решение

### A. Детект опрашивает оба action

`hasRealFilePicker` → возвращает не `Boolean`, а какой именно action
обслуживается реальным (не-stub) обработчиком:

- `OPEN_DOCUMENT` есть → прежний путь через плагин (поведение на
  телефонах не меняется);
- реален только `GET_CONTENT` → путь Б;
- ни одного → `PickNoPicker`, подсказка как сейчас.

`isStubHandler` применяется к обоим спискам — заглушка TV отвечает и на
`GET_CONTENT` (`MediaStub`, см. таблицу выше), без фильтра фикс сломал бы
уже работающий §372-случай.

### B. Свой `GET_CONTENT`-пик через канал

Плагин переключить нельзя (см. диагностику), поэтому для этого случая —
собственный `startActivityForResult(ACTION_GET_CONTENT)` в
`MainActivity`, с чтением результата через `ContentResolver` и возвратом
байтов в Dart. Формат результата приводится к тому, что уже ждёт
`pickFileSafely`, чтобы 8 call-site'ов и разбор `PickOutcome` не менялись.

Существенно для API 25: `path` у `content://` Uri, как правило, `null` —
читаем именно байты (`withData: true` в наших вызовах уже стоит).

### C. Область изменений

- [`MainActivity.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)
  — детект + новый метод канала;
- [`url_launcher.dart`](../../../app/lib/services/url_launcher.dart) —
  Dart-обёртка канала;
- [`file_import.dart`](../../../app/lib/services/file_import.dart) —
  ветвление в `pickFileSafely`.

Публичный контракт `PickOutcome` и тексты подсказок не меняются.

## Риски и edge cases

- **Регрессия на телефонах** — главный риск: детект общий для всех
  устройств. Митигация: при живом `OPEN_DOCUMENT` путь остаётся
  побайтово прежним; проверка на API 34 обязательна.
- **`GET_CONTENT` не даёт постоянного доступа** к Uri (в отличие от SAF).
  Нам не нужно: файл читается один раз в момент импорта.
- **Экспорт (`saveFile` / `CREATE_DOCUMENT`)** этой таской **не
  покрывается**. `GET_CONTENT`-аналога для сохранения не существует; на
  устройствах без SAF остаётся §374-fallback в Downloads, а он
  API 29+. Сохранение на 7.1.1 — отдельный вопрос, вне скоупа.
- **Менеджер, отвечающий на `GET_CONTENT`, но возвращающий `file://`
  Uri** (старые сборки TC) — читаем через `ContentResolver`, который
  `file://` тоже открывает; на API 25 `FileUriExposedException` не
  применяется (она про исходящие Uri, API 24+, и только для
  `StrictMode`-нарушений отправителя).

## Верификация

Стенд: AVD `LxBox_TV31` (Android TV, API 31, arm64) + собственный тестовый
менеджер `com.example.fakefm` — активность, зарегистрированная **только** на
`ACTION_GET_CONTENT`, отдающая файл через свой ContentProvider. Он
воспроизводит связку пользователя точно:

```
OPEN_DOCUMENT → только com.android.tv.frameworkpackagestubs
GET_CONTENT   → frameworkpackagestubs + com.example.fakefm
```

| # | Проверка | Статус |
|---|---|---|
| 1 | TV API 31 без менеджера → подсказка, заглушка не запускается (§372 не сломан) | ✅ DEVICE-VERIFIED |
| 2 | TV API 31 + менеджер на `GET_CONTENT` → intent запускается, система находит реальный обработчик | ✅ DEVICE-VERIFIED — `START … act=GET_CONTENT cmp=com.example.fakefm/.PickActivity`; до фикса до этой точки не доходило |
| 3 | Тот же сценарий сквозняком → файл прочитан, узел в списке | ✅ DEVICE-VERIFIED — `onActivityResult req=7035 res=-1 data=content://com.example.fakefm.provider/picked.json`, на экране Servers появился «⚡ FakeFM-test / VLESS server» |
| 4 | Телефон API 34 → путь через `OPEN_DOCUMENT`, регрессии нет | ✅ DEVICE-VERIFIED — `START … act=OPEN_DOCUMENT cmp=com.google.android.documentsui/…PickActivity`, ветка `GET_CONTENT` не активируется |
| 5 | `flutter analyze` — весь проект | ✅ No issues found |
| 6 | `flutter test` | ✅ 2947 passed |
| 7 | 4 l10n-чекера `--strict` | ✅ 0 failures / 0 warnings |
| 8 | Реальный Android 7.1.1 + Total Commander | ⏳ PENDING — у пользователя 4PDA |

### Грабля стенда (стоила одного ложного «фикс не работает»)

Промежуточные прогоны показывали «пик открылся, но узел не добавился», и это
выглядело как потеря результата на обратном пути. Причина оказалась в способе
автоматизации, а не в коде: на TV `ResolverActivity` при повторных вызовах
меняет раскладку — предвыбирает `Activity Stub` (заглушку TV) и уводит
реальный менеджер под заголовок «Use a different app». Слепые `input tap` по
прежним координатам попадали в кнопки заглушки, та отвечала отменой, и в
приложение приходило `res=0 data=null`.

Диагностический `Log.d` в `onActivityResult` развёл эти случаи однозначно:

```
req=7035 res=0  data=null                       ← промах по заглушке
req=7035 res=-1 data=content://…/picked.json    ← реальный выбор, всё работает
```

Вывод для будущих device-проверок: экран выбора обработчика **проверять
скриншотом перед каждым тапом**, не полагаться на координаты прошлого прогона.

Пункт 7 непроверяем на доступном стенде: TV-образ API 25 существует
только под x86 и на Apple Silicon не запускается (зафиксировано в §372),
arm64-образа API 25 не существует.

## Нерешённое / follow-up

- **Пустой главный экран после холодного старта** (тот же пользователь:
  «пока не сохранишь журнал debug — ничего не показывает»). Root cause не
  установлен; чтение конфига из `filesDir` и зависание bootstrap-цепочки
  как гипотезы отвергнуты. Нужен `bootstrap:`-лог с устройства. Отдельная
  таска.
- **D-pad: не прокручивается список узлов** — закрывает пункт 9 приёмки
  §372 (`DEVICE-PENDING`, проверялся тапами, не пультом). Отдельная таска.
- **Настраиваемое TLS-хранилище** (выбор системного / встроенного
  CA-бандла, как в NekoBox): на 7.1.1 корневые сертификаты в прошивке
  протухли, узлы с проверкой сертификата не подключаются. Фича, не таска.
- **Экспорт файла на устройствах без SAF** — см. Риски.
