import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/taildrop.dart';
import 'package:lxbox/services/debug/transport/middleware/timeout.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §707 итер. 5 — `/taildrop/*` на фейке нативных действий: маршрут зовёт
/// то же действие, что вкладка Network / «Send file…», с нужными
/// аргументами, имена без `reveal` не отдаёт, отказы — общим форматом.
void main() {
  late _FakeActions fake;

  setUp(() {
    fake = _FakeActions();
    TaildropDebugActions.instance = fake;
  });
  tearDown(() => TaildropDebugActions.instance = const TaildropDebugActions());

  final now = DateTime.utc(2026, 11, 2, 14, 30, 5);
  DebugContext ctx() => DebugContext(
      registry: DebugRegistry.I, appStartedAt: now, clock: () => now);

  DebugRequest req(String method, String pathAndQuery, [Object? body]) =>
      DebugRequest(
        method: method,
        uri: Uri.parse('http://127.0.0.1:9269$pathAndQuery'),
        headers: const {},
        body: body == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(body))),
        receivedAt: now,
      );

  Future<Map<String, dynamic>> call(String method, String path,
      [Object? body]) async {
    final r = await taildropHandler(req(method, path, body), ctx());
    return ((r as JsonResponse).body as Map).cast<String, dynamic>();
  }

  Future<int> status(String method, String path, [Object? body]) async {
    final r = await taildropHandler(req(method, path, body), ctx());
    return (r as JsonResponse).status;
  }

  test('GET /taildrop: Tailscale nodes of the config, core fields from status',
      () async {
    final b = await call('GET', '/taildrop');
    final nodes = (b['nodes'] as List).cast<Map>();
    expect([for (final n in nodes) n['tag']], ['ts-a', 'ts-b']);
    final a = nodes.first;
    expect(a['allow'], false);
    expect(a['disable_taildrop'], true);
    final bNode = nodes.last;
    expect(bNode['allow'], true);
    expect(bNode['disable_taildrop'], isNull);
    expect(bNode['can_share_files'], true);
    expect(bNode['self_id'], 'nSELF');
    expect(bNode['autosave'], true);
    expect(bNode['inbox_files'], 2);
    expect(bNode['receiving'], 1);
    expect(b['clip_target'], {'tag': 'ts-b', 'peer_id': 'nPEER1'});
    expect(b['clip_feeds'], [
      {'tag': 'ts-b', 'peer_id': 'nPEER1', 'messages': 3},
    ]);
    expect(jsonEncode(b), isNot(contains('laptop')));
    final r = await call('GET', '/taildrop?reveal=true');
    expect((r['clip_target'] as Map)['name'], 'laptop');
  });

  test('GET /taildrop with VPN off lists nodes without core fields', () async {
    fake.up = false;
    final b = await call('GET', '/taildrop');
    expect(b['tunnel_up'], false);
    final n = (b['nodes'] as List).cast<Map>().last;
    expect(n['allow'], true);
    expect(n['can_share_files'], isNull);
    expect(n['inbox_files'], isNull);
    expect(fake.statusCalls, 0);
  });

  test('GET /taildrop/peers hides names unless reveal; permissions per peer',
      () async {
    final b = await call('GET', '/taildrop/peers?tag=ts-b');
    final peers = (b['peers'] as List).cast<Map>();
    expect(peers.first['id'], 'nPEER1');
    expect(peers.first.containsKey('name'), false);
    expect(peers.first['permissions'], {'clipboard': true, 'open_url': false});
    expect(jsonEncode(b), isNot(contains('laptop')));

    final r = await call('GET', '/taildrop/peers?tag=ts-b&reveal=true');
    expect((r['peers'] as List).cast<Map>().first['name'], 'laptop');
  });

  test('tag without or with another source prefix finds the node', () async {
    final r = await call(
        'GET', '/taildrop/peers?tag=${Uri.encodeQueryComponent('🕸️ ts-b')}');
    expect(r['tag'], 'ts-b');
  });

  test('refusals: unknown node 404, VPN off 409, no tag 400', () async {
    expect(() => call('GET', '/taildrop/peers?tag=nope'),
        throwsA(isA<NotFound>()));
    expect(() => call('GET', '/taildrop/peers'), throwsA(isA<BadRequest>()));
    fake.up = false;
    expect(() => call('GET', '/taildrop/inbox?tag=ts-b'),
        throwsA(isA<Conflict>()));
  });

  test('GET /taildrop/inbox: sorted by time, index, sha256, age, no names',
      () async {
    final b = await call('GET', '/taildrop/inbox?tag=ts-b');
    final files = (b['files'] as List).cast<Map>();
    expect([for (final f in files) f['index']], [0, 1]);
    expect(files.first['sha256'], 'aa');
    expect(files.first['age_s'], 50);
    expect(files.first['sender_id'], 'nPEER1');
    expect(jsonEncode(b), isNot(contains('old.txt')));
    final rec = (b['receiving'] as List).cast<Map>().single;
    expect(rec['progress'], 0.5);

    final r = await call('GET', '/taildrop/inbox?tag=ts-b&reveal=true');
    expect((r['files'] as List).cast<Map>().first['name'], 'old.txt');
  });

  test('POST /taildrop/send content_base64 goes to the native send path',
      () async {
    final data = utf8.encode('hello');
    final b = await call('POST', '/taildrop/send', {
      'tag': 'ts-b',
      'peer': 'laptop',
      'name': 'a.txt',
      'content_base64': base64Encode(data),
    });
    expect(b['status'], 'sent');
    expect(b['sha256'], sha256.convert(data).toString());
    expect(b.containsKey('name'), false);
    final s = fake.sent.single;
    expect((s.$1, s.$2, s.$3, s.$4, s.$6),
        ('ts-b', 'nPEER1', 'laptop', 'a.txt', null));
    expect(s.$5, data);
  });

  test('POST /taildrop/send: note, in_progress → 202, core error → 409',
      () async {
    fake.sendResult = const CcTaildropResult(status: 'in_progress');
    expect(
        await status('POST', '/taildrop/send',
            {'tag': 'ts-b', 'peer': 'nPEER1', 'text': 'hi'}),
        202);
    expect(fake.sent.single.$6, 'hi');

    fake.sendResult = const CcTaildropResult(
        status: 'error', error: 'Taildrop is disabled on this node');
    await expectLater(
        call('POST', '/taildrop/send',
            {'tag': 'ts-b', 'peer': 'nPEER1', 'text': 'hi'}),
        throwsA(isA<Conflict>().having(
            (e) => e.message, 'message', contains('disabled'))));

    await expectLater(
        call('POST', '/taildrop/send',
            {'tag': 'ts-b', 'peer': 'nPEER1', 'text': 'x', 'commands': []}),
        throwsA(isA<BadRequest>()));
    await expectLater(
        call('POST', '/taildrop/send',
            {'tag': 'ts-b', 'peer': 'nobody', 'text': 'x'}),
        throwsA(isA<NotFound>()));
  });

  test('POST /taildrop/send commands: the native builder makes the file',
      () async {
    final b = await call('POST', '/taildrop/send', {
      'tag': 'ts-b',
      'peer': 'nPEER1',
      'commands': [
        {'kind': 'clipboard', 'text': 'copied'},
      ],
    });
    expect(fake.built.single, [
      {'kind': 'clipboard', 'text': 'copied'},
    ]);
    final s = fake.sent.single;
    expect(s.$4, 'lx-20261102T143005Z-k3x9p.json');
    expect(s.$5, fake.builtBytes);
    expect(b['sha256'], sha256.convert(fake.builtBytes).toString());
  });

  test('POST /taildrop/send commands over max_bytes: 400, nothing sent',
      () async {
    fake.buildResult = const CcServiceFile(
        error: 'too_large', size: 70100, maxBytes: 65536);
    await expectLater(
        call('POST', '/taildrop/send', {
          'tag': 'ts-b',
          'peer': 'nPEER1',
          'commands': [
            {'kind': 'clipboard', 'text': 'x'},
          ],
        }),
        throwsA(isA<BadRequest>()
            .having((e) => e.message, 'message', contains('65536'))));
    expect(fake.sent, isEmpty);
  });

  test('inbox save / delete / cancel pick the file by index', () async {
    final s = await call(
        'POST', '/taildrop/inbox/save?reveal=true', {'tag': 'ts-b', 'index': 1});
    expect(fake.saved.single, ('ts-b', 'new.bin'));
    expect(s['name'], 'new (1).bin');

    await call('POST', '/taildrop/inbox/delete', {'tag': 'ts-b', 'index': 0});
    expect(fake.deleted.single, ('ts-b', 'old.txt'));

    await call('POST', '/taildrop/inbox/cancel', {'tag': 'ts-b', 'index': 0});
    expect(fake.cancelled.single, ('ts-b', 'nPEER1', 'big.iso'));

    await expectLater(
        call('POST', '/taildrop/inbox/delete', {'tag': 'ts-b', 'index': 5}),
        throwsA(isA<NotFound>()));
  });

  test('PUT /taildrop/settings: autosave and allow', () async {
    final b = await call('PUT', '/taildrop/settings',
        {'tag': 'ts-a', 'autosave': true, 'allow': true});
    expect(b['autosave'], true);
    expect(b['allow'], true);
    expect(fake.autoSaveWrites.single, ('ts-a', true));
    expect(fake.allowWrites.single, ('ts-a', true));

    fake.autoSaveSupported = false;
    await expectLater(
        call('PUT', '/taildrop/settings', {'tag': 'ts-a', 'autosave': true}),
        throwsA(isA<Conflict>()));
    await expectLater(call('PUT', '/taildrop/settings', {'tag': 'ts-a'}),
        throwsA(isA<BadRequest>()));
  });

  test('PUT /taildrop/permissions: kind from the registry, peer by name',
      () async {
    await call('PUT', '/taildrop/permissions',
        {'tag': 'ts-b', 'peer': 'laptop', 'kind': 'open_url', 'enabled': true});
    expect(fake.permWrites.single,
        ('ts-b', 'nPEER1', 'laptop', 'open_url', true));
    await expectLater(
        call('PUT', '/taildrop/permissions',
            {'tag': 'ts-b', 'peer': 'laptop', 'kind': 'shell', 'enabled': true}),
        throwsA(isA<BadRequest>()));
  });

  test('GET /taildrop/service-files: last value only with reveal', () async {
    final b = await call('GET', '/taildrop/service-files');
    expect(b['received'], 3);
    final last = (b['last'] as Map).cast<String, dynamic>();
    expect(last['kind'], 'clipboard');
    expect(last['sha256'], sha256.convert(utf8.encode('secret')).toString());
    expect(last.containsKey('value'), false);
    expect(jsonEncode(b), isNot(contains('secret')));

    final r = await call('GET', '/taildrop/service-files?reveal=true');
    expect((r['last'] as Map)['value'], 'secret');
  });

  test('unknown path 404, wrong method 400', () async {
    expect(() => call('GET', '/taildrop/nope'), throwsA(isA<NotFound>()));
    expect(() => call('GET', '/taildrop/send'), throwsA(isA<BadRequest>()));
  });

  test('timeout middleware: per-path limit overrides the default', () async {
    final mw = timeoutMiddleware(const Duration(milliseconds: 10),
        perPath: {'/taildrop/send': const Duration(seconds: 5)});
    final done = Completer<void>();
    Future<DebugResponse> slow() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      done.complete();
      return const JsonResponse({});
    }

    await mw(req('POST', '/taildrop/send'), ctx(), slow);
    expect(done.isCompleted, true);
    await expectLater(mw(req('GET', '/taildrop'), ctx(), slow),
        throwsA(isA<RequestTimeout>()));
  });
}

