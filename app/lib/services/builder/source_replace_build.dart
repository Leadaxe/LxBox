/// Свёртка источника в группу на сборке (фича 565, фаза B; контракт 1.1.78
/// §74 п.1–5, эталон лаунчера `core/config/folder_replaces.go`).
///
/// `ServerList.build` у свёрнутого источника не отдаёт узлы в пул
/// Направлений, а копит их в [ReplacePlan]; `buildConfig` после всех
/// отбраковок узлов (fail-closed detour, гард реестра) разворачивает план в
/// группы [materializeReplaceGroups]:
///
/// - `manual` → ручной селектор `tag` (`interrupt_exist_connections: true`);
/// - `auto` → автовыбор `tag` с параметрами `auto`, провайдерские группы
///   источника в состав не входят;
/// - `both` → автовыбор `<tag>-auto`, затем селектор `tag` с первой опцией и
///   умолчанием `<tag>-auto`.
///
/// Ноль живых узлов — группа не пишется (пустую ядро не принимает), и
/// называется кодом `replace_group_empty` в отчёте сборки (контракт 1.1.80).
/// Тег, занятый другим объявленным именем, — `replace_tag_conflict`: свёртка
/// не собирается, источник идёт несвёрнутым ([findReplaceTagConflicts]).
library;

import '../../models/direction.dart';
import '../../models/node_warning.dart';
import '../../models/server_list.dart';
import '../../models/singbox_entry.dart';
import '../../models/source_replace.dart';
import '../contract/group_genus.dart';

/// §77 п.5 (контракт 1.1.80) — свёртка, чей тег (или двойник `<tag>-auto`)
/// совпал с другим ОБЪЯВЛЕННЫМ именем: Направлением или его двойником
/// (`direction`), свёрткой источника выше по списку (`replace`; первая по
/// списку владеет именем) или тегом шаблона (`system`). Узел-тёзка
/// конфликтом не считается — он получает суффикс.
class ReplaceConflict {
  const ReplaceConflict(this.listId, this.warning);

  /// Источник, чья свёртка не собирается.
  final String listId;

  /// `replace_tag_conflict {tag, other}`.
  final RegistryWarning warning;
}

/// Конфликты имён свёрток включённых источников [lists] в порядке списка.
List<ReplaceConflict> findReplaceTagConflicts(
  Iterable<ServerList> lists, {
  required Set<String> directionNames,
  required Set<String> systemNames,
}) {
  final out = <ReplaceConflict>[];
  final claimed = <String>{};
  for (final l in lists) {
    if (!l.enabled) continue;
    final r = l.replace;
    if (r == null || r.tag.trim().isEmpty) continue;
    String? other;
    String? clash;
    for (final n in r.names) {
      final o = directionNames.contains(n)
          ? 'direction'
          : claimed.contains(n)
              ? 'replace'
              : systemNames.contains(n)
                  ? 'system'
                  : null;
      if (o != null) {
        other = o;
        clash = n;
        break;
      }
    }
    if (other == null) {
      claimed.addAll(r.names);
      continue;
    }
    out.add(ReplaceConflict(
      l.id,
      RegistryWarning(
        code: 'replace_tag_conflict',
        params: {'tag': clash!, 'other': other},
      ),
    ));
  }
  return out;
}

/// `@имя` в строковом параметре автовыбора свёртки — ссылка на переменную
/// шаблона, как у Направления: значение берётся из [resolveVar], без
/// значения — умолчание [fallback] (корпус `fold_auto_inherits_template_vars`).
DirectionAuto resolveAutoVars(
  DirectionAuto a,
  Object? Function(String name)? resolveVar,
) {
  if (resolveVar == null) return a;
  const fallback = DirectionAuto();
  String pick(String v, String def) {
    if (!v.startsWith('@')) return v;
    final r = resolveVar(v.substring(1))?.toString() ?? '';
    return r.isEmpty ? def : r;
  }

  return a.copyWith(
    url: pick(a.url, fallback.url),
    interval: pick(a.interval, fallback.interval),
    idleTimeout: pick(a.idleTimeout, fallback.idleTimeout),
  );
}

