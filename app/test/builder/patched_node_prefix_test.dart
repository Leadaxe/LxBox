import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/import_rules.dart';

/// §307 — накопление tag-префикса у пропатченных нод (4PDA #1263).
///
/// Репро бага: узел с `patchedJson` (import-rule REPLACE) эмитился патчем ПО
/// ССЫЛКЕ; билдер писал префиксованный тег прямо в сохранённый патч, и каждый
/// следующий build (старт/рестарт VPN в рамках сессии) клеил префикс поверх:
/// «xxx xxx 0004 - …». Фикс — `emit` отдаёт глубокую копию патча.
class _FakeCtx implements EmitContext {
  final entries = <SingboxEntry>[];
  final selectorTags = <String>[];
  final autoTags = <String>[];
  final _seen = <String>{};

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  String allocateTag(String baseTag) {
    var t = baseTag;
    var i = 1;
    while (!_seen.add(t)) {
      t = '$baseTag-${i++}';
    }
    return t;
  }

  @override
  void addEntry(SingboxEntry entry) => entries.add(entry);

  @override
  void addToSelectorTagList(SingboxEntry entry) => selectorTags.add(entry.tag);

  @override
  void addToAutoList(SingboxEntry entry) => autoTags.add(entry.tag);

  @override
  final RuleSetRegistry ruleSets =
      RuleSetRegistry(initialRuleSets: const [], initialRules: const []);
}

void main() {
  const uri = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#0004';

  SubscriptionServers sub(String prefix) => SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [
          // Узел, которого коснулось REPLACE-правило — как в репро.
          parseUri(uri)!
            ..patchedJson = applyRulesToNode(
              parseUri(uri)!,
              [
                const ImportRule(
                  conditions: [
                    ImportRuleCondition(path: 'tag', pattern: '0004'),
                  ],
                  action: ImportRuleAction.replace,
                  targetPath: 'tls.utls.fingerprint',
                  replacement: 'chrome',
                ),
              ],
            ).patchedJson,
        ],
      );

  test('пять сборок подряд — префикс в теге ровно один', () {
    final list = sub('xxx');
    for (var build = 1; build <= 5; build++) {
      final ctx = _FakeCtx();
      list.build(ctx);
      expect(ctx.entries.single.tag, 'xxx 0004',
          reason: 'build #$build: не «xxx xxx …»');
    }
    // Сохранённый патч не тронут: тег в нём остался голым, detour не въехал.
    final patch = list.nodes.single.patchedJson!;
    expect(patch['tag'], '0004');
    expect(patch.containsKey('detour'), isFalse);
  });

  test('смена префикса подписки не тащит старый (репро «ууу ууу xxx xxx»)',
      () {
    final list = sub('xxx');
    list.build(_FakeCtx());

    // Юзер сменил префикс — модель immutable, копия с новым prefix, узлы
    // (и их патчи) те же инстансы.
    final renamed = list.copyWith(tagPrefix: 'yyy');
    final ctx = _FakeCtx();
    renamed.build(ctx);
    expect(ctx.entries.single.tag, 'yyy 0004');
  });
}
