# 685 — Интервал обновления подписки: пункт «As subscription», ручной выбор не перетирается

| Поле | Значение |
|------|----------|
| Статус | Done (на устройстве не проверено) |
| Дата начала | 2026-10-26 |
| Связанные спеки | [603](603-subscription-and-own-server-bugs.md) — разбор заголовка `profile-update-interval`, правило `nextUpdateIntervalHours`; [129F](129F-file-subscription/) — спец-значения `-1`/`0` |

## Проблема

Пользователь выбирает интервал обновления подписки (например, 12 ч). При
следующем обновлении приложение записывает в это поле значение из заголовка
сервера `profile-update-interval` (например, 3 ч), и выбор пользователя
пропадает. Ручной выбор поэтому держится только до ближайшего обновления.

Причина: `nextUpdateIntervalHours(current, server)` (`sources.dart`) для
любого `current ≥ 0` возвращает `server ?? current`, а результат пишется в
`updateIntervalHours` подписки при каждом успешном фетче.

## Решение (слово владельца 26.10.2026)

Первый пункт списка — «As subscription» (интервал из заголовка сервера). Ниже
идут ручные значения. Ручное значение обновление подписки не трогает.

### Значения поля `update.interval_hours` (форма хранилища не меняется)

| Значение | Было | Станет |
|---|---|---|
| `0` | «Never (respect server)»: сами не обновляем, заголовок сервера записывается в поле | **«As subscription»**: интервал берётся из заголовка; поле не меняется |
| `-1` | «Don't auto-update» | без изменений |
| `> 0` | раз в N часов, заголовок сервера перезаписывает | раз в N часов, **заголовок не перезаписывает** |
| `< -1` | наследие до §603, лечится на refresh | при refresh превращается в `0` |

Действующий интервал (его читают автообновление, GC отметок выключенных узлов
и подписи в UI) вычисляет `effectiveUpdateIntervalHours(setting, server)`:

- `setting == 0`: сервер прислал число `N > 0` → `N`; прислал `0` → автообновления
  нет; заголовка нет → 24 ч;
- иначе `setting` (`-1` = выключено).

Серверное значение хранится в `meta.update_interval_hours` (уже есть, §603).

### Новые подписки

URL-подписка, добавленная пользователем, создаётся с `0` («As subscription»).
Файловые остаются `-1`. При смене источника файл → URL ставится `0` (было 24),
URL → URL оставляет выбор пользователя (было: `≤ 0` сбрасывалось на 24).

### UI

Диалог «Update interval»: первым пунктом «As subscription (…)», в скобках
действующее значение; затем «Don't auto-update», затем 1, 3, 6, 12, 24, 48,
72, 168 ч. Пункт «Never (respect server)» снят: его поведение покрывает
«As subscription».

Подпись строки в настройках подписки: «As subscription — every 3h» /
«As subscription — server sets none, every 24h» / «As subscription — server
disables auto-update». Подпись в списке подписок показывает действующий
интервал.

### Что меняется у существующих установок (миграции нет)

- Значение `> 0`, которое раньше записал сервер, остаётся как ручное: интервал
  тот же, но за изменениями сервера больше не следует. Вернуть слежение — выбрать
  «As subscription».
- Значение `0` при сервере без заголовка раньше означало «только вручную»,
  теперь — раз в 24 ч.

## Файлы

- `lib/services/subscription/sources.dart` — `nextUpdateIntervalHours`,
  новая `effectiveUpdateIntervalHours`, константа 24.
- `lib/services/subscription/auto_updater.dart` — действующий интервал.
- `lib/controllers/subscription_controller.dart` — GC и создание/смена URL.
- `lib/controllers/subscription_controller/subscription_entry.dart` — геттер
  действующего интервала.
- `lib/screens/subscription_detail_screen.dart`,
  `.../widgets/subscription_settings_tab.dart`,
  `lib/screens/subscriptions_screen/widgets/subscription_entry_subtitle.dart` — UI.
- `assets/l10n/*/ui.json` — новые строки.
- `docs/STORAGE.md` — смысл `0`.

## Проверка

- Юнит-тест `nextUpdateIntervalHours` / `effectiveUpdateIntervalHours`.
- Ручная: выбрать 12 ч у подписки с заголовком 3 ч → Update → в диалоге
  отмечено 12 ч; выбрать «As subscription» → в подписи 3h.
