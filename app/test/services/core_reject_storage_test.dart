// Фича 478 — хранение вердикта и его снятие (PARSING_PRINCIPLES §9.4). Переезд в бэкап — §489.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller/core_reject_ops.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

SubscriptionServers _sub({
  required List<String> uris,
  Map<String, DateTime> disabled = const {},
  Map<String, List<StoredWarning>> warnings = const {},
}) =>
    SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      disabledHashes: disabled,
      nodeWarnings: warnings,
      nodes: [for (final u in uris) parseUri(u)!],
    );

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  group('запись вердикта', () {
    test('форма лаунчера: code + params, без path и severity', () {
      final w = StoredWarning.coreRejected('parse encryption: bad');
      expect(w.toJson(), {
        'code': 'core_rejected',
        'params': {'reason': 'parse encryption: bad'},
      });
      expect(w.isCoreRejected, true);
      expect(w.reason, 'parse encryption: bad');
    });

    test('round-trip через JSON', () {
      final w = StoredWarning.coreRejected('bad key');
      expect(StoredWarning.fromJson(jsonDecode(jsonEncode(w.toJson()))), w);
    });

    test('негодная запись отбрасывается молча', () {
      expect(StoredWarning.fromJson('строка'), isNull);
      expect(StoredWarning.fromJson({'params': {}}), isNull);
      expect(StoredWarning.fromJson({'code': ''}), isNull);
      expect(storedWarningsFromJson(['мусор', 42]), isEmpty);
    });

    test('дубль по коду ЗАМЕЩАЕТСЯ свежим, вердикт идёт первым', () {
      final other = const StoredWarning(code: 'tls_insecure');
      final first = StoredWarning.coreRejected('первая');
      final second = StoredWarning.coreRejected('вторая');
      final out = upsertVerdict(upsertVerdict([other], first), second);
      expect(out.first, second, reason: 'приговор уровня узла — первым');
      expect(out.where((w) => w.isCoreRejected).length, 1);
      expect(out, contains(other), reason: 'прочие записи сохраняются');
    });

    test('снятие вердикта не трогает прочие записи', () {
      final other = const StoredWarning(code: 'tls_insecure');
      final out = dropVerdict([StoredWarning.coreRejected('x'), other]);
      expect(out, [other]);
    });

    test('вердикт рендерится предупреждением уровня error', () {
      final w = coreRejectedWarningOf('parse encryption: bad');
      expect(w.code, 'core_rejected');
      expect(w.params['reason'], 'parse encryption: bad');
    });
  });

  group('кодек записи источника', () {
    test('подписка: warnings рядом с disabled, round-trip', () {
      final sub = _sub(
        uris: ['vless://11111111-1111-1111-1111-111111111111@h1:443?type=ws&security=tls#A'],
        disabled: {'A': DateTime.utc(2026, 9, 19)},
        warnings: {
          'A': [StoredWarning.coreRejected('parse encryption: bad')]
        },
      );
      final rec = sourceToRecord(sub);
      expect(rec['warnings'], {
        'A': [
          {
            'code': 'core_rejected',
            'params': {'reason': 'parse encryption: bad'}
          }
        ]
      });
      final read = sourceFromRecord(rec).value as SubscriptionServers;
      expect(read.nodeWarnings['A']!.single.reason,
          'parse encryption: bad');
      expect(read.disabledHashes.keys, ['A']);
    });

    test('пустой оверлей ключа не пишет', () {
      final rec = sourceToRecord(_sub(uris: ['vless://11111111-1111-1111-1111-111111111111@h:443#A']));
      expect(rec.containsKey('warnings'), false);
    });

    test('ручной сервер: warnings рядом с enabled', () {
      final srv = UserServer(
        id: 'u1',
        name: '',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: 'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#S',
        warnings: [StoredWarning.coreRejected('bad')],
      );
      final rec = sourceToRecord(srv);
      expect((rec['warnings'] as List).single,
          {'code': 'core_rejected', 'params': {'reason': 'bad'}});
      final read = sourceFromRecord(rec).value as UserServer;
      expect(read.warnings.single.reason, 'bad');
      expect(read.enabled, false);
    });

    test('член папки: warnings рядом с enabled', () {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        createdAt: DateTime.utc(2026, 9, 19),
        members: [
          FolderMember(
            raw: 'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#M',
            enabled: false,
            warnings: [StoredWarning.coreRejected('bad m')],
          ),
        ],
      );
      final rec = sourceToRecord(folder);
      final read = sourceFromRecord(rec).value as FolderServers;
      expect(read.members.single.warnings.single.reason, 'bad m');
      expect(read.members.single.enabled, false);
    });

    test('ключ warnings в allowlist — не попадает в unknown', () {
      final rec = sourceToRecord(_sub(
        uris: ['vless://11111111-1111-1111-1111-111111111111@h:443#A'],
        warnings: {'A': [StoredWarning.coreRejected('x')]},
      ));
      final read = sourceFromRecord(rec);
      expect(read.unknownKeys, isEmpty);
    });
  });

  group('применение вердикта', () {
    test('узел подписки: выключен + вердикт', () {
      final sub = _sub(uris: [
        'vless://11111111-1111-1111-1111-111111111111@h1:443?type=ws&security=tls#A',
        'vless://11111111-1111-1111-1111-111111111111@h2:443?type=ws&security=tls#B',
      ]);
      final out = applyVerdict(sub, sub.nodes[1], 'bad b');
      expect(out.changed, true);
      final next = out.list as SubscriptionServers;
      final id = sourceNodeIdentities(sub.nodes)[sub.nodes[1]]!;
      expect(next.disabledHashes.containsKey(id), true);
      final verdict = next.nodeWarnings[id]!.single;
      expect(verdict.reason, 'bad b');
      expect(
        verdict.coreRejectRef,
        CoreRejectNodeRef(sourceId: sub.id, nodeKey: id),
      );
    });

    test('чужой узел — changed:false, автоматики нет', () {
      final sub = _sub(uris: ['vless://11111111-1111-1111-1111-111111111111@h1:443#A']);
      final alien = parseUri('vless://11111111-1111-1111-1111-111111111111@h9:443#Z')!;
      expect(applyVerdict(sub, alien, 'bad').changed, false);
    });

    test('ручной сервер выключается своим выключателем', () {
      final node = parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#S')!;
      final srv = UserServer(
        id: 'u1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: 'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#S',
        nodes: [node],
      );
      final out = applyVerdict(srv, node, 'bad s');
      expect(out.changed, true);
      final next = out.list as UserServer;
      expect(next.enabled, false);
      expect(next.warnings.single.reason, 'bad s');
    });
  });

  group('снятие вердикта по телу узла (PARSING_PRINCIPLES §9.4 п. 1)', () {
    const id = 'A';
    final disabled = {id: DateTime.utc(2026, 9, 19)};
    final warnings = {
      id: [StoredWarning.coreRejected('bad')]
    };

    test('тело то же → вердикт держится, узел выключен', () {
      final r = refreshSubscriptionVerdicts(
        disabled: disabled,
        warnings: warnings,
        oldBodies: const {id: '{"a":1}'},
        newBodies: const {id: '{"a":1}'},
      );
      expect(r.disabled.containsKey(id), true);
      expect(r.warnings[id]!.single.isCoreRejected, true);
    });

    test('тело изменилось → вердикт снят И узел включён обратно', () {
      final r = refreshSubscriptionVerdicts(
        disabled: disabled,
        warnings: warnings,
        oldBodies: const {id: '{"a":1}'},
        newBodies: const {id: '{"a":2}'},
      );
      expect(r.disabled.containsKey(id), false);
      expect(r.warnings.containsKey(id), false);
    });

    test('старого тела нет → вердикт снимается', () {
      final r = refreshSubscriptionVerdicts(
        disabled: disabled,
        warnings: warnings,
        oldBodies: const {},
        newBodies: const {id: '{"a":1}'},
      );
      expect(r.disabled.containsKey(id), false);
      expect(r.warnings.containsKey(id), false);
    });

    test('узел ушёл из набора → запись доживает до GC', () {
      final r = refreshSubscriptionVerdicts(
        disabled: disabled,
        warnings: warnings,
        oldBodies: const {id: '{"a":1}'},
        newBodies: const {},
      );
      expect(r.warnings.containsKey(id), true);
    });

    test('узел, выключенный человеком (без вердикта), сменой тела не оживает',
        () {
      final r = refreshSubscriptionVerdicts(
        disabled: {'H': DateTime.utc(2026, 9, 19)},
        warnings: const {},
        oldBodies: const {'H': '{"a":1}'},
        newBodies: const {'H': '{"a":2}'},
      );
      expect(r.disabled.containsKey('H'), true);
    });

    test('прочие записи при смене тела переживают снятие вердикта', () {
      final r = refreshSubscriptionVerdicts(
        disabled: disabled,
        warnings: {
          id: [
            StoredWarning.coreRejected('bad'),
            const StoredWarning(code: 'tls_insecure'),
          ]
        },
        oldBodies: const {id: '{"a":1}'},
        newBodies: const {id: '{"a":2}'},
      );
      expect(r.warnings[id]!.map((w) => w.code), ['tls_insecure']);
    });
  });

  group('снятие вердикта ручной правкой узла (PARSING_PRINCIPLES §9.4 п. 1)', () {
    final verdict = [StoredWarning.coreRejected('bad')];
    // `late`: разбор обязан случиться ПОСЛЕ загрузки секций, а объявление
    // группы исполняется до `setUpAll`.
    late final a = parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=x#A')!;

    test('тело изменилось → вердикт снимается', () {
      expect(
        verdictDroppedByEdit(
          warnings: verdict,
          before: a,
          after: parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=y#A')!,
        ),
        true,
      );
    });

    test('пересохранение того же тела → вердикт держится', () {
      expect(
        verdictDroppedByEdit(
          warnings: verdict,
          before: a,
          // Другой порядок параметров — то же тело после нормализации.
          after: parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?security=tls&sni=x&type=ws#A')!,
        ),
        false,
      );
    });

    test('переименование — тоже смена тела: emit() включает tag', () {
      expect(
        verdictDroppedByEdit(
          warnings: verdict,
          before: a,
          after: parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=x#B')!,
        ),
        true,
        reason: 'та же функция, что на refetch; лишняя проверка ядром дешевле '
            'починенного узла, оставшегося выключенным',
      );
    });

    test('вердикта не было → правка ничего не включает', () {
      expect(
        verdictDroppedByEdit(
          warnings: const [StoredWarning(code: 'tls_insecure')],
          before: a,
          after: parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=y#A')!,
        ),
        false,
      );
    });

    test('сравнивать нечем (узла нет) → вердикт снимается', () {
      expect(verdictDroppedByEdit(warnings: verdict, before: null, after: a),
          true);
    });
  });

  group('вердикт на разобранном узле (§479)', () {
    test('хранимая запись дописывается в warnings узла первой', () {
      final nodes = [
        parseUri('vless://11111111-1111-1111-1111-111111111111@h1:443?type=ws&security=tls#A')!,
        parseUri('vless://11111111-1111-1111-1111-111111111111@h2:443?type=ws&security=tls#B')!,
      ];
      stampStoredVerdicts(nodes, {
        'B': [StoredWarning.coreRejected('parse encryption: bad')]
      });
      expect(nodes[0].warnings.whereType<RegistryWarning>().where(
          (w) => w.code == 'core_rejected'), isEmpty);
      final w = nodes[1].warnings.first as RegistryWarning;
      expect(w.code, 'core_rejected');
      expect(w.params['reason'], 'parse encryption: bad');
    });

    test('повторное проставление не плодит дублей', () {
      final nodes = [parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#A')!];
      final stored = {'A': [StoredWarning.coreRejected('bad')]};
      stampStoredVerdicts(nodes, stored);
      stampStoredVerdicts(nodes, stored);
      expect(
          nodes.single.warnings
              .whereType<RegistryWarning>()
              .where((w) => w.code == 'core_rejected')
              .length,
          1);
    });

    test('пустой оверлей узлы не трогает', () {
      final nodes = [parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#A')!];
      final before = nodes.single.warnings.length;
      stampStoredVerdicts(nodes, const {});
      expect(nodes.single.warnings.length, before);
    });
  });

  group('GC оверлея warnings (спека 478 §3b)', () {
    test('ключ без disabled и без узла в наборе выбрасывается', () {
      final out = gcNodeWarnings(
        {
          'gone': [StoredWarning.coreRejected('bad')],
          'live': [StoredWarning.coreRejected('bad')],
        },
        {'live': DateTime.utc(2026, 9, 19)},
        {'live'},
      );
      expect(out.containsKey('gone'), isFalse);
      expect(out.containsKey('live'), isTrue);
    });
  });

  group('revertVerdict по NodeSpec (enable по emitted-тегу)', () {
    test('снимает вердикт с узла подписки', () {
      final list = _sub(
        uris: [
          'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#Frankfurt',
        ],
      );
      final node = list.nodes.single;
      final applied = applyVerdict(list, node, 'bad');
      expect(applied.changed, isTrue);
      final reverted = revertVerdict(applied.list, node);
      expect(reverted.changed, isTrue);
      final sub = reverted.list as SubscriptionServers;
      expect(sub.disabledHashes.containsKey('Frankfurt'), isFalse);
      expect(sub.nodeWarnings.containsKey('Frankfurt'), isFalse);
    });
  });

  group('каноническое тело', () {
    test('одинаковые узлы дают одинаковую форму, разные — разную', () {
      final a = parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=x#A')!;
      final b = parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=x#A')!;
      final c = parseUri('vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls&sni=y#A')!;
      expect(canonicalNodeBody(a), canonicalNodeBody(b));
      expect(canonicalNodeBody(a), isNot(canonicalNodeBody(c)),
          reason: 'SNI видна каноническому телу, в отличие от идентичности');
    });

    test('тела набора по идентичности', () {
      final nodes = [
        parseUri('vless://11111111-1111-1111-1111-111111111111@h1:443?type=ws&security=tls#A')!,
        parseUri('vless://11111111-1111-1111-1111-111111111111@h2:443?type=ws&security=tls#B')!,
      ];
      final m = bodiesByIdentity(nodes);
      expect(m.keys.toSet(), {'A', 'B'});
      expect(m['A'], isNot(m['B']));
    });
  });
}
