# 024 — Load Balance Outbound

| Поле | Значение |
|------|----------|
| Статус | Реализовано (§208, ядро sing-box-lx) — **другим путём**, чем задумано ниже |

## Итог реализации

Балансировка нагрузки реализована, но **не** через PuerNya `loadbalance`-outbound (см. «Решение» ниже — исторический план). Вместо форка добавлен режим **round-robin поверх штатной `urltest`-группы** в ядре sing-box-lx.

Модель: у канала `mode` переключается `least_test ⇄ round_robin`; в режиме `round_robin` эмитится блок `balancer{}` в config ядра:

| Поле `balancer` | Смысл | Покрывает стратегию из плана |
|---|---|---|
| `pool` | размер пула активных нод | — |
| `pool_tolerance` (мс) | 0 = весь живой пул; >0 = отбор лучших по delay | — |
| `sticky_hash[]` | компоненты ключа липкости; `[]` = чистая ротация | `round-robin` (пустой) · `consistent-hashing` / `sticky-sessions` (по составу ключа) |

- **Модель:** [`app/lib/models/channel.dart`](../../../../app/lib/models/channel.dart) (`ChannelAuto`, `UrltestMode`, `StickyHashKey`)
- **UI:** [`app/lib/screens/channel_edit_screen.dart`](../../../../app/lib/screens/channel_edit_screen.dart) (режим + sticky-ключи)
- **Билдер:** [`app/lib/services/builder/build_config.dart`](../../../../app/lib/services/builder/build_config.dart) (эмит `balancer{}` только для `round_robin`)
- **Runtime-пул:** [`app/lib/vpn/cc_channel.dart`](../../../../app/lib/vpn/cc_channel.dart) (`getPool` — снапшот слотов пула)

Таска реализации: [`../../tasks/208-urltest-balancer-round-robin.md`](../../tasks/208-urltest-balancer-round-robin.md).

Отличие от плана: PuerNya-форк libbox **не** подключался (устраняет риски «форк отстаёт» / «нет AAR»). Отдельного `loadbalance`-outbound-типа нет — балансировка живёт как режим `urltest`.

---

## Исторический план (не реализован в этом виде)

## Контекст

L×Box собирает ноды из нескольких подписок в общие группы. Сейчас доступны только `selector` (ручной выбор) и `urltest` (лучшая по латентности). Нет возможности распределять трафик между нодами.

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

- [x] ~~libbox из PuerNya форка подключён~~ — заменено: round-robin реализован в своём ядре sing-box-lx (§208), форк не нужен
- [x] balancer-группа генерируется в конфиге (`balancer{}` на `urltest`, режим `round_robin`)
- [x] Трафик распределяется между нодами (пул + sticky_hash)
- [x] Существующие соединения не рвутся при ротации (`interrupt_exist_connections`)
- [x] Выбор режима/стратегии — в редакторе канала (Channel edit), не в Routing Screen
