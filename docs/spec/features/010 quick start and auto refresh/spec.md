# 010 — Quick Start & Auto-refresh Subscriptions

## Контекст

Новый пользователь без конфига должен иметь путь к работающему VPN за один тап. Повторный пользователь не должен думать об обновлении подписок — приложение делает это автоматически.

## Что реализовано

### Quick Start (Get Free VPN)
- Встроенный пресет `assets/get_free.json`:
  - Две бесплатных подписки от @igareck (VLESS Reality, мобильные списки).
  - Рекомендованные правила роутинга: Block Ads, Russian domains direct, BitTorrent direct, Games direct.
- `GetFreeLoader` — сервис загрузки пресета из Flutter asset bundle (с кэшированием).
- `SubscriptionController.applyGetFreePreset()`:
  1. Загружает пресет.
  2. Заменяет список подписок.
  3. Сохраняет enabled rules.
  4. Fetch подписок.
  5. Генерация конфига.
- **Quick Start card** на HomeScreen:
  - Появляется когда `configRaw` пуст, подписок нет, `_subController` не busy.
  - Карточка с иконкой, описанием и кнопкой "Set Up Free VPN".
  - По нажатию: `applyGetFreePreset()` → `saveParsedConfig()` → SnackBar с количеством нод.

### Auto-refresh Subscriptions
- `SettingsStorage.parseReloadInterval(String)` — парсинг Go-style duration (`"12h"`, `"4h"`, `"30m"`).
- `SettingsStorage.shouldRefreshSubscriptions(interval)` — сравнение `last_global_update` с текущим временем.
- `SettingsStorage.getLastGlobalUpdate()` / `setLastGlobalUpdate(DateTime)` — persistent timestamp.
- При нажатии Start:
  1. Если есть подписки — проверяем `shouldRefreshSubscriptions`.
  2. Если да — `updateAllAndGenerate()` → `saveParsedConfig()` → `setLastGlobalUpdate()`.
  3. Затем `_controller.start()`.
  4. Ошибки refresh не блокируют запуск VPN (non-blocking).

### Subscription Metadata
- Новые поля в `ProxySource`: `name`, `lastUpdated`, `lastNodeCount`.
- `displayName`: `name` → `hostname` из URL → raw URL → `"(empty)"`.
- `SubscriptionEntry.subtitle`: статус + время последнего обновления ("2h ago", "just now").
- Всё сериализуется в `boxvpn_settings.json`.

## Файлы

| Файл | Изменения |
|------|-----------|
| `assets/get_free.json` | Новый asset — пресет |
| `pubspec.yaml` | Регистрация `get_free.json` |
| `services/get_free_loader.dart` | Новый — загрузка пресета |
| `services/settings_storage.dart` | `parseReloadInterval`, `shouldRefreshSubscriptions`, `lastGlobalUpdate` |
| `controllers/subscription_controller.dart` | `applyGetFreePreset()`, metadata в `_fetchEntry` |
| `models/proxy_source.dart` | `name`, `lastUpdated`, `lastNodeCount`, `displayName` |
| `screens/home_screen.dart` | Quick Start card, `_startWithAutoRefresh()`, progress banner |
| `screens/subscriptions_screen.dart` | Улучшенное отображение entry (subtitle, displayName) |

## Критерии приёмки

- [x] Quick Start card появляется при пустом конфиге и пропадает после setup.
- [x] Один тап "Set Up Free VPN" → конфиг готов к запуску VPN.
- [x] Auto-refresh: подписки обновляются автоматически при Start, если прошёл `reload` интервал.
- [x] Ошибка refresh не блокирует Start.
- [x] `lastUpdated` и `lastNodeCount` сохраняются и отображаются.
