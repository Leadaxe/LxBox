import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/tunnel_status.dart';
import 'package:lxbox/services/l10n/l10n.dart';

/// §276 — контракт статуса native↔Dart.
///
/// Регресс-якорь: Dart раньше ждал статус-строку `'Revoked'`, которую native не
/// слал никогда (`VpnStatus` = Stopped/Starting/Started/Stopping), из-за чего
/// `TunnelStatus.revoked` был недостижим, а весь revoke-UX — мёртвым кодом.
/// Revoke едет как `Stopped` + флаг `revoked`, потому что терминальный статус
/// обязан остаться `Stopped` (на нём висит teardown в native).
void main() {
  group('TunnelStatus.fromNative', () {
    test('маппит статусы, которые реально шлёт native', () {
      expect(TunnelStatus.fromNative('Started'), TunnelStatus.connected);
      expect(TunnelStatus.fromNative('Starting'), TunnelStatus.connecting);
      expect(TunnelStatus.fromNative('Stopped'), TunnelStatus.disconnected);
      expect(TunnelStatus.fromNative('Stopping'), TunnelStatus.stopping);
    });

    test('Stopped + revoked → revoked (перехват слота чужим VPN)', () {
      expect(
        TunnelStatus.fromNative('Stopped', revoked: true),
        TunnelStatus.revoked,
      );
    });

    test('Stopped без флага → disconnected (штатный стоп)', () {
      expect(
        TunnelStatus.fromNative('Stopped', revoked: false),
        TunnelStatus.disconnected,
      );
    });

    test('неизвестный raw → unknown', () {
      expect(TunnelStatus.fromNative('Nonsense'), TunnelStatus.unknown);
      // 'Revoked' статус-строкой native не шлёт — не должна распознаваться.
      expect(TunnelStatus.fromNative('Revoked'), TunnelStatus.unknown);
    });
  });

  group('TunnelStatusEvent.fromNative', () {
    test('revoke-событие: статус revoked + причина от native', () {
      final event = TunnelStatusEvent.fromNative(<dynamic, dynamic>{
        'status': 'Stopped',
        'error': 'Another VPN app took the system VPN slot '
            '(e.g. an always-on VPN). Start again to reconnect.',
        'revoked': true,
      });

      expect(event.status, TunnelStatus.revoked);
      expect(event.raw, 'Stopped');
      expect(event.errorReason, contains('took the system VPN slot'));
    });

    test('штатный стоп с ошибкой ядра НЕ становится revoked', () {
      final event = TunnelStatusEvent.fromNative(<dynamic, dynamic>{
        'status': 'Stopped',
        'error': 'start service: bind: address already in use',
      });

      expect(event.status, TunnelStatus.disconnected);
      expect(event.errorReason, contains('address already in use'));
    });

    test('обычный стоп без extras → disconnected без причины', () {
      final event = TunnelStatusEvent.fromNative(
        <dynamic, dynamic>{'status': 'Stopped'},
      );

      expect(event.status, TunnelStatus.disconnected);
      expect(event.errorReason, isNull);
    });

    test('revoked: false трактуется как отсутствие флага', () {
      final event = TunnelStatusEvent.fromNative(
        <dynamic, dynamic>{'status': 'Stopped', 'revoked': false},
      );

      expect(event.status, TunnelStatus.disconnected);
    });
  });

  group('label', () {
    test('revoked назван по-человечески (не «Disconnected»)', () {
      expect(TunnelStatus.revoked.label(L10n.en), 'Taken by another VPN');
    });
  });
}
