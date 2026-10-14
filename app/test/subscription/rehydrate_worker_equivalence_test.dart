import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller/cache_rehydrate.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../parser/engine_test_setup.dart';

/// §652 п.6 — разбор кэша в воркере и на main даёт одно и то же: узлы
/// (emit-JSON, identity, предупреждения, патч правил), `dropped`,
/// мигрированные отметки, вердикты. Расхождение = неинициализированный
/// синглтон в воркере (молчаливая порча узлов).
void main() {
  setUpAll(loadEngineSections);

  /// Корпус: небольшие тела публичных подписок и фикстуры форматов.
  List<(String, String)> corpus() {
    final out = <(String, String)>[];
    final pub = Directory('test/fixtures/public_subscriptions/bodies')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.gz'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    for (final f in pub.take(8)) {
      out.add((f.path, utf8.decode(gzip.decode(f.readAsBytesSync()),
          allowMalformed: true)));
    }
    for (final dir in const [
      'json', 'xray', 'wireguard', 'shadowsocks', 'vmess', 'vless', //
      'trojan', 'hysteria2', 'tuic', 'anytls', 'naive', 'ssh', 'socks',
      'base64',
    ]) {
      final d = Directory('test/fixtures/$dir');
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('.md')) continue;
        out.add((f.path, f.readAsStringSync()));
      }
    }
    return out;
  }

  final rule = ImportRule(
    conditions: [
      ImportRuleCondition(
          path: 'tag', op: ImportRuleOperator.contains, pattern: 'a'),
    ],
    targetPath: 'server',
    replacement: 'patched.example',
  );

  String warningKey(NodeWarning w) =>
      '${w.runtimeType}|${w.severity}|${w.renderEn()}';

  String nodeKey(NodeSpec n, Map<NodeSpec, String> ids) => jsonEncode({
        'type': n.runtimeType.toString(),
        'tag': n.tag,
        'id': ids[n],
        'emit': n.emit(TemplateVars.empty).map,
        'patched': n.patchedJson,
        'trail': n.ruleTrail.length,
        'warnings': [for (final w in n.warnings) warningKey(w)],
        'chained': n.chained == null
            ? null
            : jsonEncode(n.chained!.emit(TemplateVars.empty).map),
      });

  void expectSame(CacheParseResult a, CacheParseResult b, String name) {
    final ida = sourceNodeIdentities(a.nodes);
    final idb = sourceNodeIdentities(b.nodes);
    expect(b.nodes.length, a.nodes.length, reason: name);
    for (var i = 0; i < a.nodes.length; i++) {
      expect(nodeKey(b.nodes[i], idb), nodeKey(a.nodes[i], ida),
          reason: '$name #$i');
    }
    expect([for (final w in b.dropped) warningKey(w)],
        [for (final w in a.dropped) warningKey(w)],
        reason: '$name dropped');
    expect(b.migrated?.map((k, v) => MapEntry(k, v.toIso8601String())),
        a.migrated?.map((k, v) => MapEntry(k, v.toIso8601String())),
        reason: '$name migrated');
    expect(b.emptyHint, a.emptyHint, reason: '$name hint');
  }

  test('воркер ≡ main на корпусе тел', () async {
    final items = corpus();
    expect(items.length, greaterThan(10));
    var withNodes = 0;
    var withVerdict = 0;
    var migratedSeen = 0;
    var patched = 0;
    var registryCoded = 0;
    for (final (name, body) in items) {
      // Отметки и вердикт — на первом узле, как их увидел бы разбор на main.
      List<NodeSpec> plain;
      try {
        plain = parseAll(decode(body));
      } catch (_) {
        continue; // тело не разбирается вовсе — сравнивать нечего
      }
      final now = DateTime.utc(2026, 10, 15);
      final disabled = <String, DateTime>{'f' * 64: now};
      final verdicts = <String, List<StoredWarning>>{};
      if (plain.isNotEmpty) {
        final id = sourceNodeIdentities(plain)[plain.first];
        if (id != null) {
          disabled[legacyNodeIdentityHash(plain.first)] = now;
          verdicts[id] = [StoredWarning.coreRejected('stub reject')];
        }
      }
      final input = CacheParseInput(
        body: body,
        rules: [rule],
        disabledHashes: disabled,
        nodeWarnings: verdicts,
      );
      final onMain = parseCachedBody(input);
      final inWorker =
          await parseCachedBodyInIsolate(input, ParseEnvSnapshot.capture());
      expectSame(onMain, inWorker, name);
      if (onMain.nodes.isNotEmpty) withNodes++;
      if (onMain.nodes.any((n) => n.warnings.any((w) =>
          w is RegistryWarning && w.code == kCoreRejectedCode))) {
        withVerdict++;
      }
      if (onMain.migrated != null) migratedSeen++;
      if (onMain.nodes.any((n) => n.patchedJson != null)) patched++;
      if (onMain.nodes.any((n) => n.warnings.any((w) =>
          w is RegistryWarning && w.code != kCoreRejectedCode))) {
        registryCoded++;
      }
    }
    expect(withNodes, greaterThan(5), reason: 'корпус не пустой');
    expect(withVerdict, greaterThan(0), reason: 'вердикт дошёл до узлов');
    expect(migratedSeen, greaterThan(0), reason: 'миграция отработала');
    expect(patched, greaterThan(0), reason: 'import-правило применилось');
    expect(registryCoded, greaterThan(0),
        reason: 'коды реестра есть — сравнение видит незагруженный реестр');
  });

  test('реестр в воркере загружен из снимка main', () {
    final snap = ParseEnvSnapshot.capture();
    expect(snap.registry, isNotNull);
    expect(snap.registry!.texts, contains('VERSION'));
    expect(snap.drafts, isNotEmpty);
  });
}
