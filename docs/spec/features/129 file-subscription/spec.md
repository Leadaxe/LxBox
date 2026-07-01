# §129 — Редактируемый источник подписки (online URL ↔ локальный файл)

> **СТАТУС: СПЕКА.** Согласовано. Объединяет: file-подписку (Вариант Б, снапшот
> в кэш, без native SAF) + редактируемый URL + переключение online↔file.

## Зачем

1. Юзеры хотят «Import from file…» как **постоянную подписку из файла** со списком
   нод (не разовый импорт одной ноды).
2. Юзеры просят **редактируемый URL** подписки (сменился домен провайдера,
   опечатка) — без пересоздания и потери настроек.

Обе просьбы смыкаются в одной сущности: **источник подписки редактируемый**, и у
него два режима — online (`http(s)://url`) и file (`file:<uuid>`, снапшот в кэше).

## Модель (переиспользуем `SubscriptionServers`, native SAF НЕ нужен)

Файловая подписка = обычная `SubscriptionServers`, `url` = `file:<uuid>`:

| Поле | online | file |
|---|---|---|
| `url` | `http(s)://…` | `file:<uuid>` (синтетический ключ) |
| дискриминатор | `startsWith('http')` | `startsWith('file:')` |
| источник нод | HTTP fetch | снапшот в `HttpCache` по ключу `url` |
| обновление | fetch по URL | Edit source → Choose file (перечитать) |
| auto-update | как сейчас | fetch = keep-previous (файл не читаем) |

`id` подписки стабилен на смене источника — та же подписка, меняется только
источник; name/enabled/detour/tagPrefix/channel-привязки сохраняются.

## UX

### Import from file… (создание, быстрый путь — остаётся)

```
pickFiles → текст файла → decode+parseAll (WG-INI/base64/plain/clash/JSON +
   #key:value заголовки — всё уже ест пайплайн v2)
  → нод ≤ 1  → СТАРОЕ поведение (addFromInput → обычная нода-сервер)
    нод > 1  → SubscriptionServers(url:'file:<uuid>', name:<имя файла>)
       + HttpCache.save(url, тело) → nodes, meta, persist
```

### Edit source (новое — на существующей подписке)

Кнопка «Edit source» → попап:

```
( ) Online URL   [https://…                    ]
(•) Local file   📄 servers.txt      [Choose…]
                         [Cancel]  [Save]
```

Переключатель режима online↔file + ввод (текст-поле URL / picker файла). Save →
пробуем новый источник. Любой из 4 переходов: online→online, online→file,
file→online, file→file.

## ИНВАРИАНТ: смена источника транзакционна (не остаться без нод)

**Старый кэш и `url` сбрасываются ТОЛЬКО после успешного получения нового.**

```
Save нового источника:
  1. получить новый (fetch по новому URL / прочитать новый файл) → parse
  2. если нод > 0:
       HttpCache.save(newUrl, body); удалить старый HttpCache(oldUrl);
       entry.url = newUrl; entry.nodes = newNodes; status ok
  3. если нод == 0 / fetch fail / файл пустой:
       НИЧЕГО не трогаем — ни старый кэш, ни url, ни nodes.
       Ошибка юзеру: "Couldn't load new source — keeping current."
```

Тот же принцип, что §101 keep-previous, применённый к смене источника: коммитим
только при успехе нового, иначе полный откат. Подписка не «слетает».

## Fetch / re-hydrate

- `_fetchEntryByRef` ветка по схеме `url`:
  - `http(s)://` → HTTP (как сейчас).
  - `file:` → НЕ читаем ничего, keep-previous (ноды из кэша). Auto-update файловую
    не портит.
- Re-hydrate при старте (§101): нод нет → `HttpCache.loadBody(url)` → decode+parse.
  Работает для обоих режимов (ключ = url).

## Заголовки / WG

- `#key: value` заголовки → `_inlineHeaders` → meta (уже есть).
- WG/AWG-конфиг в файле (`[Interface]`) → decode/parseAll уже детектят и зовут
  `parseWireguardIni` (body_decoder.dart:140, parse_all.dart:16). Отдельной ветки
  не нужно.

## UI

- Список подписок: file-подписка вместо URL показывает имя файла + бейдж **file**
  (`url.startsWith('file:')`). Кнопка «Edit source» на каждой подписке.
- `maskSubscriptionUrl` для `file:` → имя (не сырой ключ).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| controller | `subscription_controller.dart` | импорт-гейт (>1→файловая); `file:`-ветка fetch (keep-previous); `updateSourceAt(index, newSource)` транзакционно (коммит по успеху) |
| helpers | `input_helpers.dart` / mask | `isFileSubscription(url)` + mask для `file:` |
| UI | `subscriptions_screen.dart` (+ entry-виджет, edit-source dialog) | Edit-source попап online↔file; бейдж file; `_importFromFile` создаёт файловую при >1 |
| model | `server_list.dart` | (возможно) helper `isFile` на url — не новые поля |
| storage/docs | STORAGE.md | `file:<uuid>` в `url` |
| тесты | `test/subscription/` | >1→файловая; ≤1→нода; fetch file→keep-previous; смена источника: успех→коммит, фейл→откат; re-hydrate |

## Что НЕ делаем (Вариант Б)

- Native SAF / persistable URI / авто-перечитывание файла на диске. Обновление
  file-подписки = Edit source → Choose file (ручной клик). Auto-update файл не
  читает (keep-previous) → не слетает при массовом апдейте онлайн-подписок.

## Связанные

- §026 subscription pipeline (Source/parseFromSource/HttpCache/re-hydrate).
- §101 keep-previous-on-fail (тот же инвариант, применён к смене источника).
- §217 xhttp-нормализация (та же подписка ест ноды).
