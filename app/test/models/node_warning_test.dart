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
        InsecureTlsWarning() => 'tls',
        NaiveBuildTagWarning() => 'naive_build',
      };
      expect(label, 'transport');
    });
  });
}
