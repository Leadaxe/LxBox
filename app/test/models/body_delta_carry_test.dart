import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../parser/engine_test_setup.dart';

/// §560 п.9 / §570 — дельта тела (`NodeSpec.bodyDelta`: поля, которых модель
/// не держит) ставится разбором и живёт в памяти узла. Узел, пересобранный
/// конструктором из другого узла (перетег WARP/MASQUE, эмодзи у `.conf`),
/// обязан унести её с собой, иначе поля пропадают до перечитывания
/// источника.
///
/// Страж по исходнику: каждая копия узла через конструктор
/// (`rawSource: x.rawSource`) вне разбора несёт в том же выражении
/// `..bodyDelta = x.bodyDelta`. `node_spec.dart` исключён: там копии живут в
/// `_withChainedTyped`, а дельту переносит обёртка `withChained`.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  test('поле дельты переживает перетег узла конструктором', () {
    final text = jsonEncode({
      'type': 'trojan',
      'tag': 't1',
      'server': 'a.example.com',
      'server_port': 443,
      'password': 'p',
      'connect_timeout': '7s',
    });
    final node = parseAll(decode(text)).single as TrojanSpec;
    expect(node.emit(TemplateVars.empty).map['connect_timeout'], '7s',
        reason: 'разбор ставит дельту');
    final retagged = TrojanSpec(
      id: node.id,
      tag: 'renamed',
      label: 'renamed',
      server: node.server,
      port: node.port,
      rawSource: node.rawSource,
      password: node.password,
    )..bodyDelta = node.bodyDelta;
    expect(retagged.emit(TemplateVars.empty).map['connect_timeout'], '7s');
  });

  test('копия узла вне разбора переносит bodyDelta', () {
    final copy = RegExp(r'rawSource:\s*(\w+)\.rawSource');
    final misses = <String>[];
    var sites = 0;
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final path = f.path.replaceAll(r'\', '/');
      if (path.startsWith('lib/services/parser/') ||
          path == 'lib/models/node_spec.dart') {
        continue;
      }
      final src = f.readAsStringSync();
      for (final m in copy.allMatches(src)) {
        sites++;
        final end = src.indexOf(';', m.end);
        final stmt = src.substring(m.end, end < 0 ? src.length : end);
        if (!stmt.contains('..bodyDelta = ${m.group(1)}.bodyDelta')) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          misses.add('$path:$line');
        }
      }
    }
    expect(sites, greaterThan(0), reason: 'страж ничего не нашёл');
    expect(misses, isEmpty,
        reason: 'копия узла теряет дельту тела (§560): $misses');
  });

  test('withChained переносит дельту (обёртка над копиями node_spec)', () {
    final src = File('lib/models/node_spec.dart').readAsStringSync();
    expect(
        RegExp(r'NodeSpec withChained\([^)]*\)\s*=>\s*\n?\s*_withChainedTyped\([^)]*\)\.\.bodyDelta = spec\.bodyDelta')
            .hasMatch(src),
        isTrue);
  });
}
