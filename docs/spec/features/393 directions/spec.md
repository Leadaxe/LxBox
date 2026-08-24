# 393 — Directions: рефакторинг каналов и паритет с лаунчером

Статус: **ТЗ к реализации** (решение оператора, 24.08.2026). Канонический
образец — лаунчер SPEC 104/108/110, контракт `app/contract/` (синхронизирован
на 0.6.0, sha в `app/contract.lock`).

## Мотив

Оператор: «directions — более верный термин, каналы используются в сетевой
терминологии по-другому» и «directions — более свежая замена Channel, надо
провести рефакторинг на мобиле как на лаунчере».

Направление (Direction) — именованная точка выбора маршрута, на которую
ссылаются правила. `Channel` LxBox уже почти совпадает с канонической формой
(`contract/schema/direction.schema.json`): label / enabled / nodeFilter
(тело regex) / nodeFilterInvert / defaultFilter / includeDirect /
includeBlock / auto. Не хватает:

1. **произвольные теги** — сейчас жёстко `vpn-1..vpn-10` (`kMaxChannels`,
   `channelNumberOf` в `app/lib/models/channel.dart:19-31`);
2. **include[]** — другие Направления опциями селектора (в лаунчере
   разрешены только стоящие ВЫШЕ по списку — циклы исключаются порядком);
3. сам термин в коде и UI.

## Состояние на момент написания (сделано 24.08)

- Контракт синкнут до 0.6.0 (`app/tool/sync_contract.sh`), **`app/contract.lock`
  НЕ коммитить**, пока контрактные тесты не зелёные: падает
  `test/contract/backup_corpus_test.dart` → `directions_created_on_import`
  (LxBox не знает раздел `directions[]` бэкапа v1.1).
- `tun_address` добавлен в `kLxPortableVars`
  (`app/lib/services/lx_backup.dart`, разрыв N7) — тест словаря зелёный.
- `app/android/libbox.version` бампнут на **v1.14.0-lx.27-rc.6**, AAR скачан
  (`scripts/fetch-libbox.sh`). Прежний rc.4 был БЕЗ `with_lx_chain`; тег
  входит в AAR с rc.5 (`sing-box-lx cmd/internal/build_libbox/main.go:93`).
- Остальные контрактные корпуса (uri/body/template/emit) — зелёные: парсер
  Dart уже в паритете с аудит-фиксами лаунчера.

## Ловушки (проверено на лаунчере, файл:строка — лаунчер)

| # | что |
|---|---|
| L1 | `default` обязан входить в состав группы: ядро отвергает ВЕСЬ конфиг («default outbound not found»). В лаунчере проверка на общем выходе эмиссии (`core/config/outbound_generator.go` перед сборкой parts) И у `options.default`. Проверить Dart-сборку каналов (`app/lib/services/builder/server_list_build.dart`) |
| L2 | Узел с detour на группу, в состав которой сам попал, — кольцо зависимостей, ядро не стартует (`dependency[X] not found`). Лаунчер: `core/config/detour_group_cycle.go`. У LxBox есть detour-каналы (`isDetour`, §248/§274) — проверить тот же класс цикла |
| L3 | Очистка поля пользователем ≠ артефакт: оба выглядят пустым значением. Лаунчер различает происхождением (`OutboundUpdate.Explicit`, `core/build/outbound_diff.go`). В LxBox патчей нет — применимо только если появятся |
| L4 | `sing-box check` НЕ ловит ошибки старта (`strip tls.utls`+reality, default-вне-состава) — падает только `run`. Валидация в форме — единственный рубеж |
| L5 | Цепочка — ИСТОЧНИК (маршрут), не Направление (выбор между маршрутами). Лаунчер прошёл через неверную модель и переносил (SPEC 110, раздел «Ревизия») |
| L6 | T9: Направление не берёт цепочку, которая через него проходит (транзитивно). Самый частый сценарий `[proxy-out, exit]` ломает сразу. Лаунчер: `core/config/chain_cycle.go` |
| L7 | Storage-ключ: решение оператора 24.08 — ПЕРЕИМЕНОВАТЬ `channels`→`directions` (полная чистота, включая данные). One-shot миграция с удалением легаси-ключей; порядок restore→migrate; downgrade пере-сеет из шаблона — принято осознанно. Прецедент лаунчера (Направления живут под json-ключом `outbounds`, `types.go:83`) рассмотрен и отклонён |
| L8 | UI-тексты только EN (AGENTS.md). «Directions» вместо «Channels» на экранах |

## Как лаунчер решает то же самое (референсы)

- Модель: `core/config/configtypes/types.go` — `Direction`, `SourceChain`,
  `ChainStripKeys/Default`.
- Бэкап направлений: `core/backup/directions.go` — export MERGED-телом,
  import ПЕРВЫМИ (цели пополняются до разбора правил), занятый тег → не
  применяется с warning; правило на несуществующую цель — выключено.
- Цепочка узлом: `core/config/chain_nodes.go` (разрешение ПОСЛЕ загрузки
  всех источников; ссылка только на цепочку ВЫШЕ по списку), эмиссия
  `chain_generator.go` (ChainOutboundObject), инварианты ядра
  (`protocol/chain/chain.go:85-100`): ≥2 позиций, без пустых/дублей/само-
  ссылки; вложенная цепочка только позицией 0; каталог strip закрыт.
- Проба ядра: launcher `core/core_chain_capability.go` по тегам сборки; на
  мобиле тегов не видно — гейт по `Libbox.version()` ≥ 1.14.0-lx.27-rc.5.
- Детур в цепочке (проверено на ядре): позиция 0 — свой detour РАБОТАЕТ
  (путь длиннее показанного, предупреждение); позиции ≥1 — detour
  перезаписывается безусловно (`protocol/chain/transform.go:110`), справка.
