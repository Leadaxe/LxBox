# §333 — Большие тексты: виртуализация редактора конфига и read-only простыней

| | |
|---|---|
| Статус | ✅ Реализовано (device-pending) |
| Дата | 2026-08-01 |
| Связанные | [`302 import-rules`](302-subscription-import-rewrite-rules.md) (decoded-режим Source-таба), [`318 oom-reports`](318-oom-reports-access.md), 4PDA k-dmitriy #1312/#1313/#1316 |

## Проблема

4PDA (k-dmitriy #1312/#1313/#1316): при подписке ~1000 нод редактор конфига
тормозит (100% CPU на каждый символ), затем приложение падает; краш-репорт
пустой (0 байт). С 23 нодами всё нормально. Файл из #1316 — 97 КБ, и это один
из двух добавленных (суммарно ~200 КБ, ~10 тыс. строк pretty-printed).

Механика. Редактор ([config_screen.dart:171](../../../app/lib/screens/config_screen.dart)) —
один `TextField` c `maxLines: null` + `expands: true`. На каждое нажатие
клавиши Flutter делает **три O(N) по всему документу**:

1. **Layout всего параграфа.** `TextField` держит текст как единый `Paragraph`;
   любое изменение инвалидирует его целиком — shaping всех строк, не только
   видимых.
2. **Полная синхронизация с IME.** Каждый keystroke шлёт в Android
   `InputConnection` весь `TextEditingValue` через platform channel:
   JSON-сериализация сотен КБ + копии строк в Java-heap. Плюс дефолтные
   `autocorrect`/`enableSuggestions` гоняют по тексту спелчекер.
3. Пере-рендер decoration/selection поверх всего блока.

Пустой краш-репорт объясняется этим же: убивает не Go-паника и не
Dart-исключение, а **lmkd** (SIGKILL за давление на память от повторных
аллокаций параграфа и IME-копий) — следа в приложении не остаётся.

### Карта всех невиртуализированных мест

Редактируемые (полный набор: пере-layout + IME-синк на каждый символ):

| Место | Текст | Риск |
|---|---|---|
| [config_screen.dart:171](../../../app/lib/screens/config_screen.dart) | весь конфиг | **высокий** — кейс жалобы |
| [add_server_wizard_screen.dart:493,523](../../../app/lib/screens/add_server_wizard_screen.dart) | paste-поля визарда (пачка URL / outbound-JSON) | **средний** — туда вставляют ту же простыню из 1000 ссылок |
| dns_server_edit/json_tab, user_rule_editor_sheet, node_settings, identity-диалоги, warp_experiment | одна сущность, сотни байт | нет |

Read-only простыни (без keystroke-цикла, но единый `Paragraph`: разовый
layout O(N), память O(N), фриз при открытии):

| Место | Текст | Риск |
|---|---|---|
| [subscription_source_tab.dart:171](../../../app/lib/screens/subscription_detail_screen/widgets/subscription_source_tab.dart) | `SelectableText(rawSource)` — тело подписки целиком; decoded-режим (§302) — вторая такая же простыня | **высокий** |
| [crash_reports_screen.dart:207](../../../app/lib/screens/crash_reports_screen.dart) | `readAsString()` целиком + `SelectableText`; Go-паника с goroutine dump — сотни КБ | **средний** (просмотр краш-репорта сам способен уронить приложение) |
| [oom_reports_screen.dart:272](../../../app/lib/screens/oom_reports_screen.dart) | снапшот core-log при OOM, без лимита | низкий-средний |
| outbound_view_screen (JSON-таб, readOnly) | JSON одного outbound; худший случай — selector на 1000 тегов, десятки КБ | низкий |

Уже правильно: [debug_screen.dart:284](../../../app/lib/screens/debug_screen.dart)
(лог) — `ListView.separated` c itemBuilder, виртуализирован.

## Нецели

- **Подсветка синтаксиса** — её нет и сейчас; chunked-highlight (re_highlight)
  — отдельная тема со своими рисками производительности. Не в этом цикле.
- **outbound_view_screen JSON-таб** — readOnly `TextField` без фокуса не
  держит IME-цикл, разовый layout десятков КБ терпим. Не трогаем.
- **Поиск по краш-репорту / find-replace UI в редакторе** — re_editor это
  умеет (`findBuilder`), но UI поиска — фаза 2 после обкатки базы.
- **Лимит/lazy-чтение файлов репортов** (голова+хвост с «show full») —
  украшение, отдельно при необходимости.
- **Продуктовый вопрос** «1000 нод в raw-конфиге вместо подписки-канала» —
  не решаем здесь; редактор обязан не падать независимо от сценария.

## Решение

Правило: **большой текст — только через построчную модель**. Два инструмента
под две болезни.

### 1. Редактируемое: `re_editor` вместо `TextField`

Пакет [re_editor](https://pub.dev/packages/re_editor) ^0.10.0 (MIT,
verified publisher reqable.com, в продакшене Reqable — написан именно из-за
непригодности `TextField` для больших текстов). Построчная модель документа:
layout и правка касаются затронутых/видимых строк; в IME не уезжает весь
документ. Транзитивно тянет `re_highlight` и `isolate_manager` — подсветку
не включаем (нецель).

Замены (drop-in: у `CodeEditor` есть `hint`, `readOnly`, `wordWrap`,
`border`, `padding`, `style: CodeEditorStyle`):

- **config_screen** — `TextField` → `CodeEditor` +
  `CodeLineEditingController`. Сохраняются: monospace 12, hint
  «JSON or JSON5 …», рамка, кнопка Copy поверх (Stack). Номера строк
  (`indicatorBuilder` + `DefaultCodeLineNumber`) — включаем: бесплатно и
  полезно для навигации по 10-тысячестрочному конфигу.
- **add_server_wizard_screen** — оба paste-поля (`_uriCtrl`, `_jsonCtrl`) →
  `CodeEditor` (hint как сейчас, monospace 13, без номеров строк). Поля
  идут в `_submitInput()` по кнопке — семантика не меняется.

Контекстное меню (long-press copy/paste): у re_editor дефолтного может не
быть — `toolbarController`. Если из коробки пусто — минимальный контроллер
(copy/cut/paste/select all) по образцу из example пакета. Проверяется на
устройстве (чек-лист ниже).

### 2. Парсы конфига — в isolate

`prettyJsonForDisplay` (initState редактора) и `canonicalJsonForSingbox`
(Save, clipboard/file import) — json5-парс сотен КБ чистым Dart'ом в main
isolate = фриз даже с идеальным редактором.

В [config_parse.dart](../../../app/lib/config/config_parse.dart) добавляются
async-обёртки `prettyJsonForDisplayAsync` / `canonicalJsonForSingboxAsync`
через `compute()`; sync-версии остаются (тесты, мелкие вызовы). Ошибка
парса возвращается явным результатом (record/holder), **не** пробросом
`FormatException` через границу изолята: json5 может положить в
`FormatException.source` весь входной текст — копировать его между
изолятами и держать в state незачем. Вызовы в `config_io.dart`
(`saveConfigRaw`, `readFromClipboard`, `readFromFile`) и `config_screen.dart`
переводятся на async-обёртки. Туда же — canonical-to-canonical дифф в
`saveParsedConfig` (§116/§323): он парсит **два** конфига на каждом
сохранении/обновлении подписки и фризил UI ровно так же.

Попутная находка при реализации: json5 на синтакс-ошибке бросает свой
`SyntaxException` (implements Exception, **не** FormatException, из пакета
не экспортирован) — он пролетал мимо всех `on FormatException` в
`config_io`, и Save битого JSON5 падал unhandled без показа ошибки.
`canonicalJsonForSingbox` теперь нормализует его в `FormatException`
с тем же message (в нём координаты «… at line:col»).

### 3. Страховочный порог в config_screen

Выше порога `kConfigEditMaxBytes = 1 МБ` (константа рядом с экраном)
редактор открывается в `readOnly: true` с баннером: «File is too large to
edit on device. Share it, edit externally, then load it back.» Кнопки
Share / Load from file уже есть в меню экрана. Это же — план отката, если
re_editor на устройстве разочарует: гейт остаётся при любом исходе.

Порог по байтам `configRaw`, не по строкам: дёшево и предсказуемо. 97 КБ
кейса жалобы — в 10 раз ниже порога, остаётся редактируемым.

### 4. Read-only простыни: построчный вьюер без зависимостей

Новый общий виджет `lib/widgets/big_text_view.dart`:

- `BigTextView` — standalone: `SelectionArea(child: ListView.builder(...))`,
  по элементу на строку текста.
- `bigTextSlivers(...)` (или эквивалентный `SliverList.builder`-хелпер) —
  для встраивания в существующие скроллы со «шапкой».
- **Чанкование длинных строк**: строка длиннее 4096 символов режется на
  куски по 4096, каждый — отдельный элемент списка. Критично для
  undecoded base64-тела подписки — это **одна** строка на сотни КБ;
  без чанкования она снова стала бы единым гигантским параграфом.
  Визуально стык чанков при wrap неотличим от обычного переноса.
- Выделение: `SelectionArea` даёт выделение в пределах видимого;
  сквозное «выделить всё пальцем» с виртуализацией невозможно — для
  этого рядом остаются/добавляются кнопки Copy.

Применение:

| Экран | Было | Станет |
|---|---|---|
| subscription_source_tab | `ListView(children: [шапка…, SelectableText(body)])` | `CustomScrollView`: шапка в `SliverToBoxAdapter`, тело — sliver-строки; кнопка Copy source остаётся |
| crash_reports_screen (view) | `SingleChildScrollView` + `SelectableText` | `BigTextView`; в AppBar к Share добавляется Copy |
| oom_reports_screen | `ListView(children: [мета…, SelectableText(log)])` | как source_tab: шапка + sliver-строки; Copy для лога |

Мелкие `SelectableText` (мета, токен, URL) не трогаются.

## Файлы

| Файл | Изменение |
|---|---|
| `app/pubspec.yaml` | + `re_editor: ^0.10.0` |
| `app/lib/screens/config_screen.dart` | CodeEditor + порог readOnly + async-парсы |
| `app/lib/config/config_parse.dart` | async-обёртки через `compute()` |
| `app/lib/controllers/home_controller/config_io.dart` | вызовы async-обёрток |
| `app/lib/screens/add_server_wizard_screen.dart` | оба paste-поля → CodeEditor |
| `app/lib/widgets/big_text_view.dart` | новый: построчный вьюер + sliver-хелпер + чанкование |
| `app/lib/screens/subscription_detail_screen/widgets/subscription_source_tab.dart` | тело → sliver-строки |
| `app/lib/screens/crash_reports_screen.dart` | просмотр → BigTextView + Copy |
| `app/lib/screens/oom_reports_screen.dart` | лог → sliver-строки + Copy |
| `app/assets/l10n/ru/ui.json` | перевод новых строк (баннер порога) |

Попутный фикс: [config_screen.dart:94](../../../app/lib/screens/config_screen.dart)
`String.fromCharCodes(file.bytes!)` → `utf8.decode(..., allowMalformed: true)` —
сейчас не-ASCII (кириллица в JSON5-комментариях) читается как мусор
(байты трактуются как UTF-16 code units).

## Тесты

- unit: чанкование `big_text_view` — пустой текст, `\n`-хвост, строка ровно
  4096, строка 4097, монолит 100 КБ без переводов строк (число чанков).
- unit: `canonicalJsonForSingboxAsync` — валидный JSON5 → канонический JSON;
  невалидный → ошибка с message (не проброс исключения); поведение
  идентично sync-версии.
- unit: гейт `configTooLargeToEdit` (порог 1 МБ) — граничные значения.
- widget: `BigTextView` рендерит первые строки 50-тысячестрочного текста
  без layout всего документа (smoke: pumpWidget не таймаутится).
- Существующие тесты parser'а/config — без изменений (sync-версии на месте).

## Device-чеклист (CPH2411) — PENDING

Редактор на файле из #1316 (97 КБ, ~5 тыс. строк):

- [ ] холодное открытие экрана Config: без фриза (парс в изоляте), скролл плавный;
- [ ] ввод/удаление символов в середине документа: без лагов, без роста памяти;
- [ ] paste большого куска, undo/redo;
- [ ] long-press: контекстное меню copy/paste работает (или добавлен свой toolbarController);
- [ ] кириллица в комментариях JSON5 — ввод и загрузка из файла (utf8-фикс);
- [ ] swipe-клавиатура (Gboard glide) не сходит с ума на IME;
- [ ] Save 200 КБ: без ANR/джанка, конфиг применяется;
- [ ] Source-таб подписки на 1000 нод: raw и decoded (§302) — открытие без фриза;
- [ ] просмотр большого краш-репорта (сотни КБ) — скролл, Copy;
- [ ] wizard: вставка 1000 `vless://`-ссылок в URI-поле — поле живое, Import работает;
- [ ] память до/после открытия редактора (adb meminfo) — нет кратного роста.

## Docs to update

- `CHANGELOG.md` → Unreleased: perf — config editor and large text viewers
  no longer freeze/crash on multi-hundred-KB content (virtualized editor,
  line-based viewers, off-main-thread parsing).
- `docs/ARCHITECTURE.md` — none (виджет-уровень, контракты не меняются).
- Debug API — none.
