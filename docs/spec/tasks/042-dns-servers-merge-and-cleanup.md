# 042 — DNS servers list: 3-tier merge + stale-fields cleanup

> ⚠ **Заменено [§043 DNS servers as kind-discriminated refs](./043-dns-servers-refs-by-kind.md).** Был промежуточный план: full-body snapshot + 3-tier merge с shape comparison. На имплементации стало ясно что архитектура не симметрична с §041 DNS rules и оставляет фрагильность (order-sensitive jsonEncode, stale fields на template-обновлениях, длинные badge'и). §043 переделал на refs-by-kind — точная симметрия с DNS rules, тривиальная override-detection через `kind == 'inline'`, auto-discovery + orphan cleanup как в `resolveDnsRulesList`.

| Поле | Значение |
|------|----------|
| Статус | Superseded by §043 |
| Дата | 2026-05-07 |
| Связанные spec'ы | [`014 dns settings`](../features/014%20dns%20settings/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`039 empty template DNS rules`](./039-empty-template-dns-rules.md) |
| Затронутые файлы | `app/lib/screens/dns_settings_screen.dart`, `app/lib/services/builder/build_config.dart` (опционально, см. ниже), тесты |

## Цель

Привести построение списка DNS-серверов в `DnsSettingsScreen` к корректному 3-tier merge'у с tag-дедупом и подтягиванием template-обновлений для уже-сохранённых записей. Фиксит два связанных бага, выявленных live на v1.6.0:

1. **Новые серверы из template не появляются у existing-юзеров.** После tag rename `direct_dns_resolver` → `google_udp` в [§039](./039-empty-template-dns-rules.md), юзер с saved DNS-серверами **не видит** `google_udp` ни в списке, ни в DNS Final dropdown'е — потому что `_servers = userServers` (XOR с template).
2. **Stale fields в user-saved записях с tag'ами совпадающими с template.** Например, `google_doh` в storage юзера содержит `detour: "vpn-1"` (из старой версии template'а где это было задано), хотя в актуальном template'е (v1.6.0) `google_doh` — без detour'а; `google_doh_vpn` — отдельный сервер для via-VPN кейса. User-storage заморожен на момент сохранения, последующие template-эволюции не подхватываются.

## Текущее поведение (баг)

`dns_settings_screen.dart:101`:
```dart
final servers = userServers.isNotEmpty ? userServers : templateServersRaw;
//                       ^^^^^^^^^ XOR — либо одно, либо другое
```

`_enabledServerTags` getter (после §039 fix'а):
- Iterates `_servers` (= user OR template, XOR)
- Iterates `_presetServersWithLabel`
- Не учитывает template-overlay для случая «у юзера есть saved, но template добавил новые»

Семантически: storage юзера = source of truth целиком, template = только initial-default для пустого storage. Это слишком грубо.

## Дизайн

### Layered model

User-saved storage = **переопределения и пользовательские серверы**, а не полный snapshot. Template = **canonical defaults** (актуальный shape для known tag'ов + список known tag'ов). Preset = **dynamically-injected** серверы (live overlay из активных custom_rules.kind:preset).

### Resolve order для UI render и `_enabledServerTags`

Tag-priority (first wins) — **user → preset → template**, каждый следующий слой добавляет только новые tag'и:

1. **User-saved** (`_servers` из storage). Юзерские overrides + кастомные серверы (всё подряд, тег-приоритет).
2. **Preset-expanded** (`_presetServersWithLabel`). Только tag'и которых **нет** в user-saved. Preset технически может переписать template (если в active preset'е DNS-сервер с тем же tag'ом что в template'е — preset wins).
3. **Template** (`_templateServersRaw`). Только tag'и которых нет ни в user-saved, ни в preset.

Логика: preset = «активная динамическая конфигурация для текущей сессии юзера», template = «статические defaults» — preset более конкретен и должен побеждать на коллизии. User-saved — финальный override юзера.

```dart
List<Map<String, dynamic>> get _displayedServers {
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  void add(List<Map<String, dynamic>> src, {String? sourceLabel}) {
    for (final s in src) {
      final tag = s['tag'] as String?;
      if (tag == null || tag.isEmpty || seen.contains(tag)) continue;
      seen.add(tag);
      final annotated = Map<String, dynamic>.from(s);
      if (sourceLabel != null) annotated['_origin'] = sourceLabel;
      out.add(annotated);
    }
  }
  add(_servers, sourceLabel: 'user');
  add(_presetServersWithLabel, sourceLabel: 'preset');
  add(_templateServersRaw, sourceLabel: 'template');
  return out;
}
```

