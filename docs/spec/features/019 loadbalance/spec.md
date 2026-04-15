# 019 — Load Balance Outbound

## Контекст

BoxVPN собирает ноды из нескольких подписок в общие группы. Сейчас доступны только `selector` (ручной выбор) и `urltest` (лучшая по латентности). Нет возможности распределять трафик между нодами — все соединения идут через одну.

## Решение

Перейти на PuerNya форк sing-box (sing-boxr) который добавляет `loadbalance` outbound с per-connection балансировкой.

### Тип: loadbalance

```json
{
  "type": "loadbalance",
  "tag": "lb-proxy",
  "strategy": "consistent-hashing",
  "outbounds": ["node-1", "node-2", "node-3"],
  "interval": "3m",
  "interrupt_exist_connections": false
}
```

### Стратегии

| Стратегия | Поведение |
|-----------|-----------|
| `round-robin` | Каждое новое соединение → следующая нода по кругу |
| `consistent-hashing` | Один домен всегда через одну ноду (sticky per domain) |
| `sticky-sessions` | Один source+dest → одна нода (TTL кэш, default 10m) |

`interrupt_exist_connections: false` — существующие соединения НЕ рвутся при ротации.

### Что делаем

#### 1. Замена libbox

Заменить `com.github.singbox-android:libbox:1.12.12` на PuerNya сборку:
- Вариант A: JitPack из `PuerNya/sing-box`
- Вариант B: Собрать `libbox.aar` из PuerNya/sing-box через `gomobile`
- Вариант C: Скачать готовый `.aar` из PuerNya releases

#### 2. Wizard Template

Новый preset group type `loadbalance`:

```json
{
  "tag": "lb-proxy",
  "type": "loadbalance",
  "label": "Load Balance",
  "default_enabled": false,
  "options": {
    "strategy": "consistent-hashing",
    "interval": "3m",
    "interrupt_exist_connections": false
  }
}
```

#### 3. UI в Routing Screen

В секции Proxy Groups — loadbalance группа с:
- Switch вкл/выкл
- Dropdown выбора стратегии (round-robin / consistent-hashing / sticky-sessions)

#### 4. ConfigBuilder

`_buildPresetOutbounds` уже поддерживает произвольные `type` + `options` — loadbalance заработает без изменений если PuerNya libbox обрабатывает `"type": "loadbalance"`.

## Файлы

| Файл | Изменения |
|------|-----------|
| `android/app/build.gradle.kts` | Заменить libbox dependency |
| `assets/wizard_template.json` | Добавить loadbalance preset group |
| `lib/screens/routing_screen.dart` | Dropdown стратегии для loadbalance групп |

## Риски

- PuerNya форк может отставать от основного sing-box
- API libbox может отличаться — нужно тестирование
- Если PuerNya не публикует AAR — нужна своя сборка через gomobile

## Критерии приёмки

- [ ] libbox из PuerNya форка подключён и работает.
- [ ] loadbalance группа генерируется в конфиге.
- [ ] Трафик реально распределяется между нодами.
- [ ] Существующие соединения не рвутся при ротации.
- [ ] Выбор стратегии доступен в Routing Screen.
