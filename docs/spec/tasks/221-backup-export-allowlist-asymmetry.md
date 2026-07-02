# §221 — Backup-экспорт терял channels: асимметрия allowlist ↔ export

| Поле | Значение |
|------|----------|
| Статус | Done |
| Тип | bug (data-loss при backup/restore) |
| Дата | 2026-07-02 |
| Приоритет | High — теряется вся модель роутинга при переносе на новое устройство |
| Связано | §219 (нашёл masque_account, но не сверил обратную сторону), §125 (channels), §130 (masque_account — тот же класс) |

## Проблема

`SettingsStorage.allowedTopLevelKeys` (что **restore принимает**) и
`backup_service._topLevelRoutingKeys`/`_topLevelAppKeys` (что **export пишет**)
разошлись: **4 ключа были в allowlist, но НЕ в экспорте** → молча выбрасывались
при `buildExport`. Restore их бы принял — но их нет в файле, потому что export не
записал.

| Потерянный ключ | Что теряется | Severity |
|---|---|---|
| **`channels`** | вся модель роутинг-каналов §125 (vpn-1..vpn-10, node/default-фильтры, auto-балансировщики) | 🔴 |
| **`channels_migrated`** | guard one-shot миграции — без него миграция пере-сработает поверх восстановленных каналов | 🔴 |
| `route_idle_suspend` | порог idle-suspend §215 (`route.lx_idle_suspend`) | 🟡 |
| `profiler_retention_sec` | окно хранения Live-журнала §044 | 🟡 |

**User-impact:** юзер делает backup → в файле нет `channels` → restore на новом
устройстве → вся модель роутинг-каналов потеряна, откат к дефолтам. Серьёзнее
исходного masque_account (§130), т.к. channels — центральная живая модель
роутинга поста-§125.

## Диагностика

- §219 закрыл `masque_account` (не был в allowlist restore) — но **не сверил
  обратную сторону**: ключи, что в allowlist есть, а в export нет.
- Корень механизма: `backup_service._filterStorageForImport` (используется и на
  export) фильтрует top-level по `_topLevelRoutingKeys`/`_topLevelAppKeys`;
  комментарий там прямо предписывает «новый ключ — добавить в нужную категорию
  **и** в allowedTopLevelKeys». §125 добавил `channels` в allowlist, но забыл в
  категорийный фильтр экспорта. §215/§044 — то же с `route_idle_suspend`/
  `profiler_retention_sec`.
- Почему тесты не поймали: `sampleSnapshot()` в backup_service_test **не
  содержал** `channels` → ни один export-тест не проверял его наличие.

## Решение

Ревью §219-фиксов (пользователь) вскрыло **4 находки** — все закрыты:

1. **channels в export (главный, этот тайтл).** `channels` +
   `channels_migrated` + `route_idle_suspend` → `_topLevelRoutingKeys`;
   `profiler_retention_sec` → `_topLevelAppKeys`. Асимметрия детально выше.
2. **use-after-dispose закрыт частично (§219).** `_emit` (home_controller.dart)
   оставался БЕЗ гейта `_disposed` — точечные `if (_disposed) return` после await
   стояли лишь в 2 методах, а start/stop/reconnect/switchNode/pullToRefresh
   дырявые. **Радикально:** одна строка `if (_disposed) return;` в самом `_emit`
   закрывает весь класс разом (dispose не эмитит, гейт штатный teardown не рвёт).
   Точечные проверки §219 остаются как ранний выход.
3. **Утечка `http.Client` в support_message.dart** (`fetchOrCached`, главный
   экран) — тот же паттерн, что чинили в sources/community (§219), но прод-путь
   пропущен. Фикс: `owned`-флаг + `try/finally` close.
4. **FIX 7 неполон (§219):** в `channel_edit._snapshot` клэмпился только `pool`,
   а `tolerance`/`poolTolerance` — нет (снапшот ≠ персист). `_clampTolerance` →
   публичная `clampChannelTolerance`, применена в снапшоте.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| backup (#1) | `services/backup_service.dart` | +channels/channels_migrated/route_idle_suspend в routing-keys, +profiler_retention_sec в app-keys |
| controller (#2) | `controllers/home_controller.dart` | гейт `if (_disposed) return;` в `_emit` |
| service (#3) | `services/support/support_message.dart` | owned-close `http.Client` в `fetchOrCached` |
| model (#4) | `models/channel.dart` | `_clampTolerance` → публичная `clampChannelTolerance` |
| UI (#4) | `screens/channel_edit_screen.dart` | clamp tolerance/poolTolerance в `_snapshot` |
| тесты | `test/services/backup_service_test.dart` | +channels в `sampleSnapshot`; тест «§221 — channels экспортируются»; инвариант allowlist ⊆ export |

## Верификация

- `channels`+`channels_migrated` в export при routing-категории. ✓
- round-trip export→reset→import→bytewise equal (теперь с channels). ✓
- allowlist ↔ export полная сверка скриптом: 0 расхождений после фикса. ✓
- `flutter analyze` чист; 1470 тестов зелёные.

## Профилактика

Асимметрия allowlist ↔ export — системный риск: любой новый top-level ключ надо
класть **в оба** места. Стоит завести тест-инвариант «каждый ключ из
`allowedTopLevelKeys` (кроме vars/server_lists со своими ветками) присутствует в
одной из export-категорий» — тогда следующий забытый ключ упадёт в CI.

## Docs to update

- `CHANGELOG.md` — entry в `[2.9.1]` (релиз готовится).
- Этот файл — летопись.
