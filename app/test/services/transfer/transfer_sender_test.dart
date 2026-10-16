// §622 — отправка на TV: исходы ответов и сети (фича 031, P6, P7 фолбэк).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/transfer/transfer_code.dart';
import 'package:lxbox/services/transfer/transfer_envelope.dart';
import 'package:lxbox/services/transfer/transfer_receiver.dart';
import 'package:lxbox/services/transfer/transfer_sender.dart';

const _backup =
    '{"app":"lxbox","kind":"backup","storage":{"storage_version":1}}';

Future<LanPostOutcome> _noNative(TransferEndpoint ep, Uint8List body) async =>
    const LanPostNoNetwork();

TransferCode _code(List<TransferEndpoint> eps, [List<int>? key]) =>
    TransferCode(addresses: eps, key: key ?? newTransferKey(), name: 'TV');

void main() {
  group('transferResultForResponse', () {
    test('each answer has its own status', () {
      expect(transferResultForResponse(200, 'ok').status,
          TransferSendStatus.sent);
      expect(transferResultForResponse(403, '').status,
          TransferSendStatus.rejected);
      expect(transferResultForResponse(409, '').status,
          TransferSendStatus.expired);
      expect(transferResultForResponse(413, '').status,
          TransferSendStatus.tooLarge);
      final invalid = transferResultForResponse(422, ' Not a LxBox backup ');
      expect(invalid.status, TransferSendStatus.invalid);
      expect(invalid.detail, 'Not a LxBox backup');
      expect(transferResultForResponse(503, 'busy').status,
          TransferSendStatus.busy);
      final other = transferResultForResponse(500, '');
      expect(other.status, TransferSendStatus.failed);
      expect(other.httpStatus, 500);
    });
  });

  group('TransferSender', () {
    test('no non-VPN network → Dart client delivers to a live receiver',
        () async {
      final rx = await TransferReceiver.open(
          bindAddress: InternetAddress.loopbackIPv4, log: (_) {});
      addTearDown(rx.close);
      final code = _code([TransferEndpoint('127.0.0.1', rx.port)], rx.key);
      final env = await sealTransferEnvelope(utf8.encode(_backup), code.key);
      final r = await TransferSender(nativePost: _noNative).send(code, env);
      expect(r.status, TransferSendStatus.sent);
      expect(await rx.done, isA<TransferReceived>());
    });

    test('closed receiver port → expired', () async {
      final rx = await TransferReceiver.open(
          bindAddress: InternetAddress.loopbackIPv4, log: (_) {});
      final port = rx.port;
      await rx.close();
      final code = _code([TransferEndpoint('127.0.0.1', port)]);
      final r = await TransferSender(nativePost: _noNative).send(code, '{}');
      expect(r.status, TransferSendStatus.expired);
    });

    test('wrong key → rejected', () async {
      final rx = await TransferReceiver.open(
          bindAddress: InternetAddress.loopbackIPv4,
          log: (_) {},
          parse: (_) async => BackupContents());
      addTearDown(rx.close);
      final code = _code([TransferEndpoint('127.0.0.1', rx.port)]);
      final env = await sealTransferEnvelope(utf8.encode(_backup), code.key);
      final r = await TransferSender(nativePost: _noNative).send(code, env);
      expect(r.status, TransferSendStatus.rejected);
    });

    test('native answer wins, Dart client not used', () async {
      var dartCalls = 0;
      final sender = TransferSender(
        nativePost: (ep, body) async => const LanPostResponse(200, 'ok'),
        dartPost: (ep, body) async {
          dartCalls++;
          return const LanPostNoNetwork();
        },
      );
      final r = await sender
          .send(_code([const TransferEndpoint('192.168.1.2', 1000)]), '{}');
      expect(r.status, TransferSendStatus.sent);
      expect(dartCalls, 0);
    });

    test('addresses tried in order until one answers', () async {
      final tried = <String>[];
      final sender = TransferSender(nativePost: (ep, body) async {
        tried.add(ep.host);
        return ep.host == '10.0.0.5'
            ? const LanPostResponse(200, 'ok')
            : const LanPostUnreachable('timeout');
      });
      final r = await sender.send(
          _code(const [
            TransferEndpoint('192.168.1.2', 1000),
            TransferEndpoint('10.0.0.5', 1000),
            TransferEndpoint('10.0.0.6', 1000),
          ]),
          '{}');
      expect(r.status, TransferSendStatus.sent);
      expect(tried, ['192.168.1.2', '10.0.0.5']);
    });

    test('nobody answers → unreachable', () async {
      final sender = TransferSender(
          nativePost: (ep, body) async => const LanPostUnreachable('timeout'));
      final r = await sender
          .send(_code([const TransferEndpoint('192.168.1.2', 1000)]), '{}');
      expect(r.status, TransferSendStatus.unreachable);
    });
  });
}
