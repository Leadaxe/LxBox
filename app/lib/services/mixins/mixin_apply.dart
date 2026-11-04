/// §704 §2/§4 — применение миксинов к итоговому конфигу ядра.
///
/// Место в сборке — `_buildConfig` после `sanitizeOutboundGraph` и до
/// `validateConfig`: миксины — сырой обход, санитайзер реестра и автоснятия
/// их не видят, валидатор видит результат. Ошибки не бросаются, а копятся
/// [MixinIssue] (все fatal: сборка их отдаёт валидатору).
library;

import '../../models/mixin.dart';
import '../../models/validation.dart';
import '../json_clone.dart';
import 'mixin_path.dart';

/// Итог [applyMixins].
class MixinApplyResult {
  /// Конфиг после миксинов. Без включённых миксинов — тот же объект, что
  /// пришёл; иначе — глубокая копия (вход не меняется).
  final Map<String, dynamic> config;

  /// Отказы по порядку миксинов; дубли тегов — сразу за миксином, который
  /// их внёс.
  final List<MixinIssue> issues;

  /// Сколько миксинов применилось без отказа.
  final int applied;

  const MixinApplyResult(this.config, this.issues, {this.applied = 0});
}

/// Итог одного миксина: совпадения пути (до применения) и причина отказа.
typedef MixinOnceResult = ({List<PathMatch> matches, String? reason});

/// Включённые миксины [mixins] по порядку списка; каждый видит результат
/// предыдущих. Миксин с отказом конфиг не меняет. После каждого — проверка
/// уникальности тегов в `inbounds`, `outbounds`+`endpoints` (одно
/// пространство имён ядра), `dns.servers`: новый дубль — issue этого миксина.
MixinApplyResult applyMixins(
    Map<String, dynamic> config, List<Mixin> mixins) {
  final enabled = [
    for (final m in mixins)
      if (m.enabled) m,
  ];
  if (enabled.isEmpty) return MixinApplyResult(config, const []);
  // Копия через JSON: в собранном конфиге бывают типизированные списки
  // (`List<String>`), куда вставка объекта упала бы TypeError'ом.
  final work = deepCopyJson(config);
  final issues = <MixinIssue>[];
  var applied = 0;
  var dups = duplicateTagKeys(work);
  for (final m in enabled) {
    final r = applyMixinOnce(work, m);
    final reason = r.reason;
    if (reason != null) {
      issues.add(mixinIssue(m, reason));
      continue;
    }
    applied++;
    final now = duplicateTagKeys(work);
    for (final e in now.entries) {
      if (!dups.containsKey(e.key)) {
        issues.add(mixinIssue(m, e.value, aboutTarget: false));
      }
    }
    dups = now;
  }
  return MixinApplyResult(work, issues, applied: applied);
}

/// Issue миксина [m] с причиной [reason].
MixinIssue mixinIssue(Mixin m, String reason, {bool aboutTarget = true}) =>
    MixinIssue(
      mixinId: m.id,
      name: m.displayName,
      target: m.target,
      reason: reason,
      aboutTarget: aboutTarget,
    );

/// Конфиг [base] с применёнными включёнными миксинами, стоящими в [mixins]
/// ВЫШЕ миксина [beforeId] (нет такого или `null` — все). Отказы молча
/// пропускаются. База предпросмотра и подсказок формы: миксин видит то, что
/// увидит при сборке.
Map<String, dynamic> mixinPreviewBase(
  Map<String, dynamic> base,
  List<Mixin> mixins, {
  String? beforeId,
}) {
  final upTo = beforeId == null
      ? mixins.length
      : mixins.indexWhere((m) => m.id == beforeId);
  final prior = mixins.sublist(0, upTo < 0 ? mixins.length : upTo);
  return applyMixins(base, prior).config;
}

/// Ключи дублей тегов: `<список>\u0000<тег>\u0000<номер повтора>` → текст
/// причины. Номер повтора отличает третью копию от второй.
Map<String, String> duplicateTagKeys(Map<String, dynamic> config) {
  final out = <String, String>{};
  void scan(List<(String, Object?)> lists) {
    final seen = <String, int>{};
    for (final (label, list) in lists) {
      if (list is! List) continue;
      for (final el in list) {
        if (el is! Map) continue;
        final tag = el['tag'];
        if (tag is! String) continue;
        final n = seen.update(tag, (v) => v + 1, ifAbsent: () => 0);
        if (n > 0) {
          out['$label\u0000$tag\u0000$n'] = 'duplicate tag "$tag" in $label';
        }
      }
    }
  }

  scan([('inbounds', config['inbounds'])]);
  scan([
    ('outbounds', config['outbounds']),
    ('endpoints', config['endpoints']),
  ]);
  final dns = config['dns'];
  scan([('dns.servers', dns is Map ? dns['servers'] : null)]);
  return out;
}

