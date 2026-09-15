import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';

// §438 — чтение LX Backup 1.0 (`lx_backup: 2`) вместе с 0.x одним слиянием.
// Корпус `v10_*` проверяет сквозные сценарии; здесь — развилки, которых
// корпус не касается: версии, тёзки папок, preset-серверы DNS, ось правил,
// секции совпавшего узла, виды записей без дома в модели LxBox.

String _file(Map<String, dynamic> body) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': 'test'},
      'exported_at': '2026-09-14T00:00:00Z',
      ...body,
    });

Map<String, dynamic> _server(String tag, String host, {Object? sections}) => {
      'kind': 'server',
      'tag': tag,
      'enabled': true,
      'body': {'type': 'trojan', 'server': host, 'server_port': 443, 'password': 'p'},
      'sections': ?sections,
    };

({List<ServerList> lists, List<CustomRule> rules}) _apply(
  List<ServerList> lists,
  LxBackupFile file,
) {
  final subs = mergeBackupSubscriptions(lists, file.subscriptions);
  final servers = mergeBackupServers(
    subs.lists,
    file.servers,
    folders: file.folders,
    sourceIds: subs.ids,
    addedSources: subs.added,
    sourceDetours: subs.detours,
  );
  return (
    lists: servers.lists,
    rules: renumberBackupAxis(file.rules, servers.lists, servers.touched),
  );
}

