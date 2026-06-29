# Feature 126 — First-run startup wizard

> **СТАТУС: РЕАЛИЗАЦИЯ.** Единый последовательный движок first-run-промптов
> вместо россыпи `unawaited(...)` в `home_screen.initState`.

## Зачем

На холодном старте home-screen показывает несколько onboarding-диалогов. Сейчас
([home_screen.dart](../../../../app/lib/screens/home_screen.dart) в
`addPostFrameCallback`):

```dart
unawaited(maybeShowNotificationPermissionDialog(context));
unawaited(maybeShowBatteryOptimizationDialog(context, _vpn));
```

Они запускаются **параллельно** (`unawaited`) → barrier-диалоги физически
наезжают друг на друга (один поверх другого / гонка за navigator). Добавить
новый промпт (плитка QS) в эту схему = ещё хуже.

**Решение:** один `StartupWizard` — последовательный движок. Шаги идут по
очереди с `await`: следующий показывается только после закрытия предыдущего.
Добавлять/править/переупорядочивать onboarding-вопросы — в одном месте.

## Что входит в визард

Только **first-run onboarding** (показывается один раз, persist-флаг). Порядок —
от «нужно для работы» к «приятно иметь»:

| # | Шаг | Persist-ключ | Применимость |
|---|---|---|---|
| 1 | Notification permission | `notif_perm_prompted_v1` (существующий) | Android 13+ (runtime perm) |
| 2 | Battery optimization | новый `wizard_battery_v1` | если НЕ в whitelist |
| 3 | Add QS tile | новый `wizard_addtile_v1` | Android 13+ (есть системный промпт) |

**НЕ входит** (событийные, не onboarding — не трогаем):
- `_maybeShowSupport` — по факту подключения + порог сессии.
- update-snackbar — по приходу новой версии.

## Механика

`StartupWizard` (новый [startup_wizard.dart](../../../../app/lib/screens/home/startup_wizard.dart)):

```dart
class StartupWizard {
  StartupWizard(this.context, this.vpn);
  final BuildContext context;
  final BoxVpnClient vpn;

  Future<void> run() async {
    for (final step in _steps) {
      if (!context.mounted) return;
      if (!await step.shouldShow()) continue;
      await step.run(context, vpn);
      // помечается показанным ВНУТРИ run() (или сразу после shouldShow=false),
      // чтобы повторный визард шёл мимо.
    }
  }
}
```

Шаг — простой record/класс `({Future<bool> Function() shouldShow, Future<void>
Function(BuildContext, BoxVpnClient) run})`. Реализации шагов = тонкие обёртки
над уже существующими `maybeShow*` функциями в
[home_dialogs.dart](../../../../app/lib/screens/home/home_dialogs.dart) — НЕ
дублируем логику диалогов, переиспользуем.

**Persist-контракт:** каждый шаг ставит свой флаг сразу после показа (как
`maybeShowNotificationPermissionDialog` уже делает с `notif_perm_prompted_v1`).
`shouldShow()` читает флаг + проверяет применимость к устройству (API level /
whitelist). Battery-шаг дополнительно гейтится «не в whitelist» — если юзер уже
дал exception, повторно не спрашиваем (как сейчас).

**Add-tile шаг:** только API 33+ (там есть системный промпт
`requestAddTileService`). На API < 33 промпта нет — шаг помечается показанным и
пропускается молча (никакой текстовой инструкции на онбординге — она остаётся в
App Settings по кнопке «Add tile»). `vpn.requestAddTile()` уже есть.

## Интеграция

`home_screen.dart` — блок из двух `unawaited(maybeShow...)` заменяется на:
```dart
unawaited(StartupWizard(context, _vpn).run());
```
`_maybeShowSupport()` остаётся отдельным вызовом (событийный, не онбординг).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| Dart | `screens/home/startup_wizard.dart` (NEW) | движок + список шагов |
| Dart | `screens/home/home_dialogs.dart` | battery-шаг → persist-флаг (сейчас показывается каждый старт); add-tile обёртка `maybeShowAddTilePrompt` |
| Dart | `screens/home_screen.dart` | 2× unawaited → 1× `StartupWizard.run()` |

## Поведенческое изменение battery-промпта

Сейчас `maybeShowBatteryOptimizationDialog` показывается **каждый** старт пока
нет whitelist. В визарде — добавляем persist-флаг `wizard_battery_v1`: показать
один раз. Обоснование: навязчивый повтор раздражает; кнопка в App Settings
остаётся для повторного захода. (Если решим оставить повтор — флаг не ставим,
shouldShow гейтит только по whitelist. Дефолт спеки: один раз.)

## Тесты

- `StartupWizard.run`: шаги вызываются по порядку; шаг со `shouldShow=false`
  пропускается; mounted=false прерывает.
- Persist: показанный шаг на втором проходе не показывается.
- (диалоги сами — через существующие пути, виджет-тесты не дублируем).

## Связанные

- §032 — Quick Connect tile (кнопка «Add tile» в App Settings, переиспользуем).
- [§212 tile long-press → open app](../../tasks/212-tile-longpress-open-app.md).
- §105 — support-message (НЕ часть визарда, событийный).