/// Свёрнутый источник до развёртки: члены в порядке модели источника.
class ReplacePlan {
  ReplacePlan({required this.replace, required this.source});

  final SourceReplace replace;

  /// Как назвать источник в отчёте сборки.
  final String source;

  /// Члены ручного селектора: узлы источника и его провайдерские группы.
  final List<SingboxEntry> selectorMembers = [];

  /// Члены автовыбора: только узлы (группа внутри автовыбора мерила бы уже
  /// выбранный ею узел, §74 п.2 `NoGroupMembers`).
  final List<SingboxEntry> autoMembers = [];
}

/// Итог развёртки всех планов сборки.
class ReplaceBuild {
  /// Группы в порядке эмиссии: внутри источника автовыбор раньше селектора.
  final List<Map<String, dynamic>> groups = [];

  /// Кандидаты пула Направлений: по одному на источник — `tag` (у `both`
  /// двойник вторым кандидатом не идёт, §74 п.5).
  final List<String> candidates = [];

  /// Все эмитированные имена свёрток (`tag` и двойник): цели правил,
  /// `route.final` и опций Направлений.
  final Set<String> emitted = {};

  /// Объявленные, но не эмитированные имена (ноль узлов): ссылки на них
  /// вычищает сборка.
  final Set<String> dropped = {};
}

/// Автовыбор с параметрами [a] — одна форма у двойника Направления и у
/// свёртки (§74 п.2 `buildTwin`). Ключи и порядок — как у двойника
/// Направления: `balancer` только у `round_robin`, `passive_check` — только
/// `true` (omitempty ядра).
Map<String, dynamic> buildAutoGroup({
  required String tag,
  required List<String> outbounds,
  required DirectionAuto a,
  bool passiveCheck = false,
}) {
  final group = <String, dynamic>{
    'tag': tag,
    'type': GroupGenus.auto,
    'outbounds': outbounds,
    'url': a.url,
    'interval': a.interval,
    'tolerance': a.tolerance,
    'idle_timeout': a.idleTimeout,
    'interrupt_exist_connections': a.interruptExistConnections,
  };
  if (passiveCheck) group['passive_check'] = true;
  if (a.mode == UrltestMode.roundRobin) {
    group['mode'] = a.mode.wire;
    group['balancer'] = <String, dynamic>{
      'pool': a.pool,
      'pool_tolerance': a.poolTolerance,
      // Пустой набор ядро схлопывает в умолчание; выключение — ["none"].
      'sticky_hash': a.stickyHash.isEmpty
          ? const ['none']
          : a.stickyHash.map((k) => k.wire).toList(),
    };
  }
  return group;
}

