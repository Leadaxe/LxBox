[English](node-detour.md) · [Русский](node-detour.ru.md)

# Detour узла — выход сервера через другой сервер

Свой сервер или член папки может выходить в интернет через другой узел; путь
показан в порядке пакета, а сломанная ссылка не превращается в прямое
соединение.

| Поле | Значение |
|------|----------|
| Фича | [006-DETOUR_AND_BALANCE](../FEATURE.ru.md) |
| Обещания | P1 P12 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Даёт своему серверу или члену папки «сначала через другой сервер»:
блок **Detour** в настройках узла («Route through another server first»),
строка **Detour server** открывает пикер цели. Под строкой — превью пути
в порядке пакета: `Phone → <хопы> → <узел> → Internet`, с разворотом
цели по её собственному detour (до шести хопов), либо «Traffic goes
directly to this server.».

## Параметры

| Ручка | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| Detour server | None (direct) · член этой папки · detour-Направление · свободный сервер | None | `detour` узла |

Секции пикера «Detour server», сверху вниз:

| Секция | Кто в ней | Когда видна |
|---|---|---|
| None (direct) | — | всегда |
| This folder (N) | члены своей папки, кроме себя и групп; «Chains inside the folder get the folder detour appended» | только в контексте папки |
| Directions | включённые Направления с «Use as detour», подпись «Switchable detour direction», текущий выбор в скобках | есть хоть одно |
| Standalone servers | узлы включённых одиночных серверов, кроме себя и групп; `TYPE · server:port` | иначе «No standalone servers available» |

## Входы / Выходы

**Входы:** выбор пользователя; список источников; Направления; текущие
выборы групп (для подписи в скобках).
**Выходы:** ссылка-адрес в хранении (член папки — пара «папка + сырой тег»,
остальное — корневой тег); `detour` с финальным тегом в конфиге;
предупреждение, если узел выпал.

## Правила и инварианты

- Сервер не может ходить через себя: «A server cannot detour through
  itself». В папке кольцо личных detour отвергается сразу: «This would
  create a detour loop inside the folder».
- Узлы подписок и члены чужих папок целью не бывают — они живут под
  чужой политикой.
- Узел автовыбора (группа) целью не бывает и сам блока Detour не
  имеет (P12).
- Разрешение ссылки — вторым проходом сборки, когда известны все
  финальные теги; цель может стоять ниже по списку источников.
- Fail-closed (P1): ссылка на пропавший/выключенный узел, удалённый
  источник, на себя или в кольцо ссылок → узел не эмитится, каскадом
  выпадают ходившие через него. Предупреждение: «Node "…" was skipped:
  its detour … did not resolve — … A node whose detour does not
  resolve is not emitted, so its traffic never goes direct.» (при
  нескольких — одна строка, первые пять имён и счётчик).
- Под detour, назначенным сборкой, тело узла уступает: `tls.fragment`
  (и осиротевший `fragment_fallback_delay`, если нет `record_fragment`)
  и `listen_port` WireGuard снимаются с кодом; у авторского JSON-тела
  `tls.fragment` остаётся с пометкой «не применено».
- Detour через WireGuard/AmneziaWG разрешён (прежний запрет §130 снят).
- «Force direct-out» как detour не делается: ядро рвёт каждое соединение
  такого узла; прямой выход — это None.

## Границы

- Detour всей подписки/папки — [source-detour-policy.md](source-detour-policy.ru.md).
- Цель-Направление и её лечение — [026-DIRECTIONS](../../026-DIRECTIONS/FUNCTIONS/direction-as-detour.ru.md).
- Хранение ссылок, их обновление при переименовании и удалении узлов —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.ru.md).
- Прочие настройки узла — [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Политика в 026 | Первичная модель detour/jump-серверов |
| 2 | [006](../../../tasks/006-per-node-detour-toggles.md) | Done | Detour-регистрация на уровне сервера |
| 3 | [080](../../../tasks/080-detour-override-picker-prefix-aware.md) | ✅ Реализовано | Пикер хранит тег с префиксом источника |
| 4 | [128](../../../tasks/128-force-direct-out-detour.md) | Won't-fix | `detour: direct-out` не предлагается |
| 5 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | Запрет AWG→WG снят вслед за ядром |
| 6 | [237](../../../tasks/237-folder-member-node-settings.md) | реализовано | Личный detour члена папки |
| 7 | [239](../../../tasks/239-folder-detour-symmetry.md) | реализовано | Единый пикер: свободные + своя папка |
| 8 | [252](../../../tasks/252-physical-packet-route-line.md) | РЕАЛИЗОВАНО | Превью пути в порядке пакета |
| 9 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Ссылка — адрес `{folder_id?, tag}`, fail-closed |
| 10 | [574](../../../tasks/574-tls-fragment-yields-to-detour.md) | Released v2.25.7 | `tls.fragment` уступает detour сборки |
