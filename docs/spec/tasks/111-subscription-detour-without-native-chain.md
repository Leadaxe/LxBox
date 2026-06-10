# 111 — Detour для подписок без родных detour-серверов

| Поле | Значение |
|------|----------|
| Статус | Done — в develop, установлено на тест-телефон (vc 2522); визуальная проверка за юзером |
| Дата старта | 2026-06-10 |
| Дата завершения | 2026-06-10 |
| Коммиты | `9573f57` feat(§111): detour для подписок без родных detour-серверов |
| Связанные spec'ы | [`018 detour server management`](../features/018%20detour%20server%20management/spec.md), [`026 parser v2`](../features/026%20parser%20v2/spec.md) §1.3/§3.4, [`073 append vs replace`](./073-detour-append-vs-replace.md), [`080`](./080-display-form-override-detour.md), [`096`](./096-register-toggles-in-append-mode.md) |

## Проблема

Секция «Detour servers» на экране подписки (Settings tab) показывается только
когда хотя бы у одной ноды есть родная detour-цепочка:

- [`subscription_detail_screen.dart:261`](../../../app/lib/screens/subscription_detail_screen.dart:261) — `hasDetour = nodes.any((n) => n.chained != null)`;
- [`subscription_settings_tab.dart:75`](../../../app/lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart:75) — `if (hasDetour) ...[вся секция]`.

Для подписки, чьи ноды приходят **без** detour'ов (типичный кейс — провайдер
отдаёт плоский список vless/ss-нод), секция скрыта целиком → прописать detour
всем нодам подписки негде.

При этом builder уже полностью поддерживает этот сценарий:
[`server_list_build.dart:43-47`](../../../app/lib/services/builder/server_list_build.dart:43)
— APPEND-режим (§073) при пустой цепочке ставит `main.map['detour'] =
overrideDetour` (1-hop). Фича чисто UI'шно недоступна.

## Решение

UI-only. Builder, модели, storage — без изменений.

### Компактная секция «Detour» (нет родных детуров)

В `SubscriptionSettingsTab` добавляется else-ветка к `if (hasDetour)`:
заголовок «Detour» + один ListTile-пикер, без radio-режимов:

- Полный radio (Use / Add detour / None) не нужен: без родной цепочки
  «Use» и «None» неразличимы (builder в обоих случаях не ставит detour),
  register-тоглы (§096) и «Replace existing chain» (§073) неприменимы —
  регистрировать/заменять нечего.
- ListTile: title «Detour server», subtitle = `'None — nodes connect
  directly'` либо `'Nodes → <tag> → Internet'`; tap → существующий
  `_showOverrideDetourPicker()` (кандидаты — ноды enabled `UserServer`'ов
  в display-form, §080; решение юзера 2026-06-10 — список кандидатов
  не расширяем).

Mapping на `DetourPolicy` (тот же storage-ключ `override_detour`):

| Действие в пикере | Эффект |
|---|---|
| выбран `<tag>` | `overrideDetour = '<tag>'`, `useDetourServers = true` |
| «None» (`''`) | `overrideDetour = ''` (useDetourServers не трогаем) |

### Fix в `_showOverrideDetourPicker`

При непустом выборе пикер дополнительно ставит `useDetourServers = true`.
Без этого leftover-состояние `useDetourServers=false` (юзер когда-то выбрал
None при живых детурах, потом подписка их потеряла) молча гасит override:
ветка [`server_list_build.dart:41-42`](../../../app/lib/services/builder/server_list_build.dart:41)
`!useDetourServers → main.map.remove('detour')` старше APPEND-ветки.
Для полного UI правка идемпотентна — пикер там вызывается только из
mode=override, где `useDetourServers` уже `true`.

## Таблица состояний (builder, цепочки нет: `detours.isEmpty`)

| `useDetourServers` | `overrideDetour` | `replaceDetourChain` | detour у main |
|---|---|---|---|
| true | `''` | любой | — (нет) |
| true | `X` | false (APPEND) | `X` (1-hop, строка 47) |
| true | `X` | true (REPLACE) | `X` (строка 40) |
| false | `X` | false | — (**до фикса**: override молча игнорился) |
| false → пикер ставит true | `X` | false | `X` |

## Edge cases

- **Подписка получила детуры после refresh** (`hasDetour` false→true):
  UI переключается на полный radio; `override_detour` уже непустой →
  mode=override (APPEND), native chain + override хвостом. Консистентно с §073.
- **Подписка потеряла детуры** (true→false): компактный UI показывает текущий
  override; leftover `replaceDetourChain=true` безразличен (обе ветки builder'а
  дают 1-hop `X`).
- **Подписка без нод** (fetch failed): `hasDetour=false` → секция теперь
  видна; настройка сохраняется и применится после успешного fetch. Безвредно.
- **Выбранный UserServer удалён/disabled** → dangling `detour`-ссылка.
  Существующее поведение override-пикера (§080, известное ограничение),
  этой таской не меняется.
- **Per-node detour для нод подписки** — out of scope (решение юзера
  2026-06-10: «достаточно уровня подписки»).

## Верификация

- `dart analyze lib/` — 0 issues.
- `flutter test` — без регрессий (builder-кейс «empty chain + override»
  уже покрыт `test/builder/detour_append_replace_test.dart`).
- Manual checklist:
  1. Подписка без родных детуров → Settings tab показывает секцию «Detour»
     с «None — nodes connect directly».
  2. Выбрать UserServer-ноду → subtitle «Nodes → X → Internet»; rebuild
     конфига: у всех нод подписки `"detour": "X"`.
  3. Выбрать None → detour исчезает из конфига.
  4. Подписка С родными детурами → секция выглядит как раньше (radio,
     регрессий нет).

## Файлы

| Файл | Изменение |
|------|-----------|
| `lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart` | else-ветка к `if (hasDetour)`: компактная секция «Detour» (заголовок + ListTile-пикер) |
| `lib/screens/subscription_detail_screen.dart` | `_showOverrideDetourPicker`: при непустом выборе ставить `useDetourServers = true` |