class _FakeActions extends TaildropDebugActions {
  bool up = true;
  bool autoSaveSupported = true;
  int statusCalls = 0;
  CcTaildropResult sendResult = const CcTaildropResult(status: 'sent');

  final sent = <(String, String, String, String?, Uint8List?, String?)>[];
  final built = <List<Object?>>[];
  final builtBytes = Uint8List.fromList(
      utf8.encode('{"lx":1,"commands":[{"kind":"clipboard"}]}'));
  CcServiceFile? buildResult;
  final saved = <(String, String)>[];
  final deleted = <(String, String)>[];
  final cancelled = <(String, String, String)>[];
  final autoSaveWrites = <(String, bool)>[];
  final allowWrites = <(String, bool)>[];
  final permWrites = <(String, String, String, String, bool)>[];

  static const _peer = CcTailscalePeer(
      stableId: 'nPEER1',
      hostName: 'laptop',
      os: 'linux',
      online: true,
      canReceiveFiles: true);

  @override
  bool tunnelUp(DebugContext ctx) => up;

  @override
  String configJson(DebugContext ctx) => jsonEncode({
        'endpoints': [
          {'type': 'tailscale', 'tag': 'ts-a', 'disable_taildrop': true},
          {'type': 'tailscale', 'tag': 'ts-b'},
          {'type': 'wireguard', 'tag': 'wg'},
        ],
      });

