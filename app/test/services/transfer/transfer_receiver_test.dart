// §622 — сервер приёма на реальном сокете loopback (фича 031, P1–P4, P9).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/transfer/transfer_code.dart';
import 'package:lxbox/services/transfer/transfer_envelope.dart';
import 'package:lxbox/services/transfer/transfer_receiver.dart';

const _backup =
    '{"app":"lxbox","kind":"backup","storage":{"storage_version":1}}';

Future<({int status, String body})> _post(int port, String body,
    {String path = '/transfer', String method = 'POST'}) async {
  final client = HttpClient();
  try {
    final req = await client.open(method, '127.0.0.1', port, path);
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

Future<bool> _portRefuses(int port) async {
  try {
    final s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 2));
    s.destroy();
    return false;
  } on SocketException {
    return true;
  }
}

void main() {
  late List<String> log;
  late TransferReceiver rx;

  Future<TransferReceiver> open({
    Duration ttl = const Duration(minutes: 1),
    int maxBody = TransferReceiver.maxBodyBytes,
    TransferParse? parse,
  }) async {
    rx = await TransferReceiver.open(
      bindAddress: InternetAddress.loopbackIPv4,
      ttl: ttl,
      maxBody: maxBody,
      parse: parse,
      log: log.add,
    );
    return rx;
  }

  setUp(() => log = []);
  tearDown(() => rx.close());

  test('valid envelope → 200, session closed, same parse as backup file (P3, P4)',
      () async {
    await open();
    final env = await sealTransferEnvelope(utf8.encode(_backup), rx.key);
    final r = await _post(rx.port, env);
    expect(r.status, 200);
    final end = await rx.done;
    expect(end, isA<TransferReceived>());
    final contents = (end as TransferReceived).contents;
    // Тот же разбор, что у файла: результат совпадает с parseImport.
    final direct = await const BackupService().parseImport(_backup);
    expect(contents.storage, direct.storage);
    expect(rx.isClosed, isTrue);
    expect(await _portRefuses(rx.port), isTrue);
  });

  test('wrong key → 403, parse not called; 5th rejection closes (P2, P3)',
      () async {
    var parsed = 0;
    await open(parse: (raw) async {
      parsed++;
      return BackupContents();
    });
    final foreign = await sealTransferEnvelope(
        utf8.encode(_backup), newTransferKey());
    for (var i = 1; i <= TransferReceiver.maxRejects; i++) {
      final r = await _post(rx.port, foreign);
      expect(r.status, 403, reason: 'attempt $i');
    }
    expect(await rx.done, isA<TransferRejectedTooOften>());
    expect(parsed, 0);
    expect(await _portRefuses(rx.port), isTrue);
  });

  test('corrupted ciphertext → 403', () async {
    await open();
    final m = jsonDecode(await sealTransferEnvelope(utf8.encode(_backup), rx.key))
        as Map<String, dynamic>;
    final ct = base64.decode(m['ct'] as String)..[0] ^= 1;
    m['ct'] = base64.encode(ct);
    expect((await _post(rx.port, jsonEncode(m))).status, 403);
    expect(rx.isClosed, isFalse);
  });

  test('5 garbage envelopes → 400 each, session closed (P3)', () async {
    var parsed = 0;
    await open(parse: (raw) async {
      parsed++;
      return BackupContents();
    });
    for (var i = 1; i <= TransferReceiver.maxRejects; i++) {
      expect((await _post(rx.port, 'garbage')).status, 400, reason: 'attempt $i');
    }
    expect(await rx.done, isA<TransferRejectedTooOften>());
    expect(parsed, 0);
    expect(await _portRefuses(rx.port), isTrue);
  });

  test('other routes → 404', () async {
    await open();
    expect((await _post(rx.port, '', path: '/')).status, 404);
    expect((await _post(rx.port, '', method: 'GET')).status, 404);
    expect((await _post(rx.port, '', path: '/debug')).status, 404);
  });

  test('body over the limit → 413', () async {
    await open(maxBody: 1024);
    final r = await _post(rx.port, 'x' * 2048);
    expect(r.status, 413);
    expect(rx.isClosed, isFalse);
  });

  test('decrypted but not a backup → 422 with reason, session stays open (P6)',
      () async {
    await open();
    final env = await sealTransferEnvelope(utf8.encode('{"app":"other"}'), rx.key);
    final r = await _post(rx.port, env);
    expect(r.status, 422);
    expect(r.body, contains('Not a LxBox backup'));
    expect(rx.problem.value, isA<TransferInvalidBackup>());
    expect(rx.isClosed, isFalse);
  });

  test('second request while the first is in processing → 503 busy (P3)',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var parsed = 0;
    await open(parse: (raw) async {
      parsed++;
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return BackupContents();
    });
    final env = await sealTransferEnvelope(utf8.encode(_backup), rx.key);
    final first = _post(rx.port, env);
    await entered.future;
    final second = await _post(rx.port, env);
    expect(second.status, 503);
    expect(second.body, 'busy');
    release.complete();
    expect((await first).status, 200);
    expect(parsed, 1);
    expect(await rx.done, isA<TransferReceived>());
  });

  test('busy slot is released after a rejected request', () async {
    await open();
    expect((await _post(rx.port, 'garbage')).status, 400);
    final env = await sealTransferEnvelope(utf8.encode(_backup), rx.key);
    expect((await _post(rx.port, env)).status, 200);
  });

  test('timeout closes the session and the port (P1)', () async {
    await open(ttl: const Duration(milliseconds: 50));
    final port = rx.port;
    expect(await rx.done, isA<TransferExpired>());
    expect(await _portRefuses(port), isTrue);
  });

  test('close() is idempotent and the port refuses afterwards (P1)', () async {
    await open();
    final port = rx.port;
    await rx.close();
    await rx.close();
    expect(await rx.done, isA<TransferCancelled>());
    expect(await _portRefuses(port), isTrue);
  });

  test('session log never contains the key or the code text (P9)', () async {
    await open();
    final code = rx.codeFor(['192.168.1.20'], 'TV');
    final foreign = await sealTransferEnvelope(
        utf8.encode(_backup), newTransferKey());
    await _post(rx.port, foreign);
    await _post(rx.port, 'garbage');
    final env = await sealTransferEnvelope(utf8.encode(_backup), rx.key);
    await _post(rx.port, env);
    await rx.done;
    expect(log, isNotEmpty);
    final k64url = encodeTransferKey(rx.key);
    final k64 = base64.encode(rx.key);
    for (final line in log) {
      expect(line.contains(k64url), isFalse, reason: line);
      expect(line.contains(k64), isFalse, reason: line);
      expect(line.contains(code.encode()), isFalse, reason: line);
    }
  });

  test('codeFor carries the session port and key', () async {
    await open();
    final code = rx.codeFor(['192.168.1.20', '10.0.0.2'], 'TV');
    expect(code.addresses.map((a) => a.port).toSet(), {rx.port});
    expect(TransferCode.tryParse(code.encode())!.key, rx.key);
  });

  group('pickTransferAddresses', () {
    test('drops loopback, link-local and tunnels; Wi-Fi/Ethernet first', () {
      final picked = pickTransferAddresses([
        (interface: 'rmnet0', address: '100.64.1.2'),
        (interface: 'tun0', address: '172.19.0.1'),
        (interface: 'lo', address: '127.0.0.1'),
        (interface: 'wlan0', address: '192.168.1.20'),
        (interface: 'eth0', address: '10.0.0.5'),
        (interface: 'wlan0', address: '169.254.3.3'),
        (interface: 'wg0', address: '10.8.0.2'),
      ]);
      expect(picked, ['192.168.1.20', '10.0.0.5', '100.64.1.2']);
    });

    test('empty when only tunnels', () {
      expect(
          pickTransferAddresses(
              [(interface: 'tun0', address: '172.19.0.1')]),
          isEmpty);
    });
  });
}
