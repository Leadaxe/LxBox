import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';

// Контракт 1.0.1 — импорт групп `kind: auto` и полей стороны LxBox по норме
// LxBox на файлах корпуса. Кейсы `v10_group_links` и `v10_dev_forms` раннер
// корпуса сверяет по `.expected.lxbox.json` (selector читается urltest'ом с
// `backup_group_degraded`, ответ 6, TASKS_LXBOX.md §17.8); здесь закреплена
// перепись членов, позиций и dev-форм по модели. `v10_lxbox_fields` раннер
// проходит, но поля стороны LxBox его ожидание не несёт: «раннер LxBox сверяет
// их по своей модели» (README корпуса) — здесь.

const _corpus = 'contract/corpus/backup';

typedef _Imported = ({
  LxBackupFile file,
  List<ServerList> lists,
  List<SourceChain> chains,
  List<CustomRule> rules,
  List<DnsServerRef> dnsServers,
});

/// Импорт тем же планом, что приложение (`LxBackupImportService`).
_Imported _import(String raw, {List<ServerList> lists = const []}) {
  final plan = planLxBackupImport(raw, LxImportReceiver(lists: lists));
  final file = plan.file;
  final dns = file.dns;
  return (
    file: file,
    lists: plan.lists,
    chains: plan.chains,
    rules: plan.rules,
    dnsServers: dns == null
        ? const []
        : applyDnsBackup(
            incoming: dns,
            servers: const [],
            rules: const [],
            dnsFinal: '',
            strategy: '',
            defaultDomainResolver: '',
          ).servers,
  );
}

String? _read(String name) {
  final f = File('$_corpus/$name');
  return f.existsSync() ? f.readAsStringSync() : null;
}

FolderServers _folder(List<ServerList> lists, String name) =>
    lists.whereType<FolderServers>().singleWhere((f) => f.name == name);

AutoSelectSpec _group(FolderServers f, String tag) => f.members
    .map((m) => m.node)
    .whereType<AutoSelectSpec>()
    .singleWhere((g) => g.tag == tag);

