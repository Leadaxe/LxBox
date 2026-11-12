# 727 — Xray `mux` не переносится в `multiplex` ядра

| | |
|---|---|
| **Статус** | In progress |
| **Дата** | 2026-11-12 |
| **Повод** | Telegram-чат: узел из Xray-подписки с `"mux": {"enabled": true, …}` не работает, пока `multiplex` не удалить руками |
| **Связанные** | контракт `registry/multiplex.json` блок `xray`, кейсы `corpus/body/xray/mux_concurrency*` |

## Docs to update

- эта задача
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Fixed

## Проблема

- Разбор Xray JSON переносит `mux.enabled` в `multiplex.enabled`, а
  `mux.concurrency` — в `multiplex.max_streams` (контракт, `multiplex#xray`
  у vless/vmess/trojan/shadowsocks).
- У Xray mux — это протокол **Mux.Cool** (служебный адрес `v1.mux.cool`).
  У ядра `multiplex` — это **h2mux/smux/yamux** (служебный адрес
  `sp.mux.sing-box.arpa`). Клиентской реализации Mux.Cool в ядре нет: в
  апстриме есть только серверный приём, см. `test/mux_cool_test.go`.
- Сервер Xray принимает служебный адрес sing-box за обычное назначение →
  соединение не проходит. Узел мёртв, пока `multiplex` не удалят руками.

## Решение

- Правка делается **в контракте** (репозиторий лаунчера), как в §726.
- Все четыре ключа `json.mux.*` у диалекта `xray`: чтение объявлено, в тело
  **не пишется** (`maps_to: null`). Ключи не попадают в `json_field_unknown`.
- Если `mux.enabled` истинно (`true` / `"true"` / `"1"`), на узле появляется
  info-код `xray_mux_unsupported`. При ложном значении кода нет.
- UDP ничего не теряет: у vless `packet_encoding` по умолчанию `xudp`, это
  та же XUDP-часть, которую Xray несёт внутри mux.
- `multiplex`, который автор прописал сам в sing-box JSON, **не трогаем**:
  это настройка для сервера на sing-box.
- В ссылках `vless://` и прочих Xray mux не передаётся — диалект `uri` не
  затронут.
- Уже импортированные узлы из подписки чинятся при следующем обновлении
  подписки (пересборка из Источника). Миграции нет.

## Реализация

- Лаунчер: контракт 1.1.169 (30e09cce + 271cfd30), D-146, TASKS_LXBOX §169;
  перенос mux, введённый в 1.1.50, отменён.
- LxBox: синк `sync_contract.sh --to 271cfd30`. Своего Dart-кода нет: маппинг
  и тексты кода приходят из реестра.

## Проверка

- Синк контракта у нас, раннер корпуса зелёный (кейсы `mux_concurrency*`
  с новым ожиданием: без `multiplex`).
- Эталон корпуса публичных подписок пересчитан, если там есть узлы с `mux`.
- CI develop зелёный.
