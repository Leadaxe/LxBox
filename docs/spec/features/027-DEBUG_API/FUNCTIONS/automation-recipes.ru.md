[English](automation-recipes.md) · [Русский](automation-recipes.ru.md)

# Рецепты автоматизации — управление приложением с хоста через adb и curl

Разработчик, CI-скрипт или ИИ-агент говорит с устройством через `adb forward`
и обычный `curl`; те же шесть сценариев покрывают большую часть того, для
чего использовался бы экран.

| Поле | Значение |
|------|----------|
| Фича | [027-DEBUG_API](../FEATURE.ru.md) |
| Обещания | P17 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Превращает API в рабочий метод: как готовится сессия, как агент узнаёт
поверхность и из каких маршрутов складываются типовые сценарии —
воспроизведение жалобы, проверка узлов, правка правил, проба самодельного
конфига, прогон страховки старта в автотесте. Полный каталог примеров —
справочник ([`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md));
рецепты ниже — короткий список, который агент должен знать наизусть.

## Параметры

| Элемент | Значение |
|---------|----------|
| Проброс | `adb forward tcp:9269 tcp:9269` (порт из App Settings) |
| База | `BASE=http://127.0.0.1:9269`, `HDR="Authorization: Bearer <token>"` |
| Токен | App Settings → Diagnostics → Developer → Copy; стабилен до Regenerate |
| Теги не из ASCII | URL-кодировать значение параметра (`python3 -c 'import urllib.parse;print(urllib.parse.quote("…"))'`) |

## Входы / Выходы

**Входы:** команды оболочки на хосте; запущенное приложение на устройстве с
включённым Debug API. **Выходы:** JSON для разбора через `jq`; файлы (дамп,
pprof, отчёты), сохранённые `curl -o`; изменения состояния на устройстве.

```bash
# 1. Сессия: проброс, проверка жизни, карта
adb forward tcp:9269 tcp:9269
curl -s $BASE/ping                       # без токена: {"pong":true,…}
curl -s "$BASE/help?format=json" | jq '.endpoints[].path'

# 2. Воспроизвести жалобу: состояние, ошибки ядра, весь дамп
curl -s -H "$HDR" $BASE/state | jq '{tunnel,active_in_group,last_error}'
curl -s -H "$HDR" "$BASE/logs/core?level=warning,error&limit=100" | jq '.[].message'
curl -s -H "$HDR" $BASE/diag/dump -o dump.json

# 3. Проверить и переключить узлы
curl -s -X POST -H "$HDR" "$BASE/action/urltest?group=vpn-1-auto"
curl -s -X POST -H "$HDR" "$BASE/action/switch-node?tag=$(enc "$TAG")"

# 4. Добавить правило и пересобрать одним вызовом
curl -s -X POST -H "$HDR" -H 'Content-Type: application/json' \
  -d '{"name":"No telemetry","kind":"inline","domain_suffixes":["telemetry.example"],"outbound":"block"}' \
  "$BASE/rules?rebuild=true"

# 5. Попробовать самодельный конфиг, закреплённый от пересборок
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' -d '{"locked":true}' $BASE/settings/config_locked
curl -s -H "$HDR" $BASE/config > cfg.json          # править cfg.json
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' --data-binary @cfg.json $BASE/config
curl -s -X POST -H "$HDR" $BASE/action/reload-vpn
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' -d '{"locked":false}' $BASE/settings/config_locked

# 6. Автотест: headless-старт через страховку, затем чтение итога
curl -s -X POST -H "$HDR" "$BASE/action/start-vpn-headless?guard=true"
curl -s -H "$HDR" $BASE/core_reject | jq '{phase,outcome,disabled}'
```

## Правила и инварианты

- **Сначала `/help`, потом действия.** Карта отдаётся без токена и перечисляет
  каждый маршрут; агент, угадывающий пути, получает 404, читающий карту — нет.
- **Снимок перед опасной записью.** `GET /backup/export?include=storage` —
  полная точка восстановления; `GET /config`, `/state/rules`,
  `/state/subs?reveal=true` — дешёвые частичные. Восстановление —
  `POST /backup/import`.
- **Записи пачкой, пересборка один раз.** Несколько записей без
  `?rebuild=true` и один `POST /action/rebuild-config` в конце; пересборка —
  дорогой шаг, и флаг на каждом вызове его умножает.
- **Headless-старт не требует интерфейса.** `POST /action/start-vpn` работает
  до того, как главный экран собрал контроллеры; `start-vpn-headless`
  пропускает диалог согласия (разрешение уже должно быть выдано), а с
  `?guard=true` прогоняет ту же страховку отказа ядра, что кнопка Start, с
  отчётом через `GET /core_reject`.
- **Уважать бюджет 30 с.** Пробы папок и цепочек последовательны: на больших
  входах снижать `timeout_ms`, а не ждать 504.
- **Проверять, на каком устройстве вы.** `POST /action/toast?msg=…` показывает
  тост на экране; `GET /device` отдаёт модель, версии приложения и ядра.
- **Кодировать теги с эмодзи.** Теги узлов и групп идут значениями параметров;
  curl их не кодирует.

## Границы

- Рецепты — для тестового устройства, где API включил его владелец; API — не
  пользовательский контур и не удалённое управление (это
  [014-AUTOMATION](../../014-AUTOMATION/FEATURE.ru.md)).
- MCP-сервера или SDK поверх API нет (`§035F` отменена); инструменты — `curl`,
  `jq` и JSON-карта.
- Согласие на туннель, разрешения на уведомления и геолокацию выдаются на
  устройстве (`adb shell pm grant …`), а не через API.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | `adb forward` + curl как рабочий метод; быстрые примеры в `/help` |
| 2 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Реализовано | Сценарий «закрепить свой конфиг» |
| 3 | [316](../../../tasks/316-kernel-crash-reports-access.md) | Device-verified | Отчёты о сбоях и снимки скачиваются curl |
| 4 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | Headless-старт через страховку для автотестов |
| 5 | [592](../../../tasks/592-debug-api-help-parity.md) | N (new) | Паритет карты со справочником, на который опираются рецепты |