void main() {
  group('§438 версии формата', () {
    test('пишем 2, читаем 2 и legacy 1', () async {
      expect(kLxBackupVersion, kLxBackupFormat10);
      final out = await buildLxBackup(lists: const [], rules: const [], vars: const {});
      expect((jsonDecode(out.json) as Map)['lx_backup'], 2);
      expect(parseLxBackup(_file({})).version, 2);
      expect(parseLxBackup(jsonEncode({'lx_backup': 1})).version, 1);
    });

    test('больше читаемого и вне {1, 2} — отказ', () {
      expect(() => parseLxBackup(jsonEncode({'lx_backup': 3})), throwsFormatException);
      expect(() => parseLxBackup(jsonEncode({'lx_backup': 0})), throwsFormatException);
    });

    test('ключи 0.12 в файле 1.0 — неизвестные', () {
      final file = parseLxBackup(_file({
        'servers': [
          {'uri': 'vless://u@h:443'},
        ],
      }));
      expect(file.servers, isEmpty);
      expect(file.warnings.map((w) => '${w.code} ${w.detail}'),
          contains('$kWarnUnknownField servers'));
    });
  });

  group('§438 папки: id, затем имя', () {
    Map<String, dynamic> folder(String id, String name, String host) => {
          'kind': 'folder',
          'id': id,
          'name': name,
          'nodes': [_server('n-$id', host)],
        };

    test('две тёзки файла в пустое состояние — две папки; повторный импорт не растёт', () {
      final raw = _file({
        'sources': [
          folder('FA', 'Folder 1', 'example-1.com'),
          folder('FB', 'Folder 1', 'example-2.com'),
        ],
      });
      final first = _apply(const [], parseLxBackup(raw));
      final folders = first.lists.whereType<FolderServers>().toList();
      expect(folders.map((f) => f.id), ['FA', 'FB']);
      expect(folders.map((f) => f.members.length), [1, 1],
          reason: 'вторая тёзка файла не дописывается в первую');

      final second = _apply(first.lists, parseLxBackup(raw));
      final again = second.lists.whereType<FolderServers>().toList();
      expect(again.map((f) => f.id), ['FA', 'FB']);
      expect(again.map((f) => f.members.length), [1, 1],
          reason: 'собственный экспорт не растит состояние');
    });

    test('совпавшая папка берёт настройки файла и держит свой id и имя', () {
      final local = FolderServers(
        id: 'local-id',
        name: 'Proton',
        enabled: false,
        tagPrefix: 'old',
        detourPolicy: DetourPolicy.defaults,
      );
      final out = _apply([local], parseLxBackup(_file({
        'sources': [
          {'kind': 'folder', 'id': 'file-id', 'name': 'Proton', 'enabled': true,
           'tag_policy': {'prefix': 'pr', 'postfix': '-x'}},
        ],
      })));
      final got = out.lists.single as FolderServers;
      expect(got.id, 'local-id');
      expect(got.name, 'Proton');
      expect(got.enabled, isTrue);
      expect(got.tagPrefix, 'pr');
    });

    test('папка 0.x по-прежнему по имени, настройки не трогает', () {
      final local = FolderServers(
        id: 'local-id',
        name: 'DE',
        enabled: false,
        tagPrefix: 'keep',
        detourPolicy: DetourPolicy.defaults,
      );
      final file = parseLxBackup(jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'servers': [
          {'uri': 'vless://u@h:443#a', 'folder': 'DE'},
        ],
      }));
      final got = _apply([local], file).lists.single as FolderServers;
      expect(got.enabled, isFalse);
      expect(got.tagPrefix, 'keep');
      expect(got.members, hasLength(1));
    });

    test('хоп в папку файла получает префикс совпавшей папки', () {
      final raw = _file({
        'sources': [
          {
            'kind': 'folder',
            'id': 'FILE',
            'name': 'EU',
            'tag_policy': {'prefix': 'eu'},
            'nodes': [_server('de', 'example-1.com')],
          },
          _server('jp', 'example-2.com'),
          {
            'kind': 'chain',
            'tag': 'c',
            'enabled': true,
            'body': {'type': 'chain'},
            'hops': [
              {'folder_id': 'FILE', 'tag': 'de'},
              {'tag': 'jp'},
              {'folder_id': 'NOWHERE', 'tag': 'ghost'},
            ],
          },
        ],
      });
      final file = parseLxBackup(raw);
      final subs = mergeBackupSubscriptions(const [], file.subscriptions);
      final servers =
          mergeBackupServers(subs.lists, file.servers, folders: file.folders);
      final chain =
          resolveBackupChainHops(file, servers.lists, servers.folderIds).single;
      expect(chain.hops, ['eu de', 'jp', 'ghost'],
          reason: 'ссылка без папки ввозится как есть');
    });
  });

  group('§438 секции узла', () {
    Map<String, dynamic> sections(String name) => {
          'rules': [
            {'kind': 'inline', 'name': name, 'enabled': true, 'num': 945,
             'body': {'ip_cidr': ['100.64.0.0/10']}},
          ],
        };

    test('совпавший по телу узел: поле есть — замещает, нет — свои остаются, пустое — снимает', () {
      final first = _apply(const [], parseLxBackup(_file({
        'sources': [_server('ts', 'example-1.com', sections: sections('mine'))],
      })));
      expect((first.lists.single as UserServer).sections!.rules.single.name, 'mine');
      expect((first.lists.single as UserServer).sections!.rules.single.outbound, '@self',
          reason: 'B5: без outbound и action — @self');

      final replaced = _apply(first.lists, parseLxBackup(_file({
        'sources': [_server('renamed', 'example-1.com', sections: sections('file'))],
      })));
      expect(replaced.lists, hasLength(1), reason: 'тот же узел по телу');
      expect((replaced.lists.single as UserServer).sections!.rules.single.name, 'file');

      final kept = _apply(replaced.lists, parseLxBackup(_file({
        'sources': [_server('ts', 'example-1.com')],
      })));
      expect((kept.lists.single as UserServer).sections!.rules.single.name, 'file');

      final cleared = _apply(kept.lists, parseLxBackup(_file({
        'sources': [_server('ts', 'example-1.com', sections: <String, dynamic>{})],
      })));
      expect((cleared.lists.single as UserServer).sections, isNull);
    });

    test('секции у подписки — not_allowed; член папки chain — kind_unsupported; unsupported с исходником — член', () {
      final file = parseLxBackup(_file({
        'sources': [
          {'kind': 'subscription', 'url': 'https://example-1.com/s', 'name': 'S',
           'sections': sections('x')},
          {
            'kind': 'folder',
            'id': 'F',
            'name': 'F',
            'nodes': [
              {'kind': 'chain', 'tag': 'via', 'enabled': true, 'hops': [{'tag': 'a'}]},
              {'kind': 'auto', 'tag': 'grp', 'enabled': true},
              {'kind': 'unsupported', 'tag': 'odd', 'enabled': true,
               'origin': {'kind': 'uri', 'raw': 'weird://thing'}, 'reason': 'no parser'},
            ],
          },
          {'kind': 'auto', 'tag': 'root-group', 'enabled': true},
        ],
      }));
      final dropped = file.warnings.where((w) => w.code == kWarnSectionRecordDropped).single;
      expect(dropped.reason, kSectionDropNotAllowed);
      expect(dropped.kind, 'subscription');
      final kinds = file.warnings
          .where((w) => w.code == kWarnSourceKindUnsupported)
          .map((w) => w.kind)
          .toList();
      expect(kinds, ['chain', 'auto', 'auto']);
      expect(file.servers.single.uri, 'weird://thing');
      final folder = _apply(const [], file).lists.whereType<FolderServers>().single;
      expect(folder.members.single.raw, 'weird://thing');
      expect(folder.members.single.node, isNull, reason: 'нечитаемый член виден в папке');
    });
  });

  group('§438 ось правил: корневые и узловые вместе', () {
    test('номера файла держатся, неразмеченные корневые — в хвост оси', () {
      final file = parseLxBackup(_file({
        'sources': [
          _server('ts', 'example-1.com', sections: {
            'rules': [
              {'kind': 'inline', 'name': 'node', 'enabled': true,
               'body': {'ip_cidr': ['100.64.0.0/10']}},
            ],
          }),
        ],
        'rules': [
          {'kind': 'inline', 'name': 'late', 'enabled': true, 'num': 1100,
           'body': {'domain': ['b'], 'outbound': 'direct'}},
          {'kind': 'inline', 'name': 'unmarked', 'enabled': true,
           'body': {'domain': ['c'], 'outbound': 'direct'}},
          {'kind': 'inline', 'name': 'head', 'enabled': true, 'num': 0,
           'body': {'domain': ['a'], 'outbound': 'direct'}},
        ],
      }));
      final out = _apply(const [], file);
      expect([for (final r in out.rules) '${r.name}=${r.orderNum}'],
          ['head=0', 'late=1100', 'unmarked=1101']);
      final node = (out.lists.single as UserServer).sections!.rules.single;
      expect(node.orderNum, isNull,
          reason: 'без num узловое остаётся без номера — сборка ставит его на 945');
    });

    test('номера файла держатся, порядок сохраняется, равные остаются равными', () {
      // Раскладка шаблона: голова 0, пресеты 950–990, зона 1000–1100,
      // перехватчики 1110+. Правило из UI после импорта встаёт в конец зоны,
      // пресет из шаблона — на свой номер, и оба оказываются там же, где до
      // импорта (§438, v2.23.2 номера сохранял).
      final file = parseLxBackup(jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'lxbox'},
        'rules': [
          {'kind': 'preset', 'name': 'ru-inside', 'ref': 'ru-inside', 'num': 1110},
          {'kind': 'inline', 'name': 'user-b', 'num': 1001, 'outbound': 'direct', 'match': {}},
          {'kind': 'preset', 'name': 'tp', 'ref': 'traffic-processing', 'num': 0},
          {'kind': 'inline', 'name': 'user-a', 'num': 1000, 'outbound': 'direct', 'match': {}},
          {'kind': 'inline', 'name': 'dup', 'num': 1000, 'outbound': 'direct', 'match': {}},
          {'kind': 'preset', 'name': 'private', 'ref': 'private-ip', 'num': 950},
        ],
      }));
      final rules = renumberBackupAxis(file.rules, const [], const []);
      expect([for (final r in rules) '${r.name}=${r.orderNum}'], [
        'tp=0',
        'private=950',
        'user-a=1000',
        'dup=1000',
        'user-b=1001',
        'ru-inside=1110',
      ]);
    });
  });

  group('§438 правила 1.0', () {
    test('method: drop и самостоятельный action — вид json телом целиком', () {
      final file = parseLxBackup(_file({
        'rules': [
          {'kind': 'inline', 'name': 'drop', 'enabled': true, 'num': 1,
           'body': {'domain': ['a'], 'action': 'reject', 'method': 'drop'}},
          {'kind': 'inline', 'name': 'sniff', 'enabled': true, 'num': 2,
           'body': {'action': 'sniff'}},
        ],
      }));
      expect(file.warnings, isEmpty);
      final drop = file.rules[0] as CustomRuleJson;
      expect(jsonDecode(drop.json), {'domain': ['a'], 'action': 'reject', 'method': 'drop'});
      expect(file.rules[1], isA<CustomRuleJson>());
    });

    test('rule_set в теле и srs с незнакомым ключом — отброс с предупреждением', () {
      final file = parseLxBackup(_file({
        'rules': [
          {'kind': 'inline', 'name': 'rs', 'enabled': true,
           'body': {'rule_set': ['geo'], 'outbound': 'direct'}},
          {'kind': 'srs', 'name': 'srs', 'enabled': true, 'refs': ['https://x/a.srs'],
           'body': {'process_name': ['a'], 'outbound': 'direct'}},
          {'kind': 'json', 'name': 'legacy', 'enabled': true},
        ],
      }));
      expect(file.rules, isEmpty);
      expect(file.warnings.map((w) => w.code).toSet(), {kWarnUnknownField});
      expect(file.warnings, hasLength(3));
    });

    test('цель вне известных — выключено; preset без имени зовётся ссылкой', () {
      final file = parseLxBackup(
        _file({
          'rules': [
            {'kind': 'inline', 'name': 'ghost', 'enabled': true,
             'body': {'domain': ['a'], 'outbound': 'vpn-9'}},
            {'kind': 'preset', 'ref': 'block_ads', 'enabled': true},
          ],
        }),
        knownOutbounds: {'proxy'},
      );
      expect(file.rules[0].enabled, isFalse);
      expect(file.warnings.single.code, kWarnUnknownOutbound);
      expect(file.rules[1].name, 'block_ads');
    });
  });

  group('§438 DNS', () {
    test('preset-серверы по ref, правила по телу, безымянное правило получает имя', () {
      final file = parseLxBackup(_file({
        'dns': {
          'default_domain_resolver': 'local',
          'servers': [
            {'kind': 'preset', 'ref': 'yandex_udp', 'enabled': true},
            {'kind': 'preset', 'ref': 'yandex_doh', 'enabled': true},
            {'kind': 'preset', 'ref': 'yandex_dot', 'enabled': false},
          ],
          'rules': [
            {'kind': 'user', 'enabled': true,
             'body': {'domain_suffix': ['.corp'], 'server': 'yandex_doh'}},
            {'kind': 'user', 'enabled': true,
             'body': {'domain_suffix': ['.corp'], 'server': 'yandex_udp'}},
          ],
        },
      }));
      expect(file.warnings, isEmpty);
      final first = applyDnsBackup(
        incoming: file.dns!,
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
      );
      expect(first.servers.map((e) => e.tag), ['yandex_udp', 'yandex_doh', 'yandex_dot'],
          reason: 'preset без тега не схлопывается в одну запись');
      expect(first.rules.map((e) => (e as DnsRuleInline).name), ['.corp', '.corp-2']);
      expect(first.defaultDomainResolver, 'local');

      final again = applyDnsBackup(
        incoming: file.dns!,
        servers: first.servers,
        rules: first.rules,
        dnsFinal: first.dnsFinal,
        strategy: first.strategy,
      );
      expect(again.servers, hasLength(3));
      expect(again.rules, hasLength(2), reason: 'правило узнаётся по телу');
      expect(again.applied, 0);
    });
  });

  group('§438 файл 1.0 лаунчера', () {
    // `test/fixtures/lx_backup/launcher_v8_export10.json` — Export10 лаунчера
    // над его `core/state/testdata/v8_roundtrip.json` (без правок руками).
    test('импорт в пустое состояние: ожидаемые потери и только они', () {
      final template = jsonDecode(File('assets/wizard_template.json').readAsStringSync())
          as Map<String, dynamic>;
      final presets = (template['selectable_rules'] as List).cast<Map<String, dynamic>>();
      final file = parseLxBackup(
        File('test/fixtures/lx_backup/launcher_v8_export10.json').readAsStringSync(),
        knownPresets: {for (final p in presets) p['preset_id'] as String},
      );
      expect([for (final w in file.warnings) '${w.code} ${w.detail}'], [
        '$kWarnSourceKindUnsupported Личные: быстрые',
        '$kWarnDnsEntrySkipped dns.servers: russian:yandex_udp',
        '$kWarnDnsEntrySkipped dns.rules: russian',
      ]);

      final state = _apply(const [], file);
      final kinds = [for (final l in state.lists) l.runtimeType.toString()];
      expect(kinds, ['UserServer', 'FolderServers', 'SubscriptionServers'],
          reason: 'порядок файла');
      final root = state.lists[0] as UserServer;
      expect(root.name, '🇯🇵 Tokyo');
      expect(root.detourPolicy.overrideDetour, '[P] NL-1',
          reason: 'префикс подписки «[P] » у LxBox — «[P]» и пробел');
      expect(root.sections!.dnsServers.single.tag, '@{self}-dns');
      final folder = state.lists[1] as FolderServers;
      expect(folder.tagPrefix, '[F]');
      expect(folder.members.single.raw, 'ss://Y2hhY2hh@de.example:8388#DE-1',
          reason: 'исходник члена едет как есть (что LxBox из него разберёт — дело парсера)');
      final sub = state.lists[2] as SubscriptionServers;
      expect(sub.tagPrefix, '[P]');
      expect(sub.updateIntervalHours, 6);
      expect(sub.disabledHashes.keys, ['DE-2']);

      final subs = mergeBackupSubscriptions(const [], file.subscriptions);
      final servers = mergeBackupServers(
        subs.lists,
        file.servers,
        folders: file.folders,
        sourceIds: subs.ids,
        addedSources: subs.added,
        sourceDetours: subs.detours,
      );
      expect(resolveBackupChainHops(file, servers.lists, servers.folderIds).single.hops,
          ['🇯🇵 Tokyo', '[P] NL-1']);
      expect(
        [for (final r in state.rules) '${r.kind.name}:${r.name}:${r.orderNum}'],
        ['preset:ru-direct:960', 'inline:X:1000', 'json:blocked:1005', 'srs:three sets:1010'],
      );
      expect(state.rules[3].outbound, kOutboundReject);
      expect(file.dns!.servers.map((s) => dnsServerToRecord(s)['kind']),
          ['template', 'user']);
      expect(file.dns!.servers.last, isA<DnsServerInline>());
    });
  });

  group('§438 кодек и канон тела', () {
    test('action кроме reject — незнакомый ключ; preset-сервер пишется ref', () {
      final read = ruleFromRecord({
        'kind': 'inline',
        'name': 'x',
        'body': {'action': 'hijack-dns'},
      });
      expect(read.unknownKeys, ['action']);
      final rec = dnsServerToRecord(dnsServerFromRecord({'kind': 'preset', 'ref': 'p'}).value!);
      expect(rec['ref'], 'p');
      expect(rec.containsKey('tag'), isFalse);
    });

    test('многострочный текст не режется по #', () {
      const a = '# comment A\n[Interface]\nPrivateKey = a\n';
      const b = '# comment A\n[Interface]\nPrivateKey = b\n';
      expect(canonicalNodeBody(a), isNot(canonicalNodeBody(b)));
      expect(canonicalNodeBody('vless://u@h:443#N'), 'vless://u@h:443');
    });

    test('секции узла: rule_set — rule_set, незнакомый ключ — unknown_key, чужой kind — kind', () {
      final drops = <NodeSectionDrop>[];
      NodeSections.fromJson({
        'rules': [
          {'kind': 'preset', 'ref': 'x'},
          {'kind': 'inline', 'name': 'r', 'body': {'rule_set': ['a']}},
          {'kind': 'inline', 'name': 'p', 'body': {'process_name': ['a']}},
        ],
        'dns': {
          'servers': [
            {'kind': 'template', 'tag': 't'},
          ],
        },
      }, drops: drops);
      expect([for (final d in drops) '${d.kind}:${d.reason}'],
          ['preset:kind', 'inline:rule_set', 'inline:unknown_key', 'template:kind']);
    });
  });
}
