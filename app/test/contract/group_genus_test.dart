import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/group_genus.dart';
import 'package:lxbox/services/contract/registry.dart';

import '../contract_paths.dart';

// §565 — род группы читается из `group.json` → `genus`; зеркало на случай
// незагруженного реестра обязано совпадать с реестром.
void main() {
  setUpAll(loadTestRegistry);

  test('значения и роли рода — из реестра, зеркало совпадает', () {
    final genus = [
      for (final n in ContractRegistry.I.protocolNames)
        if (ContractRegistry.I.rawProtocol(n)?['kind'] == 'group')
          ContractRegistry.I.rawProtocol(n)!['genus'],
    ].single as Map;
    expect(GroupGenus.values, genus['values']);
    expect(GroupGenus.values, kGenusFallbackValues);
    expect(GroupGenus.auto, kGenusFallbackAuto);
    expect(GroupGenus.values, contains(GroupGenus.manual));
    expect(GroupGenus.manual, isNot(GroupGenus.auto));
  });

  test('by_source: sing-box несёт род сам, Xray и autogroup — автовыбор', () {
    expect(GroupGenus.forSource(kGenusSourceSingbox), isNull);
    expect(GroupGenus.resolve(kGenusSourceSingbox, GroupGenus.manual),
        GroupGenus.manual);
    expect(GroupGenus.resolve(kGenusSourceSingbox, 'vless'), isNull);
    expect(GroupGenus.forSource(kGenusSourceXray), GroupGenus.auto);
    expect(GroupGenus.forSource(kGenusSourceUri), GroupGenus.auto);
  });
}
