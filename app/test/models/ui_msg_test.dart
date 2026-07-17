import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/stop_reason.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/l10n/l10n.dart';

// §279 Phase 4 — sealed UiMsg: равенство по данным, рендер по локали,
// стабильность renderEn() (machine-поверхности не зависят от активной локали).
void main() {
  final ru = lookupAppLocalizations(const Locale('ru'));

  group('UiMsg equality (по данным, не по строке)', () {
    test('одинаковые данные == равны, hashCode совпадает', () {
      expect(const RawMsg('boom'), const RawMsg('boom'));
      expect(const RawMsg('boom').hashCode, const RawMsg('boom').hashCode);
      expect(const TimeoutError(5800), const TimeoutError(5800));
      expect(const ErrMsg(ErrKey.failedToStartVpn),
          const ErrMsg(ErrKey.failedToStartVpn));
      expect(
        const PrefixedMsg(ErrPrefix.reloadFailed, RawMsg('x')),
        const PrefixedMsg(ErrPrefix.reloadFailed, RawMsg('x')),
      );
      expect(const SubStatusNodes(3, detours: 1, cached: true),
          const SubStatusNodes(3, detours: 1, cached: true));
      expect(const HttpStatusMsg(404), const HttpStatusMsg(404));
    });

    test('разные данные / разные типы != равны', () {
      expect(const RawMsg('a') == const RawMsg('b'), isFalse);
      expect(const TimeoutError(1000) == const TimeoutError(2000), isFalse);
      expect(
          const ErrMsg(ErrKey.failedToStartVpn) ==
              const ErrMsg(ErrKey.stopTimedOut),
          isFalse);
      expect(
          const PrefixedMsg(ErrPrefix.reloadFailed, RawMsg('x')) ==
              const PrefixedMsg(ErrPrefix.switchFailed, RawMsg('x')),
          isFalse);
      // Разные типы с одинаковым рендером недопустимо считать равными.
      expect(
          // ignore: unrelated_type_equality_checks
          const RawMsg('Failed to start VPN') ==
              const ErrMsg(ErrKey.failedToStartVpn),
          isFalse);
    });
  });

  group('render(l) — обе локали', () {
    test('ErrMsg рендерится в обеих локалях, en = прежняя строка verbatim',
        () {
      const m = ErrMsg(ErrKey.failedToStartVpn);
      expect(m.render(L10n.en), 'Failed to start VPN');
      expect(m.render(ru), isNotEmpty);
      expect(m.render(ru), isNot(m.render(L10n.en)));
    });

    test('PrefixedMsg: payload проходит verbatim в обеих локалях', () {
      const m = PrefixedMsg(ErrPrefix.fileError, RawMsg('ENOENT'));
      expect(m.render(L10n.en), 'File error: ENOENT');
      expect(m.render(ru), contains('ENOENT'));
    });

    test('TimeoutError: формат секунд одинаковый, слово локализуется', () {
      const m = TimeoutError(5800);
      expect(m.render(L10n.en), 'timeout 5.8s');
      expect(m.render(ru), contains('5.8s'));
    });

    test('ErrMsg(tunnelNotResponding): heartbeat-стоп — типизированный UiMsg',
        () {
      // Регрессия: heartbeat._onTunnelDead писал сырой String в
      // copyWith(lastError:) (Object?-параметр) → runtime cast error.
      const m = ErrMsg(ErrKey.tunnelNotResponding);
      expect(m.render(L10n.en), 'Connection lost — VPN tunnel is not responding');
      expect(m.render(ru), isNot(m.render(L10n.en)));
      expect(m.render(ru), isNotEmpty);
    });

    test('SubStatusNodes: cached-фрейм в обеих локалях', () {
      const m = SubStatusNodes(2, cached: true);
      expect(m.render(L10n.en), '2 nodes (cached)');
      expect(m.render(ru), contains('2'));
      expect(m.render(ru), isNot(m.render(L10n.en)));
    });

    test('ValidationFatalMsg: полный перечень issues в обеих локалях', () {
      const m = ValidationFatalMsg([
        DanglingOutboundRef('rules[0]', 'ghost'),
        EmptyUrltestGroup('auto'),
      ]);
      expect(m.render(L10n.en),
          'Config invalid (2 issues): Rule "rules[0]" references missing '
          'outbound "ghost".; URL-test group "auto" has no outbounds.');
      expect(m.render(ru), contains('ghost'));
      expect(m.render(ru), contains('auto'));
    });

    test('ProbeErrorMsg: wire-части не переводятся', () {
      const m = ProbeErrorMsg('vpn-1', 'ya.ru', ErrMsg(ErrKey.noConnection));
      expect(m.render(L10n.en),
          'vpn-1 → ya.ru — No connection — check network or URL');
      expect(m.render(ru), startsWith('vpn-1 → ya.ru — '));
    });

    test('NodeWarning: рендер под обеими локалями, интерполяции verbatim', () {
      const w = UnsupportedTransportWarning('xhttp', 'httpupgrade');
      expect(
        w.message(L10n.en),
        'Transport "xhttp" is not supported by sing-box; using "httpupgrade" '
        'fallback (node may fail to connect).',
      );
      final rendered = w.message(ru);
      expect(rendered, contains('xhttp'));
      expect(rendered, contains('httpupgrade'));
      expect(rendered, isNot(w.message(L10n.en)));
    });

    test('StopReason: рендер под обеими локалями', () {
      const r = StopRevoked();
      expect(r.message(L10n.en), contains('Another VPN app'));
      expect(r.message(ru), isNot(r.message(L10n.en)));
      const e = StopError('create service: bind failed');
      expect(e.message(L10n.en), 'Stopped: create service: bind failed');
      expect(e.message(ru), contains('create service: bind failed'));
    });
  });

  group('renderEn() — стабильность при смене локали', () {
    test('переключение L10n.current не меняет renderEn-вывод', () {
      const msgs = <UiMsg>[
        ErrMsg(ErrKey.connectionTimedOut),
        PrefixedMsg(ErrPrefix.switchFailed, RawMsg('boom')),
        TimeoutError(10000),
        SubStatusFetching(),
        HttpStatusMsg(503),
        StopReasonMsg(StopRevoked()),
      ];
      final before = [for (final m in msgs) m.renderEn()];
      final saved = L10n.current;
      L10n.current = ru;
      try {
        final after = [for (final m in msgs) m.renderEn()];
        expect(after, before);
        // NodeWarning/ValidationIssue/StopReason En-мосты — та же гарантия.
        expect(const InsecureTlsWarning().renderEn(),
            'TLS certificate verification is disabled.');
        expect(const EmptyUrltestGroup('auto').renderEn(),
            'URL-test group "auto" has no outbounds.');
        expect(const StopError('x').renderEn(), 'Stopped: x');
      } finally {
        L10n.current = saved;
      }
    });
  });

  group('ValidationIssue equality (по данным — Phase-4 фикс)', () {
    test('одинаковые данные == равны', () {
      expect(const DanglingOutboundRef('r', 't'),
          const DanglingOutboundRef('r', 't'));
      expect(const DetourCycle(['a', 'b'], culprits: [(tag: 'a', detour: 'b')]),
          const DetourCycle(['a', 'b'], culprits: [(tag: 'a', detour: 'b')]));
    });

    test('разные данные != равны', () {
      expect(
          const DanglingOutboundRef('r', 't') ==
              const DanglingOutboundRef('r', 'x'),
          isFalse);
      expect(
          const DetourCycle(['a', 'b']) == const DetourCycle(['a', 'c']),
          isFalse);
      expect(
          // ignore: unrelated_type_equality_checks
          const EmptyUrltestGroup('t') == const InvalidDefault('t', 't'),
          isFalse);
    });
  });
}
