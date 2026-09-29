[English](add-server-wizard.md) · [Русский](add-server-wizard.ru.md)

# Мастер добавления сервера

| Поле | Значение |
|------|----------|
| Фича | [008-NODE_EDITOR](../FEATURE.ru.md) |
| Обещания | P1 P2 P13 P15 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Заводит один свой сервер из структурированной формы или из вставленного
текста — для тех, кто не помнит формат ссылки `socks5://…` или хочет
вписать узел Tailscale полями. Открывается на экране источников долгим
нажатием на «+» или пунктом меню «Add server…». Полноэкранный, пять вкладок
с горизонтальной прокруткой; Cancel и Add — в заголовке.

## Параметры

| Вкладка | Поля | Дефолты |
|---|---|---|
| SOCKS5 | Tag (optional), Host, Port, Username (optional), Password (optional) | пусто → `local-socks5-out`; `127.0.0.1`; `1080` |
| HTTP | те же + «HTTPS (TLS to proxy)» | пусто → `local-http-out`; `127.0.0.1`; `8080`; выкл |
| Paste URI | многострочный текст ссылок | подсказка: vless / vmess / trojan / ss / hy2 / tuic / socks5 / proxy-http(s) / wireguard |
| Paste JSON | sing-box outbound, массив или документ; подсветка JSON | — |
| Tailscale | Tag (optional), Auth key, Control URL, Hostname, Ephemeral, Accept routes, Exit node | пусто → `tailscale`; обязателен; пусто; `LxBox-<модель устройства>`; выкл; выкл; пусто |

У полей Tag — палитра эмодзи; Auth key скрыт с кнопкой Show/Hide.

## Входы / Выходы

**Вход:** поля формы или текст.
**Выход:** новая запись «свой сервер» с одним узлом в конце списка
источников, пересборка конфига, сообщение «Added: <тег>» (формы) или
«Added» (вставка), возврат на экран источников.

| Вкладка | Что получается |
|---|---|
| SOCKS5 | outbound `socks`: `server`, `server_port`, `username`, `password`, `tag` |
| HTTP | outbound `http`: то же; при HTTPS — `tls.enabled: true`, `tls.server_name` = Host |
| Tailscale | endpoint `tailscale`: `auth_key` + только заполненные поля; булевы только `true` |
| Paste URI / JSON | тем же путём, что вставка на экране источников (разбор — 002) |

Формы хранят узел **телом sing-box с `tag`**, а не ссылкой: ссылка несёт имя
во фрагменте, и тег после перечитывания стал бы другим (P1).

## Правила и инварианты

- Host непустой, Port — целое 1..65535; иначе Add не выполняется, под полем
  «Host required» / «Port 1..65535» (P15, без свидетеля).
- Пустой Auth key — «Auth key required», узел не создаётся.
- Поле Hostname открывается заполненным; стёртое — ключа `hostname` в теле
  нет, имя выбирает сам Tailscale.
- Без Exit node узел Tailscale даёт доступ к tailnet, но не становится
  кандидатом Направлений; маршрут и DNS tailnet даёт пресет шаблона, не узел.
- Тег без эмодзи получает эмодзи по виду узла ([name-is-tag.md](name-is-tag.ru.md)).
- Уникальность тега не проверяется: совпавший тег сборка суффиксует `-1`,
  `-2`; сообщение показывает введённый тег, а не итоговый.
- Ошибка вставки (не распознано, ноль узлов) — сообщение с причиной, мастер
  остаётся открытым.
- JSON с комментариями принимается; сообщение «Comments were removed.»
  вместо «Added».
- Переключение вкладок не сбрасывает введённое в других вкладках.
- Отдельного поля «Display name» нет: заголовок записи — тег.

## Границы

- Добавление по ссылке в поле ввода, из буфера, QR, файла, публичные
  тест-серверы — «Добавление источника» в
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/add-source.ru.md).
- Форм для VLESS, Trojan, WireGuard и прочих нет — только вставкой.
- Мастер не собирает цепочку и не задаёт detour — это 006.
- Cloudflare WARP — отдельный мастер ([015-WARP](../../015-WARP/FEATURE.ru.md)).
- Правка созданного узла — [node-settings.md](node-settings.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Спека | Свой узел из ссылки или JSON |
| 2 | [074F](../../../tasks/074F-add-server-wizard/spec.md) | Released в v1.9.0 | Мастер: SOCKS5, Paste URI, Paste JSON; тег хранится телом JSON |
| 3 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Палитра эмодзи в поле Tag мастера |
| 4 | [222](../../../tasks/222-http-proxy-protocol.md) | Реализация | Вкладка HTTP(S)-прокси |
| 5 | [226](../../../tasks/226-scrollable-wizard-tabs.md) | Реализация | Горизонтальная прокрутка вкладок |
| 6 | [243](../../../tasks/243-wg-import-filename-tag.md) | Реализовано | Поле Display name удалено, Tag опционален с дефолтом |
| 7 | [333](../../../tasks/333-large-text-virtualization.md) | ✅ Реализовано | Построчный редактор для больших вставок |
| 8 | [435](../../../tasks/435-node-sections-tailscale.md) | Отменено, заменено §575/§578 | Форма Tailscale (форма осталась, секции узла упразднены) |
| 9 | [449](../../../tasks/449-tailscale-default-hostname.md) | Реализовано | Hostname по умолчанию `LxBox-<модель>` |
| 10 | [554F](../../../tasks/554F-schema-driven-node-editor/spec.md) | Идея, фаза 1 частично | Подсветка JSON во вкладке Paste JSON |
| 11 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | JSON с комментариями и незнакомым типом принимается |
