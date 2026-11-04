import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';

/// §715 — замеры URL-теста ядра живут в псевдо-Направлении
/// `HomeState.coreDirection` и в показе всегда «чужие» (§325): свой замер →
/// замер другого Направления → замер ядра.
void main() {
  const core = HomeState.coreDirection;

  test('только замер ядра → показан и помечен чужим', () {
    final s = HomeState(
      selectedGroup: 'vpn-1',
      delayByDirection: {
        core: {'DE-1': 57},
      },
    );
    expect(s.delayOf('DE-1'), 57);
    expect(s.delayIsForeign('DE-1'), isTrue);
  });

  test('свой замер перекрывает замер ядра', () {
    final s = HomeState(
      selectedGroup: 'vpn-1',
      delayByDirection: {
        'vpn-1': {'DE-1': 120},
        core: {'DE-1': 57},
      },
    );
    expect(s.delayOf('DE-1'), 120);
    expect(s.delayIsForeign('DE-1'), isFalse);
  });

  test('замер другого Направления выше замера ядра, даже если ядро первое', () {
    final s = HomeState(
      selectedGroup: 'vpn-1',
      delayByDirection: {
        core: {'DE-1': 57},
        'vpn-2': {'DE-1': 200},
      },
    );
    expect(s.delayOf('DE-1'), 200);
    expect(s.delayIsForeign('DE-1'), isTrue);
  });

  test('отрицательный замер ядра (провал теста) показан как ERR', () {
    final s = HomeState(
      selectedGroup: 'vpn-1',
      delayByDirection: {
        core: {'SOCKS-1': -1},
      },
    );
    expect(s.delayOf('SOCKS-1'), -1);
    expect(s.delayIsForeign('SOCKS-1'), isTrue);
  });

  test('ядро узел не мерило → null', () {
    final s = HomeState(
      selectedGroup: 'vpn-1',
      delayByDirection: {
        core: {'DE-1': 57},
      },
    );
    expect(s.delayOf('NL-1'), isNull);
    expect(s.delayIsForeign('NL-1'), isFalse);
  });
}
