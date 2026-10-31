import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/stop_reason.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';

// §285 — sealed UiMsg: равенство по данным, рендер по локали (через
// GetLocalText, не ARB), стабильность renderEn() (machine-поверхности не
// зависят от активной локали). `_ru` — реальный словарь assets/l10n/ru/ui.json.
GetLocalText _loadRu() {
  final raw = File('assets/l10n/ru/ui.json').readAsStringSync();
  final dict = jsonDecode(raw) as Map<String, dynamic>;
  return GetLocalText(dict, const RuPluralResolver());
}

void main() {
  final ru = _loadRu();

  group('render — обе локали', () {
    test('ErrMsg: en verbatim (renderEn), ru отличается', () {
      const m = ErrMsg(ErrKey.failedToStartVpn);
      expect(m.renderEn(), 'Failed to start VPN');
      expect(m.renderWith(ru), isNotEmpty);
      expect(m.renderWith(ru), isNot(m.renderEn()));
    });

    test('PrefixedMsg: payload проходит verbatim в обеих локалях', () {
      const m = PrefixedMsg(ErrPrefix.fileError, RawMsg('ENOENT'));
      expect(m.renderEn(), 'File error: ENOENT');
      expect(m.renderWith(ru), contains('ENOENT'));
    });

    test('TimeoutError: формат секунд одинаковый, слово локализуется', () {
      const m = TimeoutError(5800);
      expect(m.renderEn(), 'timeout 5.8s');
      expect(m.renderWith(ru), contains('5.8s'));
    });

    test('ErrMsg(tunnelNotResponding): heartbeat-стоп — типизированный UiMsg',
        () {
      // Регрессия: heartbeat._onTunnelDead писал сырой String в
      // copyWith(lastError:) (Object?-параметр) → runtime cast error.
      const m = ErrMsg(ErrKey.tunnelNotResponding);
      expect(m.renderEn(), 'Connection lost — VPN tunnel is not responding');
      expect(m.renderWith(ru), isNot(m.renderEn()));
      expect(m.renderWith(ru), isNotEmpty);
    });

    test('SubStatusNodes: cached-фрейм в обеих локалях', () {
      const m = SubStatusNodes(2, cached: true);
      expect(m.renderEn(), '2 nodes (cached)');
      expect(m.renderWith(ru), contains('2'));
      expect(m.renderWith(ru), isNot(m.renderEn()));
    });

    test('ValidationFatalMsg: полный перечень issues (en verbatim)', () {
      const m = ValidationFatalMsg([
        DanglingOutboundRef('rules[0]', 'ghost'),
        EmptyUrltestGroup('auto'),
      ]);
      expect(m.renderEn(),
          'Config invalid (2 issues): Rule "rules[0]" references missing '
          'outbound "ghost".; URL-test group "auto" has no outbounds.');
      expect(m.renderWith(ru), contains('ghost'));
      expect(m.renderWith(ru), contains('auto'));
    });

    test('ProbeErrorMsg: wire-части не переводятся', () {
      const m = ProbeErrorMsg('vpn-1', 'ya.ru', ErrMsg(ErrKey.noConnection));
      expect(m.renderEn(),
          'vpn-1 → ya.ru — No connection — check network or URL');
      expect(m.renderWith(ru), startsWith('vpn-1 → ya.ru — '));
    });

    test('NodeWarning: рендер под обеими локалями, интерполяции verbatim', () {
      const w = UnknownObfsWarning('salamander');
      expect(
        w.renderEn(),
        'Unknown obfuscation type "salamander" was dropped (the core supports '
        'salamander and gecko only, and would otherwise break the whole config). '
        'The node connects without obfuscation.',
      );
      final rendered = w.messageWith(ru);
      expect(rendered, contains('salamander'));
      expect(rendered, isNot(w.renderEn()));
    });

    test('StopReason: рендер под обеими локалями', () {
      const r = StopRevoked();
      expect(r.renderEn(), contains('Another VPN app'));
      expect(r.messageWith(ru), isNot(r.renderEn()));
      const e = StopError('create service: bind failed');
      expect(e.renderEn(), 'Stopped: create service: bind failed');
      expect(e.messageWith(ru), contains('create service: bind failed'));
    });
  });

  group('renderEn() — пиненный английский', () {
    test('renderEn() всегда английский, независимо от локали', () {
      const msgs = <UiMsg>[
        ErrMsg(ErrKey.connectionTimedOut),
        PrefixedMsg(ErrPrefix.switchFailed, RawMsg('boom')),
        TimeoutError(10000),
        SubStatusFetching(),
        HttpStatusMsg(503),
        StopReasonMsg(StopRevoked()),
      ];
      // renderEn() не зависит ни от какого внешнего состояния локали.
      for (final m in msgs) {
        expect(m.renderEn(), isNot(contains(RegExp('[а-яА-ЯёЁ]'))));
      }
      // NodeWarning/ValidationIssue/StopReason — та же гарантия.
      expect(const UnknownObfsWarning('junk').renderEn(), contains('junk'));
      expect(const EmptyUrltestGroup('auto').renderEn(),
          'URL-test group "auto" has no outbounds.');
      expect(const StopError('x').renderEn(), 'Stopped: x');
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