`_enabledServerTags` — то же самое плюс filter `enabled != false`.

Override-detection (`_isOverridden`) lookup'ит canonical в том же order'е: сначала preset, потом template — то что увидел бы юзер если бы убрал свой override через Reset.

### Tag-collision (user vs template): override + reset UX

**Проблема:** user-saved `{tag: google_doh, detour: vpn-1, ...}` и template'овский `{tag: google_doh, /* без detour */, ...}`. Это могут быть две разных ситуации:

1. **Юзер сознательно переопределил** template-сервер (например, добавил `detour: vpn-1` чтобы Google DoH ходил через VPN-1).
2. **Stale snapshot** старой версии template'а который автоматически переходил в storage до §039 rename'ов. Юзер не помнит этих полей и хочет fresh template-shape.

Различить программно нельзя — поэтому **не делаем silent rebase**. Вместо этого:

- В UI tile с tag'ом совпадающим с template, но user-saved отличается от template → badge **"Template, overridden"** (вместо просто `Template`).
- Кнопка **"Reset to template"** в edit-mode (или contextmenu) — удаляет user-saved entry для этого tag'а, на следующем render'е показывается чистый template-overlay.
- Удаление user-saved entry для template-tag'а != потеря сервера (template overlay есть всегда).

```
┌──────────────────────────────────────────┐
│ google_doh                       [Template, overridden] │
│ HTTPS · dns.google:443                                  │
│ • detour: vpn-1   ← user override         [↺ Reset]    │
│ Enabled: ●                                              │
└──────────────────────────────────────────┘
```

