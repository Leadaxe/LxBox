# 010 — Quick Start & Offline

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Новый пользователь без конфига должен иметь путь к работающему VPN за один тап. Повторный пользователь не должен думать об обновлении подписок. При отсутствии сети приложение должно работать с кешированными данными.

## Quick Start (Get Free VPN)

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

## Auto-refresh Subscriptions

- `SettingsStorage.parseReloadInterval(String)` — парсинг Go-style duration (`"12h"`, `"4h"`, `"30m"`).
- `SettingsStorage.shouldRefreshSubscriptions(interval)` — сравнение `last_global_update` с текущим временем.
- При нажатии Start:
  1. Если есть подписки — проверяем `shouldRefreshSubscriptions`.
  2. Если да — `updateAllAndGenerate()` → `saveParsedConfig()` → `setLastGlobalUpdate()`.
  3. Затем `_controller.start()`.
  4. Ошибки refresh не блокируют запуск VPN (non-blocking).

## Subscription Metadata

- Новые поля в `ProxySource`: `name`, `lastUpdated`, `lastNodeCount`.
- `displayName`: `name` → `hostname` из URL → raw URL → `"(empty)"`.
- `SubscriptionEntry.subtitle`: статус + время последнего обновления ("2h ago", "just now").

## Subscription Caching

**Status:** Реализовано

### Кеш на диске

Сырой HTTP-ответ (тело подписки) сохраняется в директорию `sub_cache/` внутри application support directory. Имя файла — hex-представление `hashCode` URL подписки.

### Логика в SourceLoader

1. HTTP запрос на URL
2. **Успех:** сохранить ответ в кеш, парсить, вернуть узлы
3. **Ошибка сети:** прочитать из кеша → парсить → вернуть узлы + флаг `fromCache: true`
4. **Ошибка сети + нет кеша:** вернуть пустой результат с ошибкой

При `fromCache: true`:
- Счётчик узлов **не сбрасывается**
- Статус: `"N nodes (update failed)"`
- Последняя дата обновления не обновляется

## Файлы

| Файл | Изменения |
|------|-----------|
| `assets/get_free.json` | Пресет |
| `services/get_free_loader.dart` | Загрузка пресета |
| `services/settings_storage.dart` | `parseReloadInterval`, `shouldRefreshSubscriptions`, `lastGlobalUpdate` |
| `controllers/subscription_controller.dart` | `applyGetFreePreset()`, metadata в `_fetchEntry` |
| `models/proxy_source.dart` | `name`, `lastUpdated`, `lastNodeCount`, `displayName` |
| `screens/home_screen.dart` | Quick Start card, `_startWithAutoRefresh()` |
| `services/source_loader.dart` | Запись/чтение кеша, fallback на кеш при ошибке |

## Критерии приёмки

- [x] Quick Start card появляется при пустом конфиге и пропадает после setup.
- [x] Один тап "Set Up Free VPN" → конфиг готов к запуску VPN.
- [x] Auto-refresh: подписки обновляются при Start, если прошёл `reload` интервал.
- [x] Ошибка refresh не блокирует Start.
- [x] `lastUpdated` и `lastNodeCount` сохраняются и отображаются.
- [x] HTTP ответ подписки кешируется на диск.
- [x] При сетевой ошибке данные загружаются из кеша.
- [x] Счётчик узлов не сбрасывается при ошибке обновления.