/// Развёртка [plans] в группы. [alive] — теги узлов, переживших отбраковки
/// сборки; выпавший член в состав не идёт. [code] получает
/// `replace_group_empty` — один на свёртку, у которой не написано ни одной
/// группы; [warn] — строку на двойник, выпавший при живом селекторе.
/// [resolveVar] раскрывает `@имя` в параметрах автовыбора ([resolveAutoVars]).
ReplaceBuild materializeReplaceGroups(
  List<ReplacePlan> plans, {
  required Set<String> alive,
  bool passiveCheck = false,
  void Function(String line)? warn,
  void Function(RegistryWarning w)? code,
  Object? Function(String name)? resolveVar,
}) {
  final out = ReplaceBuild();
  for (final p in plans) {
    final r = p.replace;
    final tag = r.tag.trim();
    List<String> live(List<SingboxEntry> es) {
      final seen = <String>{};
      return [
        for (final e in es)
          if (alive.contains(e.tag) && seen.add(e.tag)) e.tag,
      ];
    }

    final autoMembers = live(p.autoMembers);
    final selectorMembers = live(p.selectorMembers);
    String? autoTag;
    if (r.hasAuto) {
      if (autoMembers.isNotEmpty) {
        autoTag = r.autoTag;
        out.groups.add(buildAutoGroup(
          tag: autoTag,
          outbounds: autoMembers,
          a: resolveAutoVars(r.autoOrDefault, resolveVar),
          passiveCheck: passiveCheck,
        ));
        out.emitted.add(autoTag);
      }
    }
    if (r.hasSelector) {
      // `both`: двойник первой опцией и умолчанием, только если он написан.
      final options = [
        ?autoTag,
        for (final t in selectorMembers)
          if (t != autoTag) t,
      ];
      if (options.isNotEmpty) {
        out.groups.add({
          'tag': tag,
          'type': GroupGenus.manual,
          'outbounds': options,
          'default': ?autoTag,
          'interrupt_exist_connections': true,
        });
        out.emitted.add(tag);
      }
    }
    if (!r.names.any(out.emitted.contains)) {
      // Контракт 1.1.80 — один код на свёртку (у `both` пустеют обе
      // половины): группа в конфиг не идёт, правила и Направления на неё не
      // сработают.
      code?.call(RegistryWarning(
        code: 'replace_group_empty',
        params: {'tag': tag, 'mode': r.mode.name},
      ));
    } else if (r.hasAuto && autoTag == null) {
      // Селектор `both` написан, а двойник — нет: у источника есть только
      // члены селектора (провайдерские группы), а узлов автовыбора нет.
      warn?.call(_twinSkippedLine(r.autoTag, p.source));
    }
    if (out.emitted.contains(tag)) out.candidates.add(tag);
    for (final n in r.names) {
      if (!out.emitted.contains(n)) out.dropped.add(n);
    }
  }
  return out;
}

String _twinSkippedLine(String tag, String source) =>
    'Replace group "$tag" of "$source" was skipped: the source has no '
    'enabled nodes for auto selection, and an empty group would stop the VPN '
    'core.';

/// §74 п.4 — правила `route.rules` с целью из [dropped] (имя свёртки, чья
/// группа не написана): цель → `route.final`, если он в [liveFinals], иначе
/// правило снимается. Эталон — `cleanDanglingOutboundRefInRule` лаунчера.
///
/// Правило внутри логического тела (`type: logical`, вложенные `rules`)
/// судится так же, рекурсивно: вложенное правило без живой цели снимается,
/// логическое правило, оставшееся без вложенных, снимается само.
/// Возвращает строки отчёта сборки, по одной на правило.
List<String> retargetRulesOffDroppedReplaces(
  Map<String, dynamic> route,
  Set<String> dropped, {
  required Set<String> liveFinals,
}) {
  final rules = route['rules'];
  if (rules is! List || dropped.isEmpty) return const [];
  final fin = route['final'];
  final finalTag = fin is String && liveFinals.contains(fin) ? fin : null;
  final lines = <String>[];
  route['rules'] =
      _retargetList(rules, dropped, finalTag, lines, prefix: 'Route rule #');
  return lines;
}

List<dynamic> _retargetList(
  List<dynamic> rules,
  Set<String> dropped,
  String? finalTag,
  List<String> lines, {
  required String prefix,
}) {
  final kept = <dynamic>[];
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    if (r is! Map) {
      kept.add(r);
      continue;
    }
    final name = '$prefix$i';
    final inner = r['rules'];
    if (r['type'] == 'logical' && inner is List) {
      final before = inner.length;
      final left = _retargetList(inner, dropped, finalTag, lines,
          prefix: '$name, nested rule #');
      r['rules'] = left;
      if (left.isEmpty && before > 0) {
        lines.add('$name lost all its nested rules to replace groups that '
            'were not built — the rule was removed.');
        continue;
      }
    }
    final out = r['outbound'];
    if (out is! String || !dropped.contains(out)) {
      kept.add(r);
      continue;
    }
    if (finalTag != null) {
      r['outbound'] = finalTag;
      kept.add(r);
      lines.add('$name went to replace group "$out", which was not built — '
          'it now goes to the default route "$finalTag".');
    } else {
      lines.add('$name went to replace group "$out", which was not built — '
          'the rule was removed.');
    }
  }
  return kept;
}
