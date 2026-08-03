import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';

void main() {
  group('NodeWarning equality', () {
    test('same subclass + same fields == equal', () {
      expect(
        const UnsupportedTransportWarning('xhttp', 'httpupgrade'),
        const UnsupportedTransportWarning('xhttp', 'httpupgrade'),
      );
    });

    // §279 — равенство по runtimeType + полям данных (не по отрендеренной
    // строке): dedup-гранулярность та же, но переживает смену локали.
    test('same subclass + different fields != equal', () {
      expect(
        const UnsupportedTransportWarning('xhttp', 'httpupgrade') ==
            const UnsupportedTransportWarning('xhttp', 'ws'),
        isFalse,
      );
      expect(
        const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'a') ==
            const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'b'),
        isFalse,
      );
    });

    // §279 — XhttpResetReason: message() обязан воспроизводить дословно
    // те же English-фразы, что были free-text до enum'а.
    test('XhttpParamResetWarning renders verbatim from enum reason', () {
      expect(
        const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'bogus')
            .renderEn(),
        'XHTTP "session_placement" reset to default — value "bogus" is not '
        'a valid session_placement (would otherwise break the whole config).',
      );
      expect(
        const XhttpParamResetWarning(
                'uplink_http_method', XhttpResetReason.getRequiresPacketUp)
            .renderEn(),
        'XHTTP "uplink_http_method" reset to default — GET requires '
        'packet-up mode (would otherwise break the whole config).',
      );
    });

    test('different subclasses != equal', () {
      expect(
        const UnsupportedTransportWarning('xhttp', 'httpupgrade') ==
            const UnsupportedProtocolWarning('xhttp'),
        isFalse,
      );
    });

    test('severity maps per type', () {
      expect(const MissingFieldWarning('sni').severity, WarningSeverity.error);
      // info, не warning — провайдеры часто намеренно ставят флаг (REALITY,
      // self-signed, IP-литералы); UI красит серым, не пугает.
      expect(const InsecureTlsWarning().severity, WarningSeverity.info);
      expect(const DeprecatedFlowWarning('xtls').severity, WarningSeverity.info);
    });

    test('exhaustive switch compiles', () {
      const NodeWarning w = UnsupportedTransportWarning('xhttp', 'httpupgrade');
      final label = switch (w) {
        UnsupportedTransportWarning() => 'transport',
        UnsupportedProtocolWarning() => 'protocol',
        MissingFieldWarning() => 'field',
        DeprecatedFlowWarning() => 'flow',
        VisionWithTransportWarning() => 'vision_transport',
        InsecureTlsWarning() => 'tls',
        NaiveBuildTagWarning() => 'naive_build',
        XhttpParamResetWarning() => 'xhttp_reset',
        UnknownFingerprintWarning() => 'fingerprint',
        EchIgnoredWarning() => 'ech_ignored',
        UnknownObfsWarning() => 'obfs_unknown',
        MissingObfsPasswordWarning() => 'obfs_no_password',
        // §368 — импорт sing-box JSON
        DetourCycleBrokenWarning() => 'detour_cycle',
        DetourTargetMissingWarning() => 'detour_missing',
        DetourToGroupWarning() => 'detour_group',
        DetourChainTooDeepWarning() => 'detour_deep',
        SelectorAsAutoWarning() => 'selector_as_auto',
        GroupMemberMissingWarning() => 'group_member_missing',
      };
      expect(label, 'transport');
    });
  });
}
