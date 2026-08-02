import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/probe/probe_config.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

/// §236 — headless probe: конфиг, раннер (probe-сессия; при живом VPN —
/// маркер-гейт, боевое ядро НЕ зовётся), пороги шкалы.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  FolderServers folder({List<FolderMember>? members, bool enabled = true}) =>
      FolderServers(
        id: 'f-1',
        name: 'F',
        enabled: enabled,
        tagPrefix: 'pr:',
        detourPolicy: DetourPolicy.defaults,
        members: members ??
            [
              FolderMember(raw: uriA),
              FolderMember(raw: uriB, enabled: false),
            ],
      );

  // §296 — probe теперь над List<NodeSpec?>; папка приводит члены к нодам
  // (nullable, unfiltered) — тот же bridge, что folder_detail/folders.dart.
  List<NodeSpec?> nodesOf(FolderServers f) =>
      [for (final m in f.members) m.node];
  ProbeConfig cfgOf(FolderServers f) => buildProbeConfig(nodesOf(f));

  group('§236 buildProbeConfig', () {
    test('ВСЕ члены (включая выключенных) попадают в конфиг, теги голые', () {
      final cfg = cfgOf(folder());
      expect(cfg.configJson, isNotNull);
      final config = jsonDecode(cfg.configJson!) as Map<String, dynamic>;
      final tags = (config['outbounds'] as List)
          .map((o) => (o as Map)['tag'] as String)
          .toList();
      expect(tags, containsAll(['Alpha', 'Beta'])); // без префикса папки
      expect(cfg.tagByIndex, {0: 'Alpha', 1: 'Beta'});
      // Без inbound'ов (openTun не должен вызываться) + local-резолвер.
      expect(config.containsKey('inbounds'), isFalse);
      expect((config['route'] as Map)['default_domain_resolver'], kProbeDnsTag);
      final dnsServers = ((config['dns'] as Map)['servers'] as List);
      expect((dnsServers.single as Map)['type'], 'local');
    });

    test('битый член исключён из конфига с вердиктом broken', () {
      final cfg = cfgOf(folder(members: [
        FolderMember(raw: uriA),
        FolderMember(raw: 'garbage-not-a-config'),
      ]));
      expect(cfg.tagByIndex.keys, [0]);
      expect(cfg.brokenByIndex, {1: 'broken'});
    });

    test('все битые → configJson == null', () {
      final cfg = cfgOf(folder(members: [
        FolderMember(raw: 'garbage-1'),
        FolderMember(raw: 'garbage-2'),
      ]));
      expect(cfg.configJson, isNull);
      expect(cfg.brokenByIndex.length, 2);
    });

    // §336 — автоузел (§322) в probe не тестируется: его emitRaw — заготовка
    // urltest с пустым outbounds, ядро валило на ней ВЕСЬ probe-конфиг
    // «missing tags» (4PDA #1406/#1407). Группа получает вердикт 'group'.
    test('§336: узел-группа не эмитится, вердикт group, соседи целы', () {
      final cfg = cfgOf(folder(members: [
        FolderMember(raw: uriA),
        FolderMember(raw: 'autogroup://#My%20auto'),
      ]));
      expect(cfg.tagByIndex, {0: 'Alpha'});
      expect(cfg.brokenByIndex, {1: 'group'});
      final config = jsonDecode(cfg.configJson!) as Map<String, dynamic>;
      final types = (config['outbounds'] as List)
          .map((o) => (o as Map)['type'] as String)
          .toSet();
      expect(types, isNot(contains('urltest')));
    });

    test('§336: папка из одних групп → configJson == null', () {
      final cfg = cfgOf(folder(members: [
        FolderMember(raw: 'autogroup://#A1'),
        FolderMember(raw: 'autogroup://#A2'),
      ]));
      expect(cfg.configJson, isNull);
      expect(cfg.brokenByIndex, {0: 'group', 1: 'group'});
    });

    test('коллизия тегов членов уникализируется', () {
      final cfg = cfgOf(folder(members: [
        FolderMember(raw: uriA),
        FolderMember(raw: uriA),
      ]));
      expect(cfg.tagByIndex[0], 'Alpha');
      expect(cfg.tagByIndex[1], 'Alpha-2');
    });
  });

  group('§236 ProbeRunner (mock method channel)', () {
    const channel = MethodChannel('com.leadaxe.lxbox/methods');
    final calls = <MethodCall>[];
    String probeStartAnswer = '';

    setUp(() {
      calls.clear();
      probeStartAnswer = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'probeStart':
            return probeStartAnswer;
          case 'probeUrlTest':
            final tag = (call.arguments as Map)['tag'] as String;
            // Alpha живой (120мс), остальные — err.
            return tag == 'Alpha'
                ? {'delay': 120, 'error': ''}
                : {'delay': 0, 'error': 'timeout'};
          case 'probeStop':
            return null;
          case 'ccUrlTestOutbound':
            return {'delay': 42, 'error': ''};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('VPN выключен: сессия, тестируются ВСЕ члены, teardown', () async {
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder()),
        url: 'https://example.com/gen204',
        timeoutMs: 3000,
        onResult: (i, r) => results[i] = r,
      );
      expect(err, isEmpty);
      expect(results[0]!.status, ProbeStatus.ok);
      expect(results[0]!.delayMs, 120);
      // Выключенный член тоже протестирован (probe-сессия).
      expect(results[1]!.status, ProbeStatus.failed);
      expect(calls.map((c) => c.method), contains('probeStop'));
    });

    test('§336: группа получает вердикт group; папка из одних групп не '
        'поднимает сессию', () async {
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder(members: [
          FolderMember(raw: 'autogroup://#My%20auto'),
        ])),
        url: '',
        timeoutMs: 0,
        onResult: (i, r) => results[i] = r,
      );
      expect(err, isEmpty);
      expect(results[0]!.status, ProbeStatus.group);
      expect(calls.map((c) => c.method), isNot(contains('probeStart')));
    });

    test('битые члены получают вердикт до ядра', () async {
      final results = <int, ProbeResult>{};
      await ProbeRunner().run(
        nodesOf(folder(members: [
          FolderMember(raw: uriA),
          FolderMember(raw: 'garbage'),
        ])),
        url: '',
        timeoutMs: 0,
        onResult: (i, r) => results[i] = r,
      );
      expect(results[1]!.status, ProbeStatus.broken);
    });

    test('VPN запущен: маркер-гейт, боевое ядро не зовётся', () async {
      probeStartAnswer = 'VPN is running — test needs its own core session';
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder()),
        url: '',
        timeoutMs: 0,
        onResult: (i, r) => results[i] = r,
      );
      // §236 UI-rework — тест через боевое ядро выпилен: возвращаем маркер,
      // UI показывает гейт-попап (Stop VPN). Ни одной ноды не тестируем.
      expect(err, kProbeVpnRunning);
      expect(results, isEmpty);
      expect(calls.map((c) => c.method), isNot(contains('ccUrlTestOutbound')));
      // Сессия не поднялась → probeStop не нужен.
      expect(calls.map((c) => c.method), isNot(contains('probeStop')));
    });

    test('фатальная ошибка старта (не «vpn running») возвращается наружу',
        () async {
      probeStartAnswer = 'create service: parse config: boom';
      final err = await ProbeRunner().run(
        nodesOf(folder()),
        url: '',
        timeoutMs: 0,
        onResult: (_, _) {},
      );
      expect(err, contains('boom'));
    });
  });

  group('§236 ProbeThresholds', () {
    test('дефолты NeoCat 250/500/700 и границы включительно', () {
      const t = ProbeThresholds();
      expect(t.bandOf(0), 0);
      expect(t.bandOf(250), 0);
      expect(t.bandOf(251), 1);
      expect(t.bandOf(500), 1);
      expect(t.bandOf(501), 2);
      expect(t.bandOf(700), 2);
      expect(t.bandOf(701), 3);
    });
  });
}
