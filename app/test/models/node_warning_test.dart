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
      expect(const InsecureTlsWarning().severity, WarningSeverity.warning);
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
      };
      expect(label, 'transport');
    });
  });
}
