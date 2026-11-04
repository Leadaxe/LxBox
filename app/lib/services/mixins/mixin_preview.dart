/// §704 §5 п.5 / §7 — предпросмотр одного миксина: число совпадений,
/// отказ и фрагмент результата (родитель цели после применения), строками
/// с маркерами `' '` без изменений, `+` вставлен, `~` изменён, `-` удалён.
///
/// Общий источник формы миксина и `GET /mixins/:id/preview` Debug API.
library;

import 'dart:convert';

import '../../models/mixin.dart';
import '../../models/validation.dart';
import '../json_clone.dart';
import 'mixin_apply.dart';
import 'mixin_path.dart';

/// Строка фрагмента. [text] — компактный JSON элемента (у объекта —
/// `"ключ": значение`), обрезка по ширине — дело UI; [value] — полный JSON
/// (для `-` — удалённое значение).
class MixinPreviewRow {
  final String marker;
  final String text;
  final Object? value;
  const MixinPreviewRow(this.marker, this.text, this.value);

  Map<String, dynamic> toJson() =>
      {'marker': marker, 'text': text, 'value': value};

  @override
  String toString() => '$marker $text';
}

class MixinPreviewFragment {
  /// Конкретный путь показанного узла (`route.rules`, `log`, пусто — корень).
  final String parentPath;
  final List<MixinPreviewRow> rows;
  const MixinPreviewFragment(this.parentPath, this.rows);

  Map<String, dynamic> toJson() => {
        'parent_path': parentPath,
        'rows': [for (final r in rows) r.toJson()],
      };
}

class MixinPreview {
  /// Совпадений пути до применения (у синтаксической ошибки — 0).
  final int matches;

  /// Отказ миксина (тот же, что дала бы сборка), включая дубль тега.
  final MixinIssue? issue;

  /// `null` — показывать нечего (путь не разобран, нет совпадений, отказ
  /// до изменения).
  final MixinPreviewFragment? fragment;

  const MixinPreview({required this.matches, this.issue, this.fragment});

  Map<String, dynamic> toJson() => {
        'matches': matches,
        'issue': issue == null
            ? null
            : {'reason': issue!.reason, 'message': issue!.renderEn()},
        'fragment': fragment?.toJson(),
      };
}

String _compact(Object? v) => jsonEncode(v);

/// Предпросмотр [mixin] над [config] (вход не меняется). Состояние
/// `enabled` миксина не учитывается: форма показывает, что он сделает.
/// [config] — база, которую миксин увидит при сборке ([mixinPreviewBase]).
MixinPreview previewMixin(Map<String, dynamic> config, Mixin mixin) {
  final work = deepCopyJson(config);
  final parsed = parseMixinPath(mixin.target);
  if (parsed is MixinPathError) {
    return MixinPreview(
      matches: 0,
      issue: mixinIssue(mixin, 'syntax: ${parsed.message}'),
    );
  }
  final before = (parsed as MixinPath).resolve(work);
  final op = mixin.opKind;

  // Показываемый узел — до применения, пока ссылки на него живы.
  Object? shown;
  var shownPath = '';
  var scalarSet = false;
  if (before.isNotEmpty) {
    final single = before.length == 1 ? before.single : null;
    if ((op == MixinOp.append || op == MixinOp.prepend) &&
        single != null &&
        single.value is List) {
      shown = single.value;
      shownPath = single.path;
    } else {
      final at = op == MixinOp.after ? before.last : before.first;
      if (at.isRoot) {
        shown = work;
      } else if (op == MixinOp.set && at.value is! Map && at.value is! List) {
        scalarSet = true;
        shown = at.parent;
        shownPath = at.path;
      } else {
        shown = at.parent;
        shownPath = at.parentPath;
      }
    }
  }
  final snapshot = deepCloneJson(shown);
  final dupsBefore = duplicateTagKeys(work);

  final r = applyMixinOnce(work, mixin);
  final reason = r.reason;
  if (reason != null) {
    return MixinPreview(
        matches: before.length, issue: mixinIssue(mixin, reason));
  }
  MixinIssue? issue;
  for (final e in duplicateTagKeys(work).entries) {
    if (!dupsBefore.containsKey(e.key)) {
      issue = mixinIssue(mixin, e.value, aboutTarget: false);
      break;
    }
  }

  final List<MixinPreviewRow> rows;
  if (scalarSet) {
    final m = before.first;
    rows = [
      MixinPreviewRow(
          '~', '${_compact(m.value)} → ${_compact(mixin.value)}', mixin.value),
    ];
  } else if (shown is List && snapshot is List) {
    rows = _listRows(op!, mixin, before, shown, snapshot);
  } else if (shown is Map && snapshot is Map) {
    rows = _mapRows(snapshot, shown);
  } else {
    rows = const [];
  }
  return MixinPreview(
    matches: before.length,
    issue: issue,
    fragment: MixinPreviewFragment(shownPath, rows),
  );
}

/// Строки списка по смыслу глагола: где вставлено, какие элементы задеты.
List<MixinPreviewRow> _listRows(
  MixinOp op,
  Mixin mixin,
  List<PathMatch> matches,
  List after,
  List before,
) {
  final inserted = mixin.value is List ? (mixin.value as List).length : 1;
  MixinPreviewRow row(String marker, Object? v) =>
      MixinPreviewRow(marker, _compact(v), v);

  switch (op) {
    case MixinOp.append:
      return [
        for (final v in before) row(' ', v),
        for (var i = before.length; i < after.length; i++) row('+', after[i]),
      ];
    case MixinOp.prepend:
      return [
        for (var i = 0; i < inserted; i++) row('+', after[i]),
        for (final v in before) row(' ', v),
      ];
    case MixinOp.before:
    case MixinOp.after:
      final at = op == MixinOp.before ? matches.first : matches.last;
      final pos = op == MixinOp.before ? at.index! : at.index! + 1;
      return [
        for (var i = 0; i < pos; i++) row(' ', before[i]),
        for (var i = pos; i < pos + inserted; i++) row('+', after[i]),
        for (var i = pos; i < before.length; i++) row(' ', before[i]),
      ];
    case MixinOp.set:
    case MixinOp.merge:
    case MixinOp.remove:
      // Задетые элементы именно этого списка.
      final hit = <int>{
        for (final m in matches)
          if (identical(m.parent, matches.first.parent) && m.index != null)
            m.index!,
      };
      if (op == MixinOp.remove && mixin.value == true) {
        final out = <MixinPreviewRow>[];
        var j = 0;
        for (var i = 0; i < before.length; i++) {
          if (hit.contains(i)) {
            out.add(row('-', before[i]));
          } else {
            out.add(row(' ', after[j++]));
          }
        }
        return out;
      }
      return [
        for (var i = 0; i < after.length; i++)
          row(
            hit.contains(i) && !deepEqualsJson(before[i], after[i]) ? '~' : ' ',
            after[i],
          ),
      ];
  }
}

/// Строки объекта по ключам: удалённые `-` на своих местах, новые `+` в
/// конце, изменённые `~`.
List<MixinPreviewRow> _mapRows(Map before, Map after) {
  MixinPreviewRow row(String marker, Object? k, Object? v) =>
      MixinPreviewRow(marker, '${jsonEncode(k)}: ${_compact(v)}', v);
  return [
    for (final e in before.entries)
      if (!after.containsKey(e.key))
        row('-', e.key, e.value)
      else
        row(deepEqualsJson(e.value, after[e.key]) ? ' ' : '~', e.key,
            after[e.key]),
    for (final e in after.entries)
      if (!before.containsKey(e.key)) row('+', e.key, e.value),
  ];
}