  @override
  Map<String, dynamic>? nodeBody(DebugContext ctx, String tag) =>
      tag == 'ts-b' ? {'disable_taildrop': false} : {};

  @override
  Future<String?> setAllow(DebugContext ctx, String tag, bool allow) async {
    allowWrites.add((tag, allow));
    return null;
  }

  @override
  Future<CcTailscaleStatus?> status(String tag) async {
    statusCalls++;
    return const CcTailscaleStatus(
      tag: 'ts-b',
      backendState: 'Running',
      stateText: '',
      self: CcTailscalePeer(stableId: 'nSELF', hostName: 'me'),
      userGroups: [
        CcTailscaleUserGroup(peers: [_peer]),
      ],
    );
  }

  @override
  Future<CcTaildropAutoSave?> autoSave(String tag) async =>
      CcTaildropAutoSave(enabled: tag == 'ts-b', supported: autoSaveSupported);

  @override
  Future<bool> setAutoSave(String tag, bool enabled) async {
    autoSaveWrites.add((tag, enabled));
    return true;
  }

  @override
  Future<CcTaildropInbox?> inbox(String tag) async => const CcTaildropInbox(
        tag: 'ts-b',
        files: [
          CcTaildropFile(name: 'new.bin', size: 8, modifiedAt: 1793629800),
          CcTaildropFile(
              name: 'old.txt',
              size: 3,
              senderId: 'nPEER1',
              senderName: 'laptop',
              modifiedAt: 1793629755,
              sha256: 'aa'),
        ],
        receiving: [
          CcTaildropReceiving(
              name: 'big.iso',
              size: 100,
              receivedBytes: 50,
              senderId: 'nPEER1',
              senderName: 'laptop'),
        ],
      );

