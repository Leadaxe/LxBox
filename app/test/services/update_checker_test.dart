import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/update_checker.dart';

void main() {
  group('isNewer — semver comparisons', () {
    test('strict newer patch', () {
      expect(isNewer('v1.4.3', '1.4.2'), isTrue);
    });

    test('strict newer minor', () {
      expect(isNewer('v1.5.0', '1.4.99'), isTrue);
    });

    test('strict newer major', () {
      expect(isNewer('v2.0.0', '1.99.99'), isTrue);
    });

    test('equal returns false', () {
      expect(isNewer('v1.4.2', '1.4.2'), isFalse);
      expect(isNewer('1.4.2', 'v1.4.2'), isFalse);
    });

    test('older returns false', () {
      expect(isNewer('v1.4.1', '1.4.2'), isFalse);
      expect(isNewer('v0.9.99', '1.0.0'), isFalse);
    });

    test('two-part vs three-part — pad with zero', () {
      expect(isNewer('v1.5', '1.4.99'), isTrue);
      expect(isNewer('v1.4', '1.4.0'), isFalse);
      expect(isNewer('v1.4.1', '1.4'), isTrue);
    });

    test('handles v / V / no prefix', () {
      expect(isNewer('1.4.3', '1.4.2'), isTrue);
      expect(isNewer('V1.4.3', 'v1.4.2'), isTrue);
    });

    test('strips suffix after first non-numeric', () {
      // local-build с "-dirty" не должен ложно быть newer
      expect(isNewer('v1.4.2-dirty', '1.4.2'), isFalse);
      expect(isNewer('v1.4.3-rc1', '1.4.2'), isTrue);
    });

    test('malformed input returns false (no false-positive notify)', () {
      expect(isNewer('', '1.4.2'), isFalse);
      expect(isNewer('not-a-version', '1.4.2'), isFalse);
      expect(isNewer('v1.4.2', ''), isFalse);
      expect(isNewer('v1.x.y', '1.4.2'), isFalse);
      expect(isNewer('v1', '1.4.2'), isFalse); // single component invalid
      expect(isNewer('v1.2.3.4', '1.4.2'), isFalse); // too many parts
    });

    test('whitespace tolerated', () {
      expect(isNewer(' v1.4.3 ', '1.4.2'), isTrue);
    });
  });
}
