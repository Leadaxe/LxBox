# 024 — Load Balance Outbound

| Поле | Значение |
|------|----------|
| Статус | Спека (planned) |

## Контекст

BoxVPN собирает ноды из нескольких подписок в общие группы. Сейчас доступны только `selector` (ручной выбор) и `urltest` (лучшая по латентности). Нет возможности распределять трафик между нодами.

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
| `round-robin` | Каждое соединение → следующая нода по кругу |
| `consistent-hashing` | Один домен → одна нода (sticky per domain) |
| `sticky-sessions` | Один source+dest → одна нода (TTL кэш) |

### Что делаем

1. **Замена libbox** на PuerNya сборку
2. **Wizard Template**: новый preset group type `loadbalance`
3. **UI в Routing Screen**: switch + dropdown стратегии
4. **ConfigBuilder**: уже поддерживает произвольные type + options

## Риски

- PuerNya форк может отставать от основного sing-box
- API libbox может отличаться
- Если PuerNya не публикует AAR — нужна своя сборка

## Файлы

| Файл | Изменения |
|------|-----------|
| `android/app/build.gradle.kts` | Заменить libbox dependency |
| `assets/wizard_template.json` | Добавить loadbalance preset group |
| `lib/screens/routing_screen.dart` | Dropdown стратегии |

## Критерии приёмки

- [ ] libbox из PuerNya форка подключён
- [ ] loadbalance группа генерируется в конфиге
- [ ] Трафик распределяется между нодами
- [ ] Существующие соединения не рвутся при ротации
- [ ] Выбор стратегии в Routing Screen
