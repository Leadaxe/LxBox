# 080 — Detour-override picker: store prefixed display-form tag

| Поле | Значение |
|------|----------|
| Статус | In progress (v1.9.1) |
| Дата | 2026-06-08 |
| Тип | fix (config emission breakage) |
| Зависимости | §073 (`server_list_build._withPrefix` + overrideDetour application), §077/§079 (same prefix-form bug class). |
| Связанные | `subscription_detail_screen.dart::_showOverrideDetourPicker`, `node_settings_screen.dart::_load`, `services/builder/server_list_build.dart::_withPrefix`. |

## Триггер

Audit §077 (workflow `verify-077-multi-match`, finding #13) обнаружил bug
того же класса что §077/§079, но с **худшим** failure mode — ломает сборку
конфига целиком.

Detour-override picker'ы хранят **bare** `UserServer.nodes[i].tag`, а
`server_list_build.dart` эмитит outbound с tag'ом через
`_withPrefix(n.tag)` = `'$tagPrefix $base'` при непустом `tagPrefix`.
`overrideDetour` подставляется builder'ом **прямо** в `main.map['detour']`
без prefix-трансформации. Когда у UserServer'a (целевого detour-сервера)
непустой `tag_prefix`, сохранённый bare tag ссылается на несуществующий
outbound → sing-box reject `'outbound[...] references unknown outbound'`
или detour молча не применяется.

## Воспроизведение

1. UserServer **A** с `tag_prefix='Home'`, нода `tag='WG'`.
   В config эмитится outbound `tag='Home WG'` (через `_withPrefix`).
2. UserServer/Subscription **B**. На B → Detour → Add detour → выбрать `WG`
   из picker'a.
3. Picker сохраняет `overrideDetour='WG'` (bare).
4. Builder: `B.main.detour = 'WG'`, но в outbounds есть только `'Home WG'`.
5. Dangling reference → config build fails / VPN won't start (или detour
   тихо игнорируется).

При пустом `tag_prefix`: bare == display → баг невидим (regression-free
default case, как §077/§079).

### Severity уточнение (review finding Q2)

Dart-валидатор (`validator.dart`) проверяет только `route.rules[].outbound`
ссылки, но **не** валидирует `detour`-поля outbound'ов. И
`subscription_controller._generate` логирует fatal, но не блокирует VPN
(см. §081 follow-up). Поэтому на **Dart-уровне** dangling detour = «detour
тихо игнорируется, конфиг собирается, VPN стартует».

**НО**: sing-box core при parse конфига может реджектить unknown detour
reference (`outbound[...] not found`) → на **native-уровне** = «VPN не
стартует». On-device поведение не верифицировано в этом проходе. Для
affected юзеров (непустой prefix + старая bare-сохранёнка) это либо
silent-broken detour, либо VPN won't start — оба плохие, фикс закрывает
оба для новых выборов.

## Root cause

Два UI picker'a строят список detour-целей из bare node-тэгов:

```dart
// subscription_detail_screen.dart::_showOverrideDetourPicker (было):
for (final e in widget.controller.entries) {
  if (e.list is! UserServer) continue;
  for (final n in e.list.nodes) {
    if (n.tag.isNotEmpty) tags.add(n.tag);   // ← bare
  }
}
// chosen tag → widget.entry.overrideDetour = chosen   (bare сохраняется)

// node_settings_screen.dart::_load (было):
for (final e in widget.subController.entries) {
  if (e.list is! UserServer) continue;
  for (final n in e.list.nodes) {
    if (n.tag.isNotEmpty && n.tag != _originalTag) tags.add(n.tag);  // ← bare
  }
}
```

Целевой outbound же эмитится prefixed:

```dart
// server_list_build.dart:
main.map['tag'] = ctx.allocateTag(_withPrefix(main.tag));  // 'Home WG'
// ...
main.map['detour'] = detourPolicy.overrideDetour;          // 'WG' — dangling!
```

## Фикс

Оба picker'a строят и сохраняют **display-form** (`'$tagPrefix $base'`),
идентичный `_withPrefix`:

```dart
// subscription_detail_screen.dart:
for (final e in widget.controller.entries) {
  final list = e.list;
  if (list is! UserServer) continue;
  if (!list.enabled) continue;   // §080: disabled → no outbounds → dangling
  final prefix = list.tagPrefix;
  for (final n in list.nodes) {
    if (n.tag.isEmpty) continue;
    tags.add(prefix.isEmpty ? n.tag : '$prefix ${n.tag}');
  }
}

// node_settings_screen.dart — + self-exclude по display-form:
final selfPrefix = widget.entry.list.tagPrefix;
final selfDisplay =
    selfPrefix.isEmpty ? _originalTag : '$selfPrefix $_originalTag';
for (final e in widget.subController.entries) {
  final list = e.list;
  if (list is! UserServer) continue;
  final prefix = list.tagPrefix;
  for (final n in list.nodes) {
    if (n.tag.isEmpty) continue;
    final display = prefix.isEmpty ? n.tag : '$prefix ${n.tag}';
    if (display != selfDisplay) tags.add(display);
  }
}
```

