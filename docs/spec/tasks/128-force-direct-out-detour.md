# 128 — «Force direct-out» в detour-настройках узла

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата старта | 2026-06-15 |
| Триггер | В настройках отдельного узла (Detour dropdown) есть `None (direct)` и список узлов. Но `None` ≠ гарантированно прямой выход: если у узла в исходном конфиге зашита нативная detour-цепочка, трафик всё равно идёт через неё (APPEND-режим). Нужен пункт, **жёстко** отправляющий трафик в `direct-out`, игнорируя любую цепочку. |
| Связанные | [фича 018 detour server management](../features/018%20detour%20server%20management/spec.md); [§073](073-detour-append-vs-replace.md) (APPEND vs REPLACE); [§111](111-subscription-detour-without-native-chain.md) (detour-пикер подписок) |
| Затронутые файлы | `screens/node_settings_screen.dart`, `controllers/subscription_controller/subscription_entry.dart`, `config/consts.dart`; тест `test/builder/` |

## Назначение

Добавить в Detour-dropdown экрана настроек **отдельного узла** (`UserServer`,
`node_settings_screen.dart`) новый пункт **«Force direct-out»**, который пишет
в outbound узла `"detour": "direct-out"`, **выкидывая** нативную detour-цепочку
из исходного конфига.

**Только node settings** (решение юзера 2026-06-15) — detour-пикер подписок
(`subscription_settings_tab`) не трогаем.

## Семантика трёх состояний dropdown

| Пункт | overrideDetour | replaceDetourChain | Поведение builder'а |
|---|---|---|---|
| **None (direct)** | `''` | `false` | APPEND: нативная цепочка из конфига сохраняется (`detours.first`); если её нет — прямой выход. |
| **Force direct-out** *(новый)* | `'direct-out'` | `true` | REPLACE: цепочка выкинута (`skipDetour`), `main.detour = 'direct-out'`. Жёсткий прямой выход. |
| **`<тег узла>`** | `<тег>` | `false` | APPEND: трафик хвостом через выбранный узел. |

**Почему не нужен новый enum/поле:** `direct-out` — уже зарезервированный
валидный тег outbound'а (base outbounds в `wizard_template.json`, фигурирует в
routing/DNS-экранах). REPLACE-режим (`overrideDetour != '' && replaceDetourChain`)
уже реализован в builder'е ([server_list_build.dart:38-40](../../../app/lib/services/builder/server_list_build.dart)):

```dart
if (replaceMode) {
  main.map['detour'] = detourPolicy.overrideDetour;  // → 'direct-out'
}
```

→ Builder менять **не нужно**. Force-direct = просто комбинация уже существующих
полей политики. Это та же машинерия, что и «пустить через конкретный узел в
REPLACE-режиме», только целевой тег — `direct-out`.

## Изменения

1. **`config/consts.dart`** — `const kDirectOutTag = 'direct-out';` (чтобы не
   хардкодить строку в UI; старые хардкоды в `build_config.dart` — out of scope).

2. **`subscription_entry.dart`** — атомарный сеттер (один `copyWith` + persist,
   а не два отдельных setter'а `overrideDetour`/`replaceDetourChain` → двойной
   persist):
   ```dart
   void setDetourOverride(String tag, {required bool replace}) =>
       _replaceList(_copy(detourPolicy: detourPolicy.copyWith(
         overrideDetour: tag, replaceDetourChain: replace)));
   ```

3. **`node_settings_screen.dart`** — dropdown:
   - значение force-direct кодируем спец-sentinel'ом (НЕ может совпасть с тегом
     узла): используем сам `kDirectOutTag` как value пункта.
   - инициализация выбранного значения: если
     `entry.overrideDetour == kDirectOutTag && entry.replaceDetourChain` →
     показываем «Force direct-out»; иначе старая логика (`_detour` / `None`).
   - `onChanged`:
     - `kDirectOutTag` → `entry.setDetourOverride(kDirectOutTag, replace: true)`;
     - `''` (None) → `setDetourOverride('', replace: false)`;
     - тег узла → `setDetourOverride(tag, replace: false)` (APPEND как раньше).
   - hint-текст: для force-direct — «Forced direct: ignores any built-in detour
     chain.»

## Acceptance

- [ ] Dropdown показывает 3 рода пунктов: `None (direct)`, `Force direct-out`, `<узлы>`.
- [ ] Выбор «Force direct-out» → `overrideDetour='direct-out'`, `replaceDetourChain=true`, persist.
- [ ] Re-open экрана сохраняет выбор «Force direct-out» (инициализация из политики).
- [ ] Builder для force-direct → outbound узла имеет `"detour": "direct-out"`, нативная цепочка отсутствует.
- [ ] `None` и выбор узла работают как раньше (regression).
- [ ] Тест в `test/builder/`: force-direct → main.detour==direct-out; цепочка выкинута.

## NB

- `direct-out` не появляется в `_availableNodes` (там только узлы `UserServer`) —
  коллизии value-пунктов нет.
- Применимо к узлу с нативной цепочкой (REPLACE имеет смысл) и без неё (тогда
  эквивалентно `None`, но явно форсит прямой выход — безопасно).
