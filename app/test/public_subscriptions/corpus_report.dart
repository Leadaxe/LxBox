// §525 — отчёты и сверка с эталоном для корпуса публичных подписок.
//
// Живёт рядом с раннером, а не в `tool/`: конвейер разбора тянет Flutter
// (`node_warning.dart` → l10n → `package:flutter/widgets.dart`), поэтому
// запустить его голым `dart run` НЕЛЬЗЯ ни из какого каталога — единственный
// путь это `flutter test`. Энтрипоинт — `public_subs_corpus_test.dart`.

import 'dart:convert';
import 'dart:io';

import 'corpus_runner.dart';

/// Записать `report.json` и `report.md` рядом с корпусом.
void writeReports(List<SubscriptionResult> results) {
  File('$kCorpusRoot/report.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'contract_version': contractVersion,
            'subscriptions': [for (final r in results) r.toJson()],
            'summary': summaryOf(results),
          })}\n');
  File('$kCorpusRoot/report.md').writeAsStringSync(renderMarkdown(results));
}

/// Переписать эталон числами текущего прогона.
void writeExpected(List<SubscriptionResult> results) {
  File('$kCorpusRoot/expected.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'note': 'эталон §525; обновлять только с объявленной причиной, '
                'см. docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md',
            'contract_version': contractVersion,
            'subscriptions': {for (final r in results) r.id: r.toExpected()},
          })}\n');
}

/// Построчные расхождения эталона и текущего прогона.
List<String> diffExpected(
    Map<String, dynamic> expected, Map<String, Map<String, dynamic>> current) {
  final out = <String>[];
  for (final id in {...expected.keys, ...current.keys}.toList()..sort()) {
    final e = expected[id] as Map<String, dynamic>?;
    final c = current[id];
    if (e == null) {
      out.add('$id: новой подписки нет в эталоне');
      continue;
    }
    if (c == null) {
      out.add('$id: подписка эталона в прогоне отсутствует (тело пропало?)');
      continue;
    }
    final en = e['nodes_total'], cn = c['nodes_total'];
    if (en != cn) {
      // Падение числа узлов — то, за чем корпус и заведён.
      final mark = (cn as int) < (en as int) ? ' ← УЗЛОВ СТАЛО МЕНЬШЕ' : '';
      out.add('$id: nodes_total $en → $cn$mark');
    }
    for (final field in const ['dropped', 'warnings']) {
      final em = ((e[field] as Map?) ?? const {}).cast<String, dynamic>();
      final cm = ((c[field] as Map?) ?? const {}).cast<String, dynamic>();
      for (final code in {...em.keys, ...cm.keys}.toList()..sort()) {
        final a = em[code] ?? 0, b = cm[code] ?? 0;
        if (a != b) out.add('$id: $field.$code $a → $b');
      }
    }
  }
  return out;
}

String get contractVersion {
  final f = File('assets/contract/VERSION');
  return f.existsSync() ? f.readAsStringSync().trim() : 'unknown';
}

/// Сводка по всему корпусу.
Map<String, dynamic> summaryOf(List<SubscriptionResult> rs) {
  final drop = <String, int>{}, warn = <String, int>{};
  final types = <String, int>{}, cover = <String, int>{};
  final kinds = <String, int>{};
  var nodes = 0;
  for (final r in rs) {
    nodes += r.nodesTotal;
    kinds[r.decodedKind] = (kinds[r.decodedKind] ?? 0) + 1;
    r.dropped.forEach((k, v) => drop[k] = (drop[k] ?? 0) + v);
    r.warnings.forEach((k, v) => warn[k] = (warn[k] ?? 0) + v);
    r.byType.forEach((k, v) => types[k] = (types[k] ?? 0) + v);
    r.coverage.forEach((k, v) => cover[k] = (cover[k] ?? 0) + v);
  }
  return {
    'subscriptions': rs.length,
    'nodes_total': nodes,
    'zero_node_subscriptions': [
      for (final r in rs)
        if (r.nodesTotal == 0)
          {
            'id': r.id,
            'decoded_kind': r.decodedKind,
            if (r.decodeFailure != null) 'decode_failure': r.decodeFailure,
            'dropped': r.dropped,
            if (r.sampleDropLines.isNotEmpty) 'sample': r.sampleDropLines,
          },
    ],
    'decoded_kinds': _desc(kinds),
    'dropped_codes': _desc(drop),
    'warning_codes': _desc(warn),
    'node_types': _desc(types),
    'coverage': _desc(cover),
  };
}