Picker показывает и сохраняет display-form → `overrideDetour` совпадает с
эмитированным outbound tag'ом → detour резолвится.

## Migration / graceful degradation

- **Старые сохранёнки с bare `overrideDetour`** (непустой prefix): были
  **уже сломаны** до §080. Не мигрируем автоматически (риск ошибочного
  маппинга при коллизиях имён). Вместо этого — graceful degradation:
  dropdown `initialValue` = `_availableNodes.contains(_detour) ? _detour : ''`,
  поэтому stale bare value (которого нет в новом display-списке)
  показывается как **None**. Юзер видит что detour «слетел» → перевыбирает
  из корректного списка → чинится. Не молчаливая поломка.
- **Empty-prefix сохранёнки**: bare == display → продолжают работать без
  изменений (regression-free).
- **Backup format**: schema `override_detour` не меняется (хранит тег как
  строку, теперь это display-form). Старые backup'ы → graceful degradation
  как выше.

## Известное ограничение (collision-suffix)

`_BuildCtx.allocateTag` добавляет `-1`/`-2` если prefixed tag коллизит с
другим outbound. Если целевой UserServer-узел получил `-N` suffix
(`'Home WG-1'`), а picker сохранил `'Home WG'` — detour снова dangling.
Тот же класс ограничения что §077 collision case. Редкий (требует двух
UserServer-узлов с идентичным prefix+name). Acceptable: graceful
degradation сработает (dropdown покажет None при следующем открытии).

## Follow-up (из adversarial review, вне scope §080)

Review (`review-080-detour-picker`, 7 confirmed findings) выявил два
смежных pre-existing gap'а — отдельные таски, не блокеры §080:

- **§081 candidate — validator не проверяет detour refs.** `validator.dart`
  валидирует только `route.rules[].outbound`, игнорируя `detour`-поля.
  Dangling detour не даёт ValidationIssue. Добавить detour-reference check
  в `validateConfig` → ловить весь класс §080-багов на Dart-уровне ДО
  native core. NB: `subscription_controller._generate` сейчас только
  логирует fatal, не блокирует — отдельный вопрос enforcement'а.
- **§082 candidate — auto-migration старых bare `overrideDetour`.** Review
  рекомендует single-match auto-migration: для каждого entry с непустым
  `overrideDetour`, если ровно **один** UserServer-узел имеет
  `n.tag == overrideDetour` с непустым prefix → переписать в `_withPrefix`
  форму. На 0/>1 кандидатов — graceful degradation (re-pick). Тихо чинит
  сломанные сетапы. Против текущего spec-решения (только graceful
  degradation) — требует version bump в `lxbox_settings.json`. Решение
  отложено: меняет storage существующих юзеров, нужно явное согласование.

Принятые как-есть ограничения (документированы выше / в коде):
collision-suffix `-N` dangling (редкий), subscription_detail picker без
stale-value guard (не регрессия, self-repairing), chained detours не
предлагаются как targets (отдельная фича).

## Файлы

- `app/lib/screens/subscription_detail_screen.dart` — `_showOverrideDetourPicker`
  строит display-form.
- `app/lib/screens/node_settings_screen.dart` — `_load` строит display-form
  + self-exclude по display-form.
- `app/test/builder/detour_append_replace_test.dart` — +3 теста (§080
  group): display-form override → valid detour ref; bare-form → dangling
  (документирует баг); empty-prefix → regression-free.
- `docs/spec/tasks/080-detour-override-picker-prefix-aware.md` (этот файл).
- `CHANGELOG.md` — entry под `### Fixed` (v1.9.1).

## Acceptance criteria

- [x] Picker показывает display-form (`'$tagPrefix $base'`) для UserServer'ов
      с непустым prefix.
- [x] Сохранённый `overrideDetour` совпадает с эмитированным outbound tag →
      detour резолвится (builder test: detour ref exists in outbounds).
- [x] Bare-form (старое поведение) документирован как dangling в тесте.
- [x] Empty-prefix UserServer: display == bare, regression-free.
- [x] Self-exclude в node_settings по display-form (нода не detour сама себе).
- [ ] Manual: UserServer с prefix как detour target → VPN стартует, detour
      применяется (verify via Debug API `/config` outbound detour ref).
