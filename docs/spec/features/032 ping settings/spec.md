# 032 — Ping Settings

**Status:** Реализовано

## Контекст

Кнопка пинга на главном экране использовала фиксированный URL. Пользователям в разных регионах нужны разные URL для корректного измерения задержки. Tooltip на кнопке пинга конфликтовал с long-press жестом.

## Реализация

### Long-press на кнопке пинга

Long-press открывает bottom sheet с настройками пинга. Tooltip с кнопки пинга удалён для устранения конфликта жестов.

### Bottom Sheet

```
┌──────────────────────────────────┐
│  Ping Settings                   │
│                                  │
│  URL Presets                     │
│  [Google 204] [Cloudflare] [Apple]│
│  [Firefox] [Yandex]             │
│                                  │
│  Custom URL                      │
│  ┌──────────────────────────────┐│
│  │ http://...                   ││
│  └──────────────────────────────┘│
│                                  │
│  Timeout (ms)                    │
│  ┌──────────────────────────────┐│
│  │ 5000                        ││
│  └──────────────────────────────┘│
└──────────────────────────────────┘
```

### Пресеты URL

Отображаются как `ChoiceChip` виджеты. Загружаются из `wizard_template.json` секции `ping_options.presets`:

```json
{
  "ping_options": {
    "url": "http://cp.cloudflare.com/generate_204",
    "timeout": 5000,
    "presets": [
      {"name": "Google 204", "url": "http://www.gstatic.com/generate_204"},
      {"name": "Cloudflare", "url": "http://cp.cloudflare.com/generate_204"},
      {"name": "Apple", "url": "http://captive.apple.com/generate_204"},
      {"name": "Firefox", "url": "http://detectportal.firefox.com/success.txt"},
      {"name": "Yandex", "url": "http://yandex.ru/generate_204"}
    ]
  }
}
```

Выбор пресета заполняет поле custom URL.

### Custom URL и Timeout

- `TextField` для произвольного URL
- `TextField` для timeout в миллисекундах
- Значения сохраняются в `HomeController.pingUrl` и `HomeController.pingTimeout`

### Хранение

Значения `pingUrl` и `pingTimeout` хранятся в `HomeController` и используются при запуске пинга. Персистируются через settings storage.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/home_screen.dart` | Long-press handler на кнопке пинга, bottom sheet UI, удалён Tooltip |
| `assets/wizard_template.json` | Секция `ping_options` с пресетами |

## Критерии приёмки

- [x] Long-press на кнопке пинга открывает bottom sheet
- [x] ChoiceChip пресеты загружаются из wizard_template
- [x] Выбор пресета устанавливает URL
- [x] Поле custom URL для произвольного адреса
- [x] Поле timeout для настройки таймаута
- [x] Значения сохраняются и используются при пинге
- [x] Tooltip удалён с кнопки пинга
