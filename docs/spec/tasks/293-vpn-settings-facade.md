# §293 — VpnSettings-фасад: унификация 4 входов настроек

**Тип:** structural refactor (Шаг 3b фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec · **Размер:** M

Домен vpn-mode/tun-apps/app-settings — «эпицентр настроек»: **нет сервиса** между
экранами и `SettingsStorage`-статиками; валидация размазана по 3 слоям; ~4 входа
(UI, Debug API, backup import, build-time) **переизобретают** одни инварианты.
Нарушение §291 правил 1–2.

## Проблема

- `vpn_mode_tab`/`tun_apps_tab`/`settings_screen`/`app_settings_screen` — все
  screen==controller, зовут `SettingsStorage` напрямую.
- enum-литералы (`off/allow/deny`, `never/lazy/always`) переписаны инлайн в
  Debug-handler вместо переиспользования storage-констант.
- Инвариант (валидный порт/mode/protocol) переизобретается на каждом входе.
- **NB:** `native_prefs.dart` уже эталон (единый write-through) — его НЕ трогаем,
  фасад для него уже фактически есть.

## Решение — тонкий VpnSettingsFacade (strangler, делегирующий)

Ввести фасад, который сперва просто **делегирует** в существующие статики (0
изменений поведения), держит валидацию/enum-константы в одном месте, и на него
по одному переводятся: сперва Debug API (мал, централизован — идеальный первый
клиент), затем экраны оппортунистически. Эталон формы — `ChannelMutations` /
`SubscriptionController`.

Зависит от §292-D (валидация порта на модели) — фасад её переиспользует, не
дублирует.

## Файлы

- новый `lib/services/vpn_settings_facade.dart` (делегирующий)
- `lib/services/debug/handlers/settings.dart` (первый клиент; enum-константы из
  storage, не инлайн)
- экраны vpn_mode/tun_apps/app_settings — по одному, оппортунистически

## Приёмка

- Валидация порт/mode/protocol — один источник (модель+фасад), не переизобретена.
- Debug-handler не содержит инлайн enum-литералов.
- Каждый переведённый экран не зовёт `SettingsStorage` напрямую для vpn-mode.

## Docs to update

- `docs/ARCHITECTURE.md` — VpnSettingsFacade в карте слоёв.
- `CHANGELOG.md` — если меняется user-visible валидация.