  @override
  Future<CcTaildropResult> save(String tag, String name) async {
    saved.add((tag, name));
    return const CcTaildropResult(
        status: 'saved', where: 'downloads', name: 'new (1).bin');
  }

  @override
  Future<String?> delete(String tag, String name) async {
    deleted.add((tag, name));
    return null;
  }

  @override
  Future<String?> cancelReceiving(
      String tag, String senderId, String name) async {
    cancelled.add((tag, senderId, name));
    return null;
  }

  @override
  Future<Map<String, bool>?> permissions(String tag, String peerId) async =>
      {'clipboard': true, 'open_url': false};

  @override
  Future<bool> setPermission(String tag, String peerId, String peerName,
      String kind, bool allowed) async {
    permWrites.add((tag, peerId, peerName, kind, allowed));
    return true;
  }

  @override
  Future<CcTaildropResult> send(String tag, String peerId, String peerName,
      {String? name, Uint8List? bytes, String? text}) async {
    sent.add((tag, peerId, peerName, name, bytes, text));
    return sendResult;
  }

  @override
  Future<CcServiceFile?> buildServiceFile(List<Object?> commands) async {
    built.add(commands);
    return buildResult ??
        CcServiceFile(
            name: 'lx-20261102T143005Z-k3x9p.json', bytes: builtBytes);
  }

  @override
  Future<Map<String, dynamic>?> clipState() async => {
        'target': {'tag': 'ts-b', 'peer_id': 'nPEER1', 'name': 'laptop'},
        'feeds': [
          {'tag': 'ts-b', 'peer_id': 'nPEER1', 'messages': 3},
        ],
      };

  @override
  Future<Map<String, dynamic>?> serviceStats() async => {
        'received': 3,
        'executed': {'clipboard': 1, 'open_url': 0},
        'last': {'kind': 'clipboard', 'at_ms': 1793629800000, 'value': 'secret'},
      };

  @override
  Future<Map<String, dynamic>> serviceFilesRegistry() async {
    final raw =
        File('assets/contract/registry/service_files.json').readAsStringSync();
    return ((jsonDecode(raw) as Map)['service_files'] as Map)
        .cast<String, dynamic>();
  }
}
