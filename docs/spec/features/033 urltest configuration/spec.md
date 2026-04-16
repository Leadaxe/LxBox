# 033 — URLTest Configuration

**Status:** Реализовано

## Контекст

Параметры URLTest outbound (URL проверки, интервал, допуск) были захардкожены. Пользователям нужна возможность настраивать эти параметры для оптимизации автовыбора узлов.

## Реализация

### Новые переменные в wizard_template

Три новые переменные в секции `vars`:

```json
{
  "vars": {
    "urltest_url": "http://cp.cloudflare.com/generate_204",
    "urltest_interval": "5m",
    "urltest_tolerance": "100"
  }
}
```

### Подстановка через @var

Переменные применяются к preset group `auto-proxy-out` через механизм `@var` подстановки:

```json
{
  "tag": "auto-proxy-out",
  "type": "urltest",
  "url": "@urltest_url",
  "interval": "@urltest_interval",
  "tolerance": "@urltest_tolerance"
}
```

`ConfigBuilder` при генерации заменяет `@urltest_url`, `@urltest_interval`, `@urltest_tolerance` на значения из merged vars.

### UI в VPN Settings

На экране `SettingsScreen` три новых поля:

| Поле | Тип | Дефолт | Описание |
|------|-----|--------|----------|
| URLTest URL | TextField | `http://cp.cloudflare.com/generate_204` | URL для проверки доступности |
| URLTest Interval | TextField | `5m` | Интервал проверки (формат sing-box duration) |
| URLTest Tolerance | TextField | `100` | Допуск в мс для переключения узла |

Изменения автосохраняются (см. 027 autosave).

### Значения по умолчанию

- **url**: `http://cp.cloudflare.com/generate_204` — быстрый глобальный endpoint
- **interval**: `5m` — проверка каждые 5 минут
- **tolerance**: `100` мс — переключение на новый узел если разница > 100 мс

## Файлы

| Файл | Изменения |
|------|-----------|
| `assets/wizard_template.json` | Переменные `urltest_url`, `urltest_interval`, `urltest_tolerance` в vars и preset_groups |
| `lib/screens/settings_screen.dart` | Три новых поля для URLTest параметров |

## Критерии приёмки

- [x] Три переменные urltest_url, urltest_interval, urltest_tolerance в wizard_template
- [x] Подстановка @var в preset group auto-proxy-out
- [x] Поля отображаются на экране VPN Settings
- [x] Автосохранение при изменении
- [x] Дефолтные значения корректны
