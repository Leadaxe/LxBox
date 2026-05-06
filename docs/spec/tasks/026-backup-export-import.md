# 026 — `/backup/*` export/import endpoints

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`031 debug api`](../features/031%20debug%20api/spec.md) |

## Проблема

Существующее Debug API позволяет писать пользовательские данные **по частям** — `PUT /config`, `PUT /settings/vars/{key}`, `POST /subs`, `POST /rules`. Чтобы восстановить полный snapshot (например, после `pm clear` или регрессии), нужно скриптовать несколько запросов.

`GET /diag/dump` отдаёт snapshot, но он **симметрии не имеет** — нет соответствующего `POST` endpoint'а. Плюс `/diag/dump` содержит диагностический шум (stderr, exit_info, logcat) который не нужен для restore.

## Решение

Новая группа [`/backup/*`](../../../app/lib/services/debug/handlers/backup.dart):

### `GET /backup/export?include=config,vars,subs`

Pure-data snapshot — только то что можно восстановить:
- `config` — текущий sing-box JSON.
- `vars` — все template-variables через `SettingsStorage.getAllVars()`.
- `server_lists` — подписки через `SettingsStorage.getServerLists()` (только persisted-shape — URL/name/meta, **без** runtime nodes-blob'ов).

Кеши (cache.db, stderr.log, applog.txt, SRS-blob) **не включаются** — restore их пересоздаст. Параметр `?include=` опционален, default — все три части.

### `POST /backup/import?merge=false&rebuild=false`

Body — JSON `{config?, vars?, server_lists?}`. Совместим с форматом `/backup/export` и `/diag/dump` (diag-поля игнорируются).

- `merge=false` (default) — replace: текущие vars стираются, server_lists заменяются.
- `merge=true` — vars upsert (новые ключи добавляются, старые обновляются), server_lists append-by-id (только entry с новыми id).
- `rebuild=true` — после restore зовёт `SubscriptionController.generateConfig` + `home.saveParsedConfig` (то же что `POST /action/rebuild-config`).

Returns `{"applied": {"config": bool?, "vars": N?, "server_lists": N?, "rebuilt": bool?}}`.

## Verification

```bash
# Backup
curl -s -H "$HDR" "$BASE/backup/export" > /tmp/backup.json

# Очистить (например adb pm clear) — потестить empty-state, etc.
adb shell pm clear com.leadaxe.lxbox

# Restore
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  --data-binary @/tmp/backup.json \
  "$BASE/backup/import?rebuild=true"
```

После restore `?rebuild=true` — sing-box config пересобран из подписок, готов к старту VPN.
