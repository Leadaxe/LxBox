# 509 — Цепочка сортируется с соседями в `sources[]`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-09-20 |
| Повод | На Servers список общий, а цепочка не встаёт между сервером и подпиской |
| Связанные | [§393](../features/393%20directions/spec.md), [§439](../features/439%20storage-contract-1-0/spec.md), [§098](098-reorder-subscriptions-and-unify-dns.md) |

## Docs to update

- эта задача
- [STORAGE.md](../../STORAGE.md) — `sources[]` в порядке списка, не «цепочки хвостом»
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Changed
- [ARCHITECTURE.md](../../ARCHITECTURE.md), [debug-api-reference.md](../../api/debug-api-reference.md) — хвост больше не норма

## Проблема

Экран Servers рисует подписки, серверы, папки и цепочки одним `ReorderableListView`. После drop порядок разводился на два блока: `saveServerLists` и `setChains` каждый склеивал «свой род + чужой хвостом/головой». Цепочка визуально уезжала и возвращалась вниз.

Инвариант «цепочка ссылается только на цепочку выше» этого не требует: он считается по взаимному порядку цепочек. Сервер между ними ссылок не ломает. В JSON все четыре `kind` — соседи одного массива.

## Решение

- Писатели `sources[]` вставляют свой род в **существующие слоты** (`_spliceSourceKind`); лишнее — в конец.
- Drag на Servers пишет полную перестановку (`SettingsStorage.reorderSources`).
- Список читает `getSourceKeys()` (`id:<uuid>` / `chain:<tag>`), а не «сначала entries, потом chains».
- LX Backup принимает `sourceKeys`, чтобы смешанный порядок не схлопывался в «lists затем chains».

Миграция 2.23.2 по-прежнему кладёт старые `chains[].order` хвостом — один раз. Дальше порядок не схлопывается.

Автогруппа не трогалась: она запись `folder.nodes[]`, не `sources[]`.

## Риски

- `saveServerLists` после списка из одних цепочек дописывает новый сервер в конец, а не перед цепочками. Для общего списка это «новая строка внизу».
- Неполная перестановка `reorderSources` — no-op, состав не меняет.

## Верификация

- `test/services/chains_storage_test.dart` — смешанный порядок, zipper не выносит цепочку в хвост
- `test/contract/lx_backup_test.dart` — `sourceKeys` ставит цепочку перед сервером
- `flutter analyze`; затронутые тесты
