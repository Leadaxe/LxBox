import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/probe/probe_config.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

import '../parser/engine_test_setup.dart';

/// §236 — headless probe: конфиг, раннер (probe-сессия; при живом VPN —
/// маркер-гейт, боевое ядро НЕ зовётся), пороги шкалы.
/// §439 N2 — член-группа папки (запись `kind: auto`), текста у неё нет.
FolderMember _group(String tag) => FolderMember.auto(
    AutoSelectSpec(id: tag, tag: tag, label: tag, membership: const RuleMembers()));

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

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
        _group('My auto'),
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
        _group('A1'),
        _group('A2'),
      ]));
      expect(cfg.configJson, isNull);
      expect(cfg.brokenByIndex, {0: 'group', 1: 'group'});
    });

    // ═══ §518 — naive и OOM пробы ══════════════════════════════════════════
    //
    // Каждый naive-outbound поднимает Chromium-движок (cronet
    // `engineCount`), десяток в одном probe-конфиге = OOM процесса при
    // `oomMemoryLimit` (§173/§271). Гейт: не больше
    // kProbeMaxNaivePerConfig naive на конфиг.
    group('§518 naive-гейт probe-конфига', () {
      String naive(String tag) => 'naive+https://u:p@$tag.example:443#$tag';

      List<Map<String, dynamic>> outboundsOf(ProbeConfig c) =>
          ((jsonDecode(c.configJson!) as Map)['outbounds'] as List)
              .cast<Map<String, dynamic>>();

      int naiveCountOf(ProbeConfig c) =>
          outboundsOf(c).where((o) => o['type'] == 'naive').length;

      test('5 naive + 3 vless: naive ≤ лимита на конфиг, все 8 проверены', () {
        final nodes = nodesOf(folder(members: [
          FolderMember(raw: naive('n1')),
          FolderMember(raw: uriA),
          FolderMember(raw: naive('n2')),
          FolderMember(raw: naive('n3')),
          FolderMember(raw: uriB),
          FolderMember(raw: naive('n4')),
          FolderMember(raw: 'vless://u3@h3.example:443?security=tls#Gamma'),
          FolderMember(raw: naive('n5')),
        ]));
        expect(nodes.every((n) => n != null), isTrue, reason: 'фикстуры парсятся');

        final batches = buildProbeBatches(nodes);
        // 5 naive по kProbeMaxNaivePerConfig(=1) → 5 батчей.
        expect(batches.length, (5 / kProbeMaxNaivePerConfig).ceil());
        for (final b in batches) {
          expect(naiveCountOf(b), lessThanOrEqualTo(kProbeMaxNaivePerConfig));
        }

        // Полнота и порядок: каждый из 8 индексов проверяется РОВНО один раз,
        // ни один не потерян и ни один не задублирован.
        final seen = <int>[];
        for (final b in batches) {
          seen.addAll(b.tagByIndex.keys);
        }
        expect(seen..sort(), [0, 1, 2, 3, 4, 5, 6, 7]);
        expect(batches.first.brokenByIndex, isEmpty);

        // Не-naive лежат в первом батче — как до §518 (один конфиг на всё).
        final firstTags = batches.first.tagByIndex;
        expect(firstTags.keys, containsAll([1, 4, 6]));
      });

      test('без naive — один батч, конфиг дословно как buildProbeConfig', () {
        final nodes = nodesOf(folder(members: [
          FolderMember(raw: uriA),
          FolderMember(raw: uriB),
        ]));
        final batches = buildProbeBatches(nodes);
        expect(batches.length, 1);
        expect(batches.single.configJson, buildProbeConfig(nodes).configJson);
      });

      test('insecure_concurrency снят у naive в ПРОБЕ, боевой emit цел', () {
        final node = FolderMember(raw: naive('n1')).node!;
        // §302 — import-rules кладут в узел патч тела; probe обязан снять
        // именно из своей копии, не из патча.
        final patch = node.emit(TemplateVars.empty);
        (patch as Outbound).map['insecure_concurrency'] = 8;
        node.patchedJson = patch.map;

        final cfg = buildProbeConfig([node]);
        final probeOut =
            outboundsOf(cfg).singleWhere((o) => o['type'] == 'naive');
        expect(probeOut.containsKey('insecure_concurrency'), isFalse,
            reason: 'в пробе движки не множим');

        // Боевой emit узла НЕ изменился: патч на месте, поле цело.
        final live = node.emit(TemplateVars.empty) as Outbound;
        expect(live.map['insecure_concurrency'], 8);
        expect(node.patchedJson!['insecure_concurrency'], 8);
      });

      test('naive c детуром: гейт считает записи, а не узлы', () {
        // Узел naive + chained naive = ДВЕ naive-записи, оба движка в одном
        // конфиге — гейт должен видеть обе (детур эмитится тем же конфигом).
        final chained = FolderMember(raw: naive('inner')).node!;
        final outer = FolderMember(raw: naive('outer')).node!;
        final withDetour = NaiveSpec(
          id: outer.id,
          tag: outer.tag,
          label: outer.label,
          server: outer.server,
          port: outer.port,
          rawSource: outer.rawSource,
          chained: chained,
        );
        final batches = buildProbeBatches([withDetour]);
        // 2 naive-записи > лимит(1), но узел неделим: он один и уходит в
        // единственный батч — гейт не может разорвать цепочку.
        expect(batches.length, 1);
        expect(naiveCountOf(batches.single), 2);
        expect(batches.single.tagByIndex.keys, [0]);
      });

      test('внутри батча — исходный порядок узлов (уникализация тегов)', () {
        // Одноимённые naive-узлы разъезжаются по батчам, и каждый получает
        // базовый тег: `usedTags` у батчей независим. А не-naive, подсаженный
        // к первому батчу, не должен перевешивать порядок обхода.
        final cfg = buildProbeBatches(nodesOf(folder(members: [
          FolderMember(raw: uriA), // 'Alpha', не naive
          FolderMember(raw: naive('n1')),
          FolderMember(raw: uriA), // тоже 'Alpha' → 'Alpha-2' в своём батче
        ])));
        expect(cfg.length, 1, reason: '1 naive при лимите 1 → один батч');
        expect(cfg.single.tagByIndex, {0: 'Alpha', 1: 'n1', 2: 'Alpha-2'});
      });

      test('битые и группы попадают в вердикты первого батча один раз', () {
        final nodes = nodesOf(folder(members: [
          FolderMember(raw: naive('n1')),
          FolderMember(raw: 'garbage'),
          FolderMember(raw: naive('n2')),
          _group('Auto'),
        ]));
        final batches = buildProbeBatches(nodes);
        expect(batches.length, 2);
        expect(batches.first.brokenByIndex, {1: 'broken', 3: 'group'});
        expect(batches[1].brokenByIndex, isEmpty);
      });
    });

    // ═══ §523 — WG/AWG-endpoint'ы и OOM пробы ══════════════════════════════
    //
    // Проба — это дайл, и ядро будит ВСЕ endpoint'ы конфига: каждый WG/AWG
    // предвыделяет пулы буферов (`PopulatePools`, 128×64 КБ × v4+v6) —
    // ≈17.5 МБ heap на endpoint по замеру на эмуляторе (192 МБ на 11).
    // Гейт: не больше kProbeMaxWireguardPerConfig endpoint'ов на конфиг.
    group('§523 WireGuard/AWG-гейт probe-конфига', () {
      const wgPriv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
      const wgPub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

      /// Обычный WG-узел (endpoint `type: wireguard`, без awg-полей).
      String wg(String tag) => 'wireguard://$wgPriv@$tag.example:51820'
          '?publickey=$wgPub&address=10.0.0.2/32&mtu=1420#$tag';

      /// §421/§097 — AmneziaWG: ТОТ ЖЕ endpoint `type: wireguard` плюс
      /// awg-поля в корне. Отдельного типа нет — гейт обязан считать и его.
      String awg(String tag) => 'wireguard://$wgPriv@$tag.example:51820'
          '?publickey=$wgPub&address=10.0.0.2/32&mtu=1408'
          '&jc=10&jmin=50&jmax=100&s1=20&s2=20&s3=60&s4=60'
          '&h1=1234567890&h2=1234567891&h3=1234567892&h4=1234567893#$tag';

      String naive(String tag) => 'naive+https://u:p@$tag.example:443#$tag';

      List<Map<String, dynamic>> endpointsOf(ProbeConfig c) {
        final config = jsonDecode(c.configJson!) as Map<String, dynamic>;
        return ((config['endpoints'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
      }

      int wgCountOf(ProbeConfig c) =>
          endpointsOf(c).where((e) => e['type'] == 'wireguard').length;

      int naiveCountOf(ProbeConfig c) =>
          ((jsonDecode(c.configJson!) as Map)['outbounds'] as List)
              .cast<Map<String, dynamic>>()
              .where((o) => o['type'] == 'naive')
              .length;

      test('9 WG (3 из них AWG) + 2 naive + 3 vless: оба лимита соблюдены, '
          'все 14 индексов проверены ровно раз', () {
        final nodes = nodesOf(folder(members: [
          FolderMember(raw: wg('w1')),
          FolderMember(raw: uriA),
          FolderMember(raw: awg('a1')),
          FolderMember(raw: wg('w2')),
          FolderMember(raw: naive('n1')),
          FolderMember(raw: wg('w3')),
          FolderMember(raw: uriB),
          FolderMember(raw: awg('a2')),
          FolderMember(raw: wg('w4')),
          FolderMember(raw: 'vless://u3@h3.example:443?security=tls#Gamma'),
          FolderMember(raw: awg('a3')),
          FolderMember(raw: wg('w5')),
          FolderMember(raw: naive('n2')),
          FolderMember(raw: wg('w6')),
        ]));
        expect(nodes.every((n) => n != null), isTrue,
            reason: 'фикстуры парсятся');
        // AWG действительно опознан как WG-endpoint с awg-полями, а не как
        // отдельный тип (иначе гейт мерил бы не то).
        final awgNode = nodes[2]!;
        expect(awgNode.protocol, 'wireguard');
        expect((awgNode as WireguardSpec).awg, isNotNull);

        final batches = buildProbeBatches(nodes);
        for (final b in batches) {
          expect(wgCountOf(b), lessThanOrEqualTo(kProbeMaxWireguardPerConfig),
              reason: 'WG не больше $kProbeMaxWireguardPerConfig на конфиг');
          expect(naiveCountOf(b), lessThanOrEqualTo(kProbeMaxNaivePerConfig),
              reason: 'naive по-прежнему по одному (§518)');
        }

        // Полнота: каждый из 14 индексов проверяется РОВНО один раз.
        final seen = <int>[];
        for (final b in batches) {
          seen.addAll(b.tagByIndex.keys);
        }
        expect(seen..sort(), [for (var i = 0; i < 14; i++) i]);
        expect(batches.first.brokenByIndex, isEmpty);

        // Не-WG/не-naive (vless) — в первом батче, как до §518.
        expect(batches.first.tagByIndex.keys, containsAll([1, 6, 9]));
      });

      test('смешанный батч допустим: 4 WG и 1 naive умещаются в один конфиг',
          () {
        final batches = buildProbeBatches(nodesOf(folder(members: [
          FolderMember(raw: wg('w1')),
          FolderMember(raw: wg('w2')),
          FolderMember(raw: naive('n1')),
          FolderMember(raw: wg('w3')),
          FolderMember(raw: wg('w4')),
        ])));
        expect(batches.length, 1, reason: '4 WG + 1 naive = оба лимита ровно');
        expect(wgCountOf(batches.single), 4);
        expect(naiveCountOf(batches.single), 1);
      });

      test('5-й WG уезжает в следующий батч, naive-лимит его не двигает', () {
        final batches = buildProbeBatches(nodesOf(folder(members: [
          for (var i = 1; i <= 5; i++) FolderMember(raw: wg('w$i')),
        ])));
        expect(batches.length, 2);
        expect(wgCountOf(batches.first), kProbeMaxWireguardPerConfig);
        expect(wgCountOf(batches[1]), 5 - kProbeMaxWireguardPerConfig);
      });

      test('конфиг без WG/naive — дословно прежний (batches == 1)', () {
        final nodes = nodesOf(folder(members: [
          FolderMember(raw: uriA),
          FolderMember(raw: uriB),
        ]));
        final batches = buildProbeBatches(nodes);
        expect(batches.length, 1);
        expect(batches.single.configJson, buildProbeConfig(nodes).configJson);
        expect(endpointsOf(batches.single), isEmpty);
      });

      test('WG-детур у vless учитывается в лимите: endpoint уезжает в тот же '
          'батч, что и узел', () {
        // 4 WG-узла уже набивают лимит; пятый «узел» — vless с WG-детуром,
        // и его endpoint не смеет подсесть к ним.
        final chained = FolderMember(raw: wg('inner')).node! as WireguardSpec;
        final plain = FolderMember(raw: uriA).node! as VlessSpec;
        final withWgDetour = VlessSpec(
          id: plain.id,
          tag: plain.tag,
          label: plain.label,
          server: plain.server,
          port: plain.port,
          rawSource: plain.rawSource,
          uuid: plain.uuid,
          transport: plain.transport,
          tls: plain.tls,
          chained: chained,
        );
        final batches = buildProbeBatches([
          for (var i = 1; i <= 4; i++) FolderMember(raw: wg('w$i')).node,
          withWgDetour,
        ]);
        expect(batches.length, 2, reason: 'детур-endpoint не влез в первый');
        expect(wgCountOf(batches.first), kProbeMaxWireguardPerConfig);
        // Узел и его WG-детур — в одном (втором) батче.
        expect(batches[1].tagByIndex.keys, [4]);
        expect(wgCountOf(batches[1]), 1);
        final types = ((jsonDecode(batches[1].configJson!) as Map)['outbounds']
                as List)
            .map((o) => (o as Map)['type'])
            .toSet();
        expect(types, contains('vless'));
      });

      test('узел с 5 WG-записями в своей цепочке неделим — один батч', () {
        // Цепочка WG→WG→…: записей больше лимита, но разорвать её гейт не
        // может (как naive-с-naive-детуром в §518).
        var node = FolderMember(raw: wg('c1')).node! as WireguardSpec;
        for (var i = 2; i <= 5; i++) {
          final outer = FolderMember(raw: wg('c$i')).node! as WireguardSpec;
          node = WireguardSpec(
            id: outer.id,
            tag: outer.tag,
            label: outer.label,
            server: outer.server,
            port: outer.port,
            rawSource: outer.rawSource,
            privateKey: outer.privateKey,
            localAddresses: outer.localAddresses,
            peers: outer.peers,
            mtu: outer.mtu,
            chained: node,
          );
        }
        final batches = buildProbeBatches([node]);
        expect(batches.length, 1);
        expect(wgCountOf(batches.single), 5);
        expect(batches.single.tagByIndex.keys, [0]);
      });
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

  // §546 — эмиттер значений не судит, поэтому probe-конфиг, как и боевая
  // сборка, проходит гард реестра: тело правится на месте, снятая запись
  // выводит узел из батча с вердиктом `invalid: …`.
  group('§546 гард реестра в probe-конфиге', () {
    const uuid = '11111111-2222-3333-4444-555555555555';
    const tls = TlsSpec(enabled: true, serverName: 'h.example');
    VlessSpec vless(
      String tag, {
      String server = 'h.example',
      String flow = '',
      TransportSpec? transport,
      NodeSpec? chained,
    }) =>
        VlessSpec(
          id: tag,
          tag: tag,
          label: tag,
          server: server,
          port: 443,
          rawSource: '',
          uuid: uuid,
          flow: flow,
          tls: tls,
          transport: transport,
          chained: chained,
        );
    Map<String, dynamic> outboundOf(ProbeConfig cfg, String tag) =>
        ((jsonDecode(cfg.configJson!) as Map)['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => o['tag'] == tag);

    test('модель с vision + ws → в probe-конфиге flow снят гардом', () {
      final node = vless('V',
          flow: 'xtls-rprx-vision', transport: const WsTransport(path: '/x'));
      // Эмиттер пишет модель как есть — судит реестр.
      expect(node.emit(TemplateVars.empty).map['flow'], 'xtls-rprx-vision');
      final cfg = buildProbeConfig([node]);
      final out = outboundOf(cfg, cfg.tagByIndex[0]!);
      expect(out.containsKey('flow'), isFalse);
      expect(out['transport'], {'type': 'ws', 'path': '/x'});
    });

    test('запись снята гардом → узел в brokenByIndex, прочие тестируются',
        () {
      final cfg = buildProbeConfig([vless('Bad', server: ''), vless('Good')]);
      expect(cfg.brokenByIndex[0], startsWith('invalid: '));
      expect(cfg.brokenByIndex[0], contains('field_missing'));
      expect(cfg.tagByIndex.containsKey(0), isFalse);
      expect(cfg.tagByIndex[1], 'Good');
      final tags = ((jsonDecode(cfg.configJson!) as Map)['outbounds'] as List)
          .map((o) => (o as Map)['tag'])
          .toList();
      expect(tags, isNot(contains('Bad')));
    });

    test('снят детур → узел не тестируется целиком', () {
      final cfg = buildProbeConfig([
        vless('Main', chained: vless('Hop', server: '')),
      ]);
      expect(cfg.configJson, isNull);
      expect(cfg.brokenByIndex[0], startsWith('invalid: Hop: '));
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

    // §518 — батчи naive прогоняются ПОСЛЕДОВАТЕЛЬНО, каждый своей сессией:
    // probeStop после каждого батча освобождает Chromium-движки до старта
    // следующего, иначе гейт не даёт ничего.
    test('§518: naive-батчи — probeStart/probeStop на каждый, все узлы меряны',
        () async {
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder(members: [
          FolderMember(raw: 'naive+https://u:p@n1.example:443#n1'),
          FolderMember(raw: uriA),
          FolderMember(raw: 'naive+https://u:p@n2.example:443#n2'),
          FolderMember(raw: 'naive+https://u:p@n3.example:443#n3'),
        ])),
        url: 'https://example.com/gen204',
        timeoutMs: 3000,
        onResult: (i, r) => results[i] = r,
      );
      expect(err, '');
      // Все четыре узла получили вердикт — ни один не потерян батчированием.
      expect(results.keys.toList()..sort(), [0, 1, 2, 3]);
      final starts = calls.where((c) => c.method == 'probeStart').length;
      final stops = calls.where((c) => c.method == 'probeStop').length;
      expect(starts, 3, reason: '3 naive при лимите 1 → 3 батча');
      expect(stops, starts, reason: 'сессия гасится после каждого батча');
      // urlTest — ровно по одному на узел.
      expect(calls.where((c) => c.method == 'probeUrlTest').length, 4);
    });

    // §523 — то же для WG/AWG: батчи по kProbeMaxWireguardPerConfig, сессия
    // гасится после каждого, чтобы пулы буферов предыдущего батча
    // (≈17.5 МБ на endpoint) освободились до старта следующего.
    test('§523: WG-батчи — probeStart/probeStop на каждый, все узлы меряны',
        () async {
      const priv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
      const pub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';
      String wg(String tag) => 'wireguard://$priv@$tag.example:51820'
          '?publickey=$pub&address=10.0.0.2/32&mtu=1420#$tag';
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder(members: [
          for (var i = 1; i <= 9; i++) FolderMember(raw: wg('w$i')),
          FolderMember(raw: uriA),
        ])),
        url: 'https://example.com/gen204',
        timeoutMs: 3000,
        onResult: (i, r) => results[i] = r,
      );
      expect(err, '');
      expect(results.keys.toList()..sort(), [for (var i = 0; i < 10; i++) i]);
      final starts = calls.where((c) => c.method == 'probeStart').length;
      final stops = calls.where((c) => c.method == 'probeStop').length;
      expect(starts, (9 / kProbeMaxWireguardPerConfig).ceil(),
          reason: '9 WG при лимите $kProbeMaxWireguardPerConfig');
      expect(stops, starts, reason: 'сессия гасится после каждого батча');
      expect(calls.where((c) => c.method == 'probeUrlTest').length, 10);
    });

    test('§336: группа получает вердикт group; папка из одних групп не '
        'поднимает сессию', () async {
      final results = <int, ProbeResult>{};
      final err = await ProbeRunner().run(
        nodesOf(folder(members: [
          _group('My auto'),
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
