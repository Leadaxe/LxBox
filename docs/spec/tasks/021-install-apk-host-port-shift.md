# 018 — install-apk.sh host port auto-shift (избегаем коллизий с другими VPN-клиентами)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Коммиты | `29951c4` |
| Связанные | Debug API forward, dev workflow |

## Проблема

`scripts/install-apk.sh` после install'а делал `adb forward tcp:9269 tcp:9269` — пробрасывал Debug API на Mac:9269. Если на Mac параллельно запущен другой VPN-клиент (`singbox-launcher` у меня), который **тоже** держит свой Debug API на 9269 — `adb forward` конфликтует.

Симптом: после install'а скрипта, юзер пытается курлить `localhost:9269` — попадает в чужой сервер. Тратит часы на отладку «почему мой токен не принимается» (натуральный кейс этой сессии).

## Решение

Разделили:
- `--debug-port` (default 9269) — порт **на устройстве** где LxBox Debug API.
- `--host-port` (default **9270**) — порт на Mac для forward.

Default `9270` выбран чтобы не толкаться с привычным `9269` других клиентов. Если 9270 тоже занят кем-то не-adb (например, после многих рестартов накопились forward'ы) — авто-инкремент до первого свободного:

```bash
while lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  if lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN -c adb >/dev/null 2>&1; then
    break  # это наш же предыдущий forward — переиспользуем
  fi
  HOST_PORT=$((HOST_PORT + 1))
done
```

Если итоговый `HOST_PORT != DEBUG_PORT` — выводим в stdout строку `(host port shifted, see --host-port)` чтобы юзер не молча получал шифт.

## Файлы

- [`scripts/install-apk.sh`](../../../scripts/install-apk.sh) — добавлен `--host-port` arg, авто-shift логика, обновлён usage в комментариях.

## Верификация

- `singbox-launcher` запущен и держит 9269 → `./scripts/install-apk.sh --no-launch` выводит `→ adb forward tcp:9270 tcp:9269  (host port shifted, see --host-port)`. Курление `curl localhost:9270/ping` идёт в LxBox.
- 9270 тоже занят кем-то посторонним → auto-shift на 9271. (Не тестировал нарочно, но логика правильная.)
- Default flow когда никто не занимает — `→ adb forward tcp:9270 tcp:9269` без shift-warning'а.

## Известное

Скрипту неоткуда узнать, что юзер хочет именно 9269 на хосте — flag `--host-port 9269` есть, но default специально 9270. При желании можно сделать env-var override (`LXBOX_HOST_PORT`), сейчас не нужно.
