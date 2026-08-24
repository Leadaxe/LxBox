part of '../settings_storage.dart';

// §125 — Направления роутинга (`directions[]`) для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Паттерн read-весь-объект → mutate-copy → rewrite-atomically
// идентичен `network.dart:_setGroupPing` (эталон per-group storage).
//
// `directions[]` заменяет `enabled_groups[]` (deprecated) и статичные
// `template.presetGroups` как source-of-truth состава Направлений. Миграция
// (`_migrateDirectionsIfNeeded`) на первом запуске seed'ит directions из template.

/// §248 — счётчики вылеченных ссылок при мутации Направления (SnackBar в UI,
/// тело ответа Debug API). `rules` — route_final/custom-rule → vpn-1
/// (только disable/delete, §274 снял flag-set-триггер); `detours` —
/// overrideDetour/member.detour → '' (None) при disable/delete/flag-unset.
typedef DirectionHealResult = ({int rules, int detours});

Future<List<Direction>> _getDirections() async {
  final data = await _load();
  final raw = data['channels'] as List<dynamic>? ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(Direction.fromJson).toList();
}

Future<void> _setDirections(List<Direction> directions, {bool flush = true}) async {
  final data = await _load();
  data['channels'] = directions.map((c) => c.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// Первый свободный 'vpn-N' (N∈2..10; vpn-1 всегда существует инвариантом).
/// throws [StateError] при лимите [kMaxDirections].
Future<Direction> _addDirection({String? label}) async {
  final directions = (await _getDirections()).toList();
  if (directions.length >= kMaxDirections) {
    throw StateError('direction limit ($kMaxDirections) reached');
  }
  final used = directions.map((c) => c.tag).toSet();
  final tag = [for (var i = 2; i <= kMaxDirections; i++) 'vpn-$i']
      .firstWhere((t) => !used.contains(t));
  // §198 — дефолтный label с цифрой-в-кружке по номеру (VPN ②…VPN ⑩).
  final defaultLabel = defaultDirectionLabel(directionNumberOf(tag) ?? 0);
  final ch = Direction(tag: tag, label: label ?? defaultLabel, enabled: true);
  directions.add(ch);
  await _setDirections(directions);
  return ch;
}

Future<DirectionHealResult> _updateDirection(Direction direction) async {
  final directions = (await _getDirections()).toList();
  final i = directions.indexWhere((c) => c.tag == direction.tag);
  if (i < 0) throw StateError('direction not found: ${direction.tag}');
  // §202 — переход enabled: true → false делает Направление невалидной мишенью
  // (как удаление): билдер деградирует только ВЫХЛОП конфига, а route_final /
  // custom-rule outbound в storage остаются висеть на выключенном теге →
  // «надо идти пересохранять». Лечим storage сразу (route_final / правило →
  // vpn-1). Решение B (28.06.2026): необратимо — повторное включение Направления
  // НЕ воскрешает старую ссылку (правила привязаны к активной конфигурации).
  //
  // §248/§274 — flag-unset лечит detour-ссылки → '' (Направление уходит из пикера
  // §239, ссылки на него как detour-мишень теряют смысл). Flag-SET rules НЕ
  // лечит (§274): detour-флаг — разрешение, Направление остаётся валидной целью
  // правил. Disable лечит ОБА рода (Направление перестаёт быть какой-либо
  // мишенью). Та же необратимость Решения B.
  final was = directions[i];
  directions[i] = direction;
  final disabling = was.enabled && !direction.enabled;
  final flagUnset = was.isDetour && !direction.isDetour;
  var rules = 0;
  var detours = 0;
  if (disabling || flagUnset) {
    await _setDirections(directions, flush: false); // единый flush ниже
    if (disabling) rules = await _healDirectionRefs(direction.tag);
    detours = await _healDetourDirectionRefs(direction.tag);
    await _save();
  } else {
    await _setDirections(directions);
  }
  return (rules: rules, detours: detours);
}

/// Удалить Направление. vpn-1 неудаляем (throws). Любая ссылка на удалённый tag
/// (route_final / custom-rule outbound → vpn-1; §248 detour-ссылки → '')
/// немедленно лечится для UI-консистентности; билдер дополнительно
/// схлопывает dangling при сборке (§172-паттерн).
Future<DirectionHealResult> _deleteDirection(String tag) async {
  if (tag == 'vpn-1') throw StateError('vpn-1 is not deletable');
  final directions = (await _getDirections()).toList()
    ..removeWhere((c) => c.tag == tag);
  await _setDirections(directions, flush: false); // единый flush ниже
  final rules = await _healDirectionRefs(tag);
  final detours = await _healDetourDirectionRefs(tag);
  await _save();
  return (rules: rules, detours: detours);
}

/// Перевод rules-ссылок на Направление → 'vpn-1'. Вызывается, когда Направление
/// перестаёт быть валидной route-мишенью: удалён (§125 F4.5) или выключен
/// (§202). Detour-flag-set больше НЕ триггер (§274: флаг — разрешение,
/// Направление остаётся целью правил). Возвращает число вылеченных ссылок.
/// Всё flush:false — атомарный `_save()` на вызывающем.
///
/// §248 — ссылка «на Направление» = его тег ИЛИ тег auto-двойника `<tag>-auto`:
/// UI-пикеры двойник не предлагают, но Debug API / правленный backup могут
/// записать что угодно.
Future<int> _healDirectionRefs(String deletedTag) async {
  final autoTag = '$deletedTag-auto';
  var count = 0;
  // route_final
  final routeFinal = await SettingsStorage.getRouteFinal();
  if (routeFinal == deletedTag || routeFinal == autoTag) {
    await SettingsStorage.saveRouteFinal('vpn-1', flush: false);
    count++;
  }
  // custom-rule outbounds — kind-agnostic через общие `outbound`/`withOutbound`:
  // inline/srs — поле `outbound`; preset — override `varsValues['outbound']`
  // (§033 Expansion §5), без heal он уезжал в expandPreset dangling-тегом →
  // fatal DanglingOutboundRef, VPN не стартует; json — '' (deletedTag всегда
  // непустой 'vpn-N', не сматчит). reject/direct-out — не direction-tag'и, под
  // deletedTag не подпадут. Build-time страховки для rule-outbound НЕТ
  // (healDanglingDetours §172 чинит только detour-поля, валидатор §141 P0.1
  // блокирует, не лечит) — storage-heal здесь единственное самолечение.
  final rules = await SettingsStorage.getCustomRules();
  var changed = false;
  final healed = rules.map((r) {
    if (r.outbound == deletedTag || r.outbound == autoTag) {
      changed = true;
      count++;
      return r.withOutbound('vpn-1');
    }
    return r;
  }).toList();
  if (changed) {
    await SettingsStorage.saveCustomRules(healed, flush: false);
  }
  return count;
}

/// §248 — сброс detour-ссылок на Направление → '' (None/direct): overrideDetour
/// одиночки/подписки/папки + личные `FolderMember.detour`. Вызывается, когда
/// Направление перестаёт быть detour-мишенью: галка detour снята, Направление выключен
/// или удалён. Необратимо (Решение B §202). Возвращает число сброшенных.
///
/// Интра-омонимия: значение, равное bare-тегу члена ТОЙ ЖЕ папки, — интра-
/// ссылка на члена (приоритет bareIndex в FolderDetourPlan), Направление тут ни
/// при чём — пропускаем. Ссылка «на Направление» = tag ИЛИ `<tag>-auto` (двойник).
/// Всё flush:false — атомарный `_save()` на вызывающем.
Future<int> _healDetourDirectionRefs(String tag) async {
  final lists = await _getServerLists();
  var count = 0;
  var changed = false;
  final healed = <ServerList>[];
  for (final l in lists) {
    // Общее ядро с in-memory ресинком контроллера (server_list.dart).
    final r = clearDetourDirectionRefs(l, tag);
    if (r.healed != null) {
      changed = true;
      count += r.count;
      healed.add(r.healed!);
    } else {
      healed.add(l);
    }
  }
  if (changed) await _saveServerLists(healed, flush: false);
  return count;
}

// ---------------------------------------------------------------------------
// §125 F0.3 — Миграция enabled_groups[] → directions[] (one-shot, first-run seed).
//
// Guard-ключ `channels_migrated` (паттерн `_hasDefaultsSeeded`). Принимает
// template.groupTemplates параметром (storage-слой не знает про template —
// вызывается из main() init с готовым шаблоном). Идемпотентна: повторный вызов
// при уже существующем `directions` или поднятом флаге — no-op.
//
// §267 — сид собирается из `default_channels` (плоский список tag/label/enabled)
// + общего json-шаблона `channel`; auto-подгруппа заводится когда `direction.include`
// содержит роль `auto`. Раньше итерировали `preset_groups` со скипом ✨auto —
// теперь auto больше не «Направление в списке», костыль-скип ушёл.
// ---------------------------------------------------------------------------

Future<void> _migrateDirectionsIfNeeded(
  GroupTemplates gt, {
  Map<String, String> varDefaults = const {},
}) async {
  final data = await _load();
  if (data['channels'] is List) return; // уже есть — не трогаем
  if (data['channels_migrated'] == true) return; // мигрировано (пусто) — не пересеивать

  final enabled = await SettingsStorage.getEnabledGroups(); // legacy set
  final hasAuto = gt.direction.include.contains('auto');
  final directions = <Direction>[];
  for (final dc in gt.defaultDirections) {
    final isEnabled = dc.tag == 'vpn-1'
        ? true // vpn-1 форсим (продуктовый инвариант)
        : (enabled.isEmpty ? dc.defaultEnabled : enabled.contains(dc.tag));
    final auto = hasAuto
        ? _seedAutoFromTemplate(gt.auto, varDefaults: varDefaults)
        : null;
    directions.add(
        Direction.seedFromDefault(dc, gt.direction, enabled: isEnabled, auto: auto));
  }

  data['channels'] = directions.map((c) => c.toJson()).toList();
  data['channels_migrated'] = true;
  SettingsStorage._cache = data;
  await _save();
}

/// `DirectionAuto` из `group_templates.auto` (urltest-шаблон). ВНИМАНИЕ: `options`
/// здесь — СЫРОЙ template (`@urltest_*`-плейсхолдеры НЕ резолвены — var-
/// substitution идёт позже, в билдере). Поэтому значения могут быть
/// `"@urltest_tolerance"`-строкой, числом ИЛИ числом-в-строке. Парсим терпимо:
/// нерезолвенный `@`-плейсхолдер или мусор → [varDefaults] той же переменной.
///
/// §327 — на плейсхолдере раньше срабатывали литералы в коде (`50`, `'5m'`), и
/// в Направления на чистой установке садились значения, расходившиеся с шаблоном
/// (`urltest_tolerance: 30`, `urltest_interval: 15m`). Теперь `@var` резолвится
/// по `default_value` — единственному источнику дефолта.
/// idle_timeout="30m", interrupt=false (мягкий urltest) — своих var не имеют.
DirectionAuto _seedAutoFromTemplate(
  AutoTemplate at, {
  Map<String, String> varDefaults = const {},
}) {
  final opts = at.options;

  /// `"@urltest_x"` → `default_value` этой var (или null, если её нет).
  String? fromVar(Object? v) {
    if (v is! String || !v.startsWith('@')) return null;
    final d = varDefaults[v.substring(1)];
    return (d != null && d.isNotEmpty) ? d : null;
  }

  // Строка-значение, но не нерезолвенный `@var`-плейсхолдер.
  String? str(Object? v) {
    if (v is! String || v.isEmpty || v.startsWith('@')) return null;
    return v;
  }

  // tolerance из num / числа-в-строке; плейсхолдер/мусор → null.
  int? toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String && !v.startsWith('@')) return int.tryParse(v.trim());
    return null;
  }

  // Порядок: значение из template.options → default_value его `@var` →
  // дефолт `DirectionAuto` (последний рубеж, если var из шаблона исчезла).
  const fallback = DirectionAuto();
  return DirectionAuto(
    url: str(opts['url']) ?? fromVar(opts['url']) ?? fallback.url,
    interval: str(opts['interval']) ?? fromVar(opts['interval']) ?? fallback.interval,
    tolerance: toInt(opts['tolerance']) ??
        int.tryParse(fromVar(opts['tolerance']) ?? '') ??
        fallback.tolerance,
    idleTimeout: fallback.idleTimeout,
    interruptExistConnections: fallback.interruptExistConnections,
  );
}
