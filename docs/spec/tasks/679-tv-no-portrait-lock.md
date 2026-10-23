# §679 — На TV ориентация не фиксируется: приложение на весь экран

| Поле | Значение |
|------|----------|
| Тип | B (поведение) |
| Статус | Implemented (2026-10-23); на устройстве не проверено |
| Дата | 2026-10-23 |
| Связанные | §220 (Allow rotation), §372 (Android TV), §622 / фича 031 (проверка на TV-эмуляторе 23.10); [Leadaxe/LxBox#163](https://github.com/Leadaxe/LxBox/issues/163) |

## Проблема

`applyAllowRotationSetting` (`app/lib/main.dart`, §220) при выключенном
`allow_rotation` (по умолчанию) ставит `DeviceOrientation.portraitUp`. На
Android TV экран всегда альбомный, и система показывает приложение узкой
портретной колонкой посреди экрана — всё приложение, не только экран
приёма §622. Найдено проверкой §622 на эмуляторе Android TV 1080p.

Решение владельца 23.10: на TV фиксацию снять.

## Решение

1. На TV ориентация не фиксируется никогда: при признаке TV
   (`UrlLauncher.isTelevision()`, §622 — UiMode TELEVISION или
   FEATURE_LEANBACK) `applyAllowRotationSetting` ставит пустой список
   предпочтений независимо от `allow_rotation`. На телефоне и планшете
   поведение §220 без изменений.
2. Значение `allow_rotation` в хранилище на TV не меняется и не
   переписывается (бэкап с TV на телефон не должен включать поворот).
3. Переключатель «Allow rotation» в App Settings на TV не показывается:
   на TV он ничего не делает. На телефоне — как был.
4. Экран приёма §622 в альбомной раскладке уже есть (на ширине больше
   высоты — QR слева, текст справа); проверить, что она и берётся.

## Риски

- Экраны приложения в альбоме на TV ~960×540 dp. Альбом и так доступен
  телефонам через «Allow rotation», грубых поломок не ждём, но
  проверенного прохода по экранам в альбоме нет.
- Признак TV асинхронный (канал); до ответа на старте — текущее
  поведение, затем повторное применение. Мигания быть не должно: на TV
  до runApp ответ канала уже есть, если вызывать после инициализации
  binding; проверить порядок в `main`.

## Решение (реализация 2026-10-23)

- `app/lib/main.dart` — `applyAllowRotationSetting` сначала ждёт
  `UrlLauncher.isTelevision()`; на TV `allow_rotation` не читается и не
  пишется, список предпочтений пустой. Выбор вынесен в
  `preferredOrientationsFor(allowRotation:, isTelevision:)`. Порядок на
  старте: вызов после `WidgetsFlutterBinding.ensureInitialized()` и до
  `runApp`, ответ канала приходит до первого кадра — портретной колонки на
  TV нет. В манифесте `screenOrientation` не задан, нативной фиксации нет.
- `app/lib/screens/app_settings_screen/widgets/appearance_tab.dart` —
  параметр `showAllowRotation` (по умолчанию `true`) скрывает переключатель.
- `app/lib/screens/app_settings_screen.dart` — признак TV в `initState`
  (как на home), `showAllowRotation: !_isTelevision`.
- Экран приёма §622 (`transfer_receive_screen.dart`) выбирает раскладку по
  `maxWidth > maxHeight` своего `LayoutBuilder`, без своей фиксации
  ориентации; на TV в альбоме берётся альбомная (QR слева, текст справа).
- Тесты: `app/test/services/allow_rotation_tv_test.dart` (чистая функция и
  `applyAllowRotationSetting` с подменой каналов; на TV файл настроек
  побайтно тот же), `app/test/screens/appearance_tab_rotation_test.dart`
  (переключатель на TV скрыт, на телефоне есть; проверяется на уровне
  вкладки, проводка `_isTelevision` в экране — нет).

## Проверка

- Юниты: TV + `allow_rotation=false` → пустой список; не TV +
  `false` → `portraitUp`; не TV + `true` → пустой список; на TV значение
  в хранилище не меняется.
- Виджет-тест: на TV переключателя «Allow rotation» нет, на телефоне есть.
- Устройство: не проверялось (TV-AVD удалены по слову владельца 23.10).