void main() {
  test('v10_group_links: члены и позиция на группу — на локальную папку, '
      'selector → urltest с backup_group_degraded', () {
    final pre = _read('v10_group_links.pre.backup.json');
    final raw = _read('v10_group_links.backup.json');
    if (pre == null || raw == null) {
      markTestSkipped('контракт не синхронизирован');
      return;
    }
    final before = _import(pre).lists;
    final got = _import(raw, lists: before);

    expect([for (final w in got.file.warnings) '${w.code} ${w.detail} ${w.reason}'],
        ['$kWarnGroupDegraded Best $kGroupDegradedSelector']);

    final work = _folder(got.lists, 'Work');
    expect(work.id, '01FLDGROUPLOCAL00000000000',
        reason: 'папка совпала по имени и держит локальный id');
    expect([for (final m in work.members) m.node?.tag],
        ['local-at', 'de-1', 'de-2', 'Best']);
    final best = _group(work, 'Best');
    // NODE_LINK §7.2 — folder_id файла переписан на локальный.
    expect((best.membership as ExplicitMembers).members, [
      NodeLink(folderId: work.id, tag: 'de-1'),
      NodeLink(folderId: work.id, tag: 'de-2'),
    ]);
    // Позиция на группу — пара с СЫРЫМ тегом группы и локальным id.
    expect(got.chains.single.hops, [
      const NodeLink(tag: 'relay-root'),
      NodeLink(folderId: work.id, tag: 'Best'),
    ]);
  });

  test('v10_dev_forms: члены {tag} — пары своей папки, позиция финальным '
      'тегом группы (S3) — сырой тег, default строкой не хранится', () {
    final raw = _read('v10_dev_forms.backup.json');
    if (raw == null) {
      markTestSkipped('контракт не синхронизирован');
      return;
    }
    final got = _import(raw);
    expect([for (final w in got.file.warnings) w.code], [kWarnGroupDegraded],
        reason: 'только selector → urltest; dev-формы молча');

    final dev = _folder(got.lists, 'Dev');
    final g = _group(dev, 'G');
    expect((g.membership as ExplicitMembers).members, [
      NodeLink(folderId: dev.id, tag: 'x'),
      NodeLink(folderId: dev.id, tag: 'y'),
    ]);
    expect(got.chains.single.hops, [
      const NodeLink(tag: 'relay-root'),
      NodeLink(folderId: dev.id, tag: 'G'),
    ]);
  });

  test('v10_lxbox_fields: поля стороны LxBox применены к модели', () {
    final raw = _read('v10_lxbox_fields.backup.json');
    if (raw == null) {
      markTestSkipped('контракт не синхронизирован');
      return;
    }
    final got = _import(raw);
    expect(got.file.warnings, isEmpty);

    final sub = got.lists.whereType<SubscriptionServers>().single;
    expect(
        sub.detourPolicy,
        const DetourPolicy(
          registerDetourServers: true,
          registerDetourInAuto: true,
          useDetourServers: false,
          replaceDetourChain: true,
        ));
    // Контракт 1.0.1: `import_rules` — anyOf [форма LxBox {conditions,
    // action, …}, старая плоская форма {pattern, is_regex, action}]. Кейс
    // несёт по правилу каждой формы, и применяются оба: старое переносится в
    // условие по `tag` (миграция §302 v1).
    expect(sub.importRules, hasLength(2));
    final byConditions = sub.importRules[0];
    expect(byConditions.conditions, hasLength(2));
    expect(byConditions.conditions[0].path, 'tag');
    expect(byConditions.conditions[0].op, ImportRuleOperator.contains);
    expect(byConditions.conditions[0].pattern, 'PROMO');
    expect(byConditions.conditions[0].caseSensitive, isTrue);
    expect(byConditions.conditions[1].path, 'type');
    expect(byConditions.conditions[1].op, ImportRuleOperator.equals);
    expect(byConditions.conditions[1].negate, isTrue);
    expect(byConditions.action, ImportRuleAction.replace);
    expect(byConditions.targetPath, 'tag');
    expect(byConditions.replaceMode, ImportRuleReplaceMode.substitute);
    expect(byConditions.substitutePattern, ' PROMO');
    final legacy = sub.importRules[1];
    expect(legacy.conditions, hasLength(1));
    expect(legacy.conditions.single.path, 'tag');
    expect(legacy.conditions.single.op, ImportRuleOperator.matches);
    expect(legacy.conditions.single.pattern, '^trial');
    expect(legacy.action, ImportRuleAction.disable);
    expect(sub.importRulesEnabled, isFalse);
    expect(sub.onUpdateAction, SubscriptionOnUpdateAction.reload);

    final server = got.lists.whereType<UserServer>().single;
    expect(server.detourPolicy, DetourPolicy.defaults);
    // У LxBox tag_policy корневого сервера — префикс имени в списке.
    expect(server.tagPrefix, 'lx:');

    final work = _folder(got.lists, 'Work');
    expect(work.detourPolicy, const DetourPolicy(replaceDetourChain: true));
    expect(work.pingUrl, 'https://example-2.com/generate_204');
    expect(work.pingTimeoutMs, 3000);
    final best = _group(work, 'Best');
    // Непустой members сильнее members_rule (по схеме у группы-правила
    // явного состава нет); pool_badge "" — без значков.
    expect((best.membership as ExplicitMembers).members, [
      NodeLink(folderId: work.id, tag: 'de-1'),
      NodeLink(folderId: work.id, tag: 'de-2'),
    ]);
    expect(best.poolBadge, '');

    expect(got.chains.single.label, 'Через релей');

    final ads = got.rules.whereType<CustomRuleSrs>().single;
    expect(ads.updateIntervalHours, 24);
    expect(got.rules.whereType<CustomRuleJson>().single.name, 'Corp',
        reason: 'verbatim: тело не перетипизировано');

    final template = got.dnsServers.whereType<DnsServerTemplate>().single;
    expect(template.description, 'Системный резолвер');
    expect(template.varValues, {'dns_local': '1.1.1.1'});
    expect(got.dnsServers.whereType<DnsServerInline>().single.description,
        'Свой DoH');
  });

  test('members_rule группы без members — группа по правилу', () {
    final raw = _read('v10_group_degraded.backup.json');
    if (raw == null) {
      markTestSkipped('контракт не синхронизирован');
      return;
    }
    final got = _import(raw);
    final rules = _folder(got.lists, 'Rules');
    final byRule = _group(rules, 'by-rule');
    expect(byRule.membership,
        isA<RuleMembers>().having((r) => r.include, 'include', '^a\$'));
    expect(_group(rules, 'pick').membership, isA<ExplicitMembers>());
    expect(
        [for (final w in got.file.warnings) '${w.code} ${w.detail} ${w.reason}'],
        ['$kWarnGroupDegraded pick $kGroupDegradedSelector']);
  });
}