Detection «overridden»: shape user-saved ≠ shape template (по любому полю кроме `enabled`/`description` — те мы считаем нормальным user-state, не override'ом). Если совпадают по shape (deep equal) — badge просто `Template`, без `overridden`.

```dart
bool _isOverridden(Map<String, dynamic> user, Map<String, dynamic> tpl) {
  // Сравниваем shape без mutable user-fields
  Map<String, dynamic> stripMutable(Map<String, dynamic> m) {
    final out = Map<String, dynamic>.from(m);
    out.remove('enabled');
    out.remove('description');
    return out;
  }
  return jsonEncode(stripMutable(user)) != jsonEncode(stripMutable(tpl));
}
```

**Reset action:**

```dart
Future<void> _resetServerToTemplate(String tag) async {
  _servers.removeWhere((s) => s['tag'] == tag);
  await SettingsStorage.saveDnsServers(_servers);
  // Re-render показывает template overlay для этого tag'а.
}
```

**Для full-custom user-серверов** (tag нет в template) — кнопки Reset нет (нечего восстанавливать); badge `User`.

### Storage write semantics

- **Edit user-saved server** → нормальный write, обновляем `_servers[i]`, save.
- **Edit template-only server** (юзер впервые тапнул toggle) → копируем server в `_servers` через `_rebaseOnTemplate` (чтобы получить актуальный shape) с применённым изменением → save.
- **Edit preset-server** → невозможно (read-only); если юзер хочет override, делает manual add того же tag'а — он попадёт в user-saved и победит preset по dedup'у.

### Migration

Existing-юзеры:
- Никакой active migration'а / silent rebase'а — это лишает юзера его осознанных override'ов.
- На ближайший render новый `_displayedServers` getter покажет union с tag-приоритетом, plus badge `Template, overridden` для overlap-случаев.
- Юзер сам решает — оставить override или нажать Reset для возврата к template-shape.

### Builder consequences

`build_config.dart` дедупит DNS-серверы по tag (first-wins) — `_servers` идёт первым, поэтому **stale поля у user-saved будут попадать в final config**. Это не баг builder'а — это design: юзер хочет именно так (его override). Если юзер хочет fresh template — Reset кнопка → user-saved entry удаляется → builder возьмёт template'овский shape.

Никакой rebase в builder'е не делаем — semantic single-source-of-truth: storage = что юзер реально хочет.

## Acceptance

- [ ] **3-tier merge:** existing user после v1.6.0 upgrade видит `google_udp` в DNS Settings list **и** в DNS Final dropdown'e (template-overlay подхватился).
- [ ] **Override badge:** existing user с `google_doh.detour=vpn-1` в storage — UI tile показывает badge `Template, overridden` + кнопку Reset.
- [ ] **Reset to template:** клик Reset убирает user-saved entry для этого tag'а → на следующем render'е tile показывает чистый template-shape (без detour'а), badge становится просто `Template`.
- [ ] **No silent migration:** юзер с осознанным override'ом не теряет его (не делаем `_rebaseOnTemplate` в `_load`).
- [ ] **User-only servers preserved:** юзерский кастомный сервер с tag'ом не в template/preset — отображается как раньше, не теряет полей; badge `User`; кнопки Reset нет.
- [ ] **Preset overlay:** активный ru-direct preset → `yandex_udp`/`yandex_doh`/`yandex_dot` отображаются с badge `Preset: ru-direct`. Если юзер вручную добавит сервер с tag=`yandex_udp`, его user-tile победит preset (`User` badge, либо `Template, overridden` если template тоже содержит этот tag — но `yandex_*` template'ом не содержит, только preset'ом).
- [ ] **First-install path:** fresh install → `_servers` пустой → UI показывает template overlay (badge `Template`) → первый toggle копирует template в `_servers` с unchanged shape → save в storage; tile продолжает показывать badge `Template` (shape совпадает, не override).
- [ ] **DNS Final dropdown** (как и Default Domain Resolver, per-rule) — содержит все enabled-tag'и из union'а (user → template → preset), даже если template-теги перекрыты user-overrides — берётся user-shape.
- [ ] **Тесты:** unit на `_displayedServers` merge-приоритет; на `_isOverridden` (deep-equal без `enabled`/`description`); на `_resetServerToTemplate` flow.

## Не в скопе

- **Удаление user-only серверов которые юзер давно не использует** — orphan-cleanup для unused, но определить «давно не использует» сложно (последний enabled? последний edit?). Отдельная задача если useful.
- **Migration UI** — пушить ничего не показываем юзеру, всё прозрачно.
- **Schema validation** — sing-box сам ругнёт на reload если в каком-то tag'е inconsistent fields. Builder-time валидация — отдельная задача.

## Risks

| Риск | Mitigation |
|---|---|
| Юзер случайно потерял свой custom-edit (например, заменил template'овский `server` field) — `_rebaseOnTemplate` это переопределит | Rebase **только для tag'ов в template**; full-custom user-серверов не трогает. Если юзер хочет override template'овского tag'а — он вынужден будет дать своему серверу другой tag (например `google_doh_user`). Это design trade-off. |
| One-shot migration в `_load` пишет в storage без user-action | Только если что-то реально изменилось (сравнение shape'ов до/после rebase). Если изменений нет — без write'а. |
| Builder-time дублирование логики если решим не делать migration | Использовать общий helper `mergeDnsServers(user, template, presets)` в `lib/services/dns_servers_merge.dart`, вызываем и из UI, и из builder'а. |

## План имплементации

1. **`dns_settings_screen.dart`:**
   - Поднять `_templateServersRaw` и `_templateByTag` как state-fields.
   - Добавить getter `_displayedServers` (3-tier merge с tag-dedup и `_origin` annotation: `user`/`template`/`preset`).
   - `_isOverridden(user, tpl)` helper — deep-equal без `enabled`/`description`.
   - `_enabledServerTags` рефакторить через `_displayedServers` (просто filter `enabled != false`).
   - UI render списка — итерируется через `_displayedServers`, badge по `_origin` (+ `, overridden` если detected).
2. **Reset-кнопка:** в edit-mode (или contextmenu для template-tile с override'ом) — `_resetServerToTemplate(tag)` удаляет user-saved entry и save.
3. **Edit handlers:** `_addServer` / `_editServer` / `_toggleServer` — на edit template-only сервера копируют template-shape в `_servers` с применённым изменением + save. На edit user-saved или overridden — обычный flow.
4. **Тесты:**
   - `dns_settings_merge_test.dart` — unit на 3-tier merge + tag-priority.
   - `is_overridden_test.dart` — `_isOverridden` (overlap по shape без mutable fields → false; различающиеся `server` → true; различающиеся `enabled` → false).
   - Интеграционный widget test для `dns_settings_screen` — все 3 tier'а с правильными badge'ами + reset flow (опционально).
5. `flutter analyze` + `flutter test` + APK + smoke на устройстве: existing-юзер видит `google_udp` после установки; `google_doh` со stale detour'ом — badge `Template, overridden` + Reset кнопка; клик Reset убирает stale поля.