Map<String, int> _desc(Map<String, int> m) {
  final e = m.entries.toList()
    ..sort((a, b) =>
        b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  return {for (final x in e) x.key: x.value};
}

String renderMarkdown(List<SubscriptionResult> rs) {
  final s = summaryOf(rs);
  final b = StringBuffer()
    ..writeln('# Корпус публичных подписок — прогон разбора')
    ..writeln()
    ..writeln('Контракт: `$contractVersion`. '
        'Подписок: ${s['subscriptions']}. Узлов: ${s['nodes_total']}.')
    ..writeln()
    ..writeln('Сгенерировано `tool/public_subs/run.dart`; править руками '
        'незачем — перезапишется. Методика: '
        '`docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md`.')
    ..writeln()
    ..writeln('## По подпискам')
    ..writeln()
    ..writeln('| id | вид | узлов | типы | отбраковки | предупреждения | мс |')
    ..writeln('|---|---|--:|---|---|---|--:|');
  for (final r in rs) {
    b.writeln('| `${r.id}` | ${r.decodedKind} | ${r.nodesTotal} '
        '| ${_inline(r.byType)} | ${_inline(r.dropped)} '
        '| ${_inline(r.warnings)} | ${r.parseMs} |');
  }

  final zero = (s['zero_node_subscriptions'] as List).cast<Map>();
  b
    ..writeln()
    ..writeln('## Ноль узлов (${zero.length})')
    ..writeln();
  if (zero.isEmpty) {
    b.writeln('Нет — каждая подписка дала хотя бы один узел.');
  } else {
    for (final z in zero) {
      b.writeln('- `${z['id']}` — вид `${z['decoded_kind']}`'
          '${z['decode_failure'] != null ? ', отказ decode: `${z['decode_failure']}`' : ''}'
          '${(z['dropped'] as Map).isEmpty ? '' : ', отбраковки: ${_inline((z['dropped'] as Map).cast<String, int>())}'}');
    }
  }

  _section(b, 'Виды тел', s['decoded_kinds'] as Map<String, int>);
  _section(b, 'Коды отбраковок', s['dropped_codes'] as Map<String, int>);
  _section(b, 'Коды предупреждений', s['warning_codes'] as Map<String, int>);
  _section(b, 'Типы узлов', s['node_types'] as Map<String, int>);

  b
    ..writeln()
    ..writeln('## Покрытие: протокол × транспорт × security')
    ..writeln()
    ..writeln('| протокол | транспорт | security | узлов |')
    ..writeln('|---|---|---|--:|');
  (s['coverage'] as Map<String, int>).forEach((k, v) {
    final p = k.split('|');
    b.writeln('| ${p[0]} | ${p[1]} | ${p[2]} | $v |');
  });

  return b.toString();
}

void _section(StringBuffer b, String title, Map<String, int> m) {
  b
    ..writeln()
    ..writeln('## $title')
    ..writeln();
  if (m.isEmpty) {
    b.writeln('—');
    return;
  }
  b
    ..writeln('| код | число |')
    ..writeln('|---|--:|');
  m.forEach((k, v) => b.writeln('| `$k` | $v |'));
}

String _inline(Map<String, int> m) {
  if (m.isEmpty) return '—';
  final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return e.map((x) => '`${x.key}`&nbsp;${x.value}').join(', ');
}