/// Один миксин над [config] на месте. Отказ — причина, конфиг не тронут.
/// [onReplace] — старое и новое значение каждого узла, заменённого `set`
/// (предпросмотр помечает строку `~`).
MixinOnceResult applyMixinOnce(
  Map<String, dynamic> config,
  Mixin m, {
  void Function(Object? oldValue, Object? newValue)? onReplace,
}) {
  final parsed = parseMixinPath(m.target);
  if (parsed is MixinPathError) {
    return (matches: const <PathMatch>[], reason: 'syntax: ${parsed.message}');
  }
  final path = parsed as MixinPath;
  final matches = path.resolve(config);
  final op = m.opKind;
  if (op == null) {
    return (matches: matches, reason: 'unknown action "${m.op}"');
  }
  if (matches.isEmpty) return (matches: matches, reason: 'no match');
  final reason = _apply(config, op, m.value, matches, onReplace);
  return (matches: matches, reason: reason);
}

List<Object?> _items(Object? value) => [
      for (final v in (value is List ? value : [value])) deepCloneJson(v),
    ];

String? _apply(
  Map<String, dynamic> config,
  MixinOp op,
  Object? value,
  List<PathMatch> matches,
  void Function(Object?, Object?)? onReplace,
) {
  switch (op) {
    case MixinOp.append:
    case MixinOp.prepend:
      final list = matches.length == 1 ? matches.single.value : null;
      if (list is! List) return 'needs a single list';
      final items = _items(value);
      if (op == MixinOp.append) {
        list.addAll(items);
      } else {
        list.insertAll(0, items);
      }
      return null;

    case MixinOp.before:
    case MixinOp.after:
      if (!matches.every((x) => x.isListElement)) return 'not a list element';
      final at = op == MixinOp.before ? matches.first : matches.last;
      final list = at.parent as List;
      final pos = op == MixinOp.before ? at.index! : at.index! + 1;
      list.insertAll(pos, _items(value));
      return null;

    case MixinOp.set:
      if (matches.any((x) => x.isRoot) && value is! Map) {
        return 'the root can only be set to an object';
      }
      for (final x in matches) {
        final next = deepCloneJson(value);
        if (x.isRoot) {
          config
            ..clear()
            ..addAll((next as Map).cast<String, dynamic>());
          continue;
        }
        _put(x, next);
        onReplace?.call(x.value, next);
      }
      return null;

    case MixinOp.merge:
      if (value is! Map) return 'merge needs an object value';
      if (!matches.every((x) => x.value is Map)) return 'not an object';
      for (final x in matches) {
        _deepMerge(x.value as Map, value);
      }
      return null;

    case MixinOp.remove:
      if (value == true) {
        if (matches.any((x) => x.isRoot)) return 'cannot remove the root';
        _removeNodes(matches);
        return null;
      }
      if (value is List && value.every((k) => k is String)) {
        if (!matches.every((x) => x.value is Map)) return 'not an object';
        for (final x in matches) {
          for (final k in value.cast<String>()) {
            _removeKey(x.value as Map, k);
          }
        }
        return null;
      }
      return 'remove expects true or a list of keys';
  }
}

void _put(PathMatch x, Object? next) {
  final parent = x.parent;
  if (parent is Map) {
    parent[x.key] = next;
  } else if (parent is List) {
    parent[x.index!] = next;
  }
}

/// Слияние вглубь: объект в объект рекурсивно, остальное (в том числе
/// список) заменяет значение цели целиком; новые ключи — в конец.
void _deepMerge(Map target, Map src) {
  for (final e in src.entries) {
    final have = target[e.key];
    final v = e.value;
    if (have is Map && v is Map) {
      _deepMerge(have, v);
    } else {
      target[e.key] = deepCloneJson(v);
    }
  }
}

/// Узлы целиком: ключи объектов, элементы списков (по убыванию индекса,
/// чтобы ранние удаления не сдвигали поздние).
void _removeNodes(List<PathMatch> matches) {
  final byList = Map<List, List<int>>.identity();
  for (final x in matches) {
    final parent = x.parent;
    if (parent is Map) {
      parent.remove(x.key);
    } else if (parent is List) {
      byList.putIfAbsent(parent, () => []).add(x.index!);
    }
  }
  for (final e in byList.entries) {
    final idx = e.value.toSet().toList()..sort((a, b) => b.compareTo(a));
    for (final i in idx) {
      e.key.removeAt(i);
    }
  }
}

/// Ключ [dotted] (`tls.utls`) внутри [obj]; отсутствующий — не ошибка.
void _removeKey(Map obj, String dotted) {
  final parts = dotted.split('.');
  Object? cur = obj;
  for (var i = 0; i < parts.length - 1; i++) {
    if (cur is! Map) return;
    cur = cur[parts[i]];
  }
  if (cur is Map) cur.remove(parts.last);
}
