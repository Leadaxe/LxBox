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
/// называется строкой отчёта сборки.
library;

import '../../models/direction.dart';
import '../../models/singbox_entry.dart';
import '../../models/source_replace.dart';
import '../contract/group_genus.dart';

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
/// сборки; выпавший член в состав не идёт. [warn] получает строку на каждую
/// не написанную группу.
ReplaceBuild materializeReplaceGroups(
  List<ReplacePlan> plans, {
  required Set<String> alive,
  bool passiveCheck = false,
  void Function(String line)? warn,
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
          a: r.autoOrDefault,
          passiveCheck: passiveCheck,
        ));
        out.emitted.add(autoTag);
      } else {
        warn?.call(_skippedLine(r.autoTag, p.source));
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
      } else {
        warn?.call(_skippedLine(tag, p.source));
      }
    }
    if (out.emitted.contains(tag)) out.candidates.add(tag);
    for (final n in r.names) {
      if (!out.emitted.contains(n)) out.dropped.add(n);
    }
  }
  return out;
}

String _skippedLine(String tag, String source) =>
    'Replace group "$tag" of "$source" was skipped: the source has no '
    'enabled nodes, and an empty group would stop the VPN core.';

/// §74 п.4 — правила `route.rules` с целью из [dropped] (имя свёртки, чья
/// группа не написана): цель → `route.final`, если он в [liveFinals], иначе
/// правило снимается. Эталон — `cleanDanglingOutboundRefInRule` лаунчера.
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
  final kept = <dynamic>[];
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    final out = r is Map ? r['outbound'] : null;
    if (out is! String || !dropped.contains(out)) {
      kept.add(r);
      continue;
    }
    if (finalTag != null) {
      (r as Map)['outbound'] = finalTag;
      kept.add(r);
      lines.add('Route rule #$i went to replace group "$out", which was '
          'not built — it now goes to the default route "$finalTag".');
    } else {
      lines.add('Route rule #$i went to replace group "$out", which was '
          'not built — the rule was removed.');
    }
  }
  route['rules'] = kept;
  return lines;
}
