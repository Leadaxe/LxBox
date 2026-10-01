// §56 (контракт 1.1.60) — узловой гейт ядра по данным реестра:
// `build_tag`/`min_core` + `on_core_unsupported` у тела, поля и `range_form`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/contract/node_core_gate.dart';
import 'package:lxbox/services/contract/registry.dart';

import '../contract_paths.dart';

void main() {
  setUpAll(loadTestRegistry);

  const tsBody = <String, dynamic>{'type': 'tailscale', 'tag': 'ts'};
  final noTs = kCoreBuildTags.difference({'with_tailscale'});

  Map<String, dynamic> wg({Object? keepalive, bool awg3 = false}) => {
        'type': 'wireguard',
        'tag': 'wg',
        'private_key': 'YNXtAzepDqRv9H52osJVDQnznT5AM11eCK3ESpwSt04=',
        'address': ['10.0.0.2/32'],
        if (awg3)
          'header_protection_key': 'YNXtAzepDqRv9H52osJVDQnznT5AM11eCK3ESpwSt04=',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'YNXtAzepDqRv9H52osJVDQnznT5AM11eCK3ESpwSt04=',
            'persistent_keepalive_interval': ?keepalive,
          },
        ],
      };

  test('реестр: атрибуты 1.1.60 читаются моделью', () {
    final ts = ContractRegistry.I.schemaFor('tailscale')!;
    expect(ts.buildTag, 'with_tailscale');
    expect(ts.onCoreUnsupported?.dropsNode, isTrue);
    expect(ts.onCoreUnsupported?.code, 'tailscale_core_unsupported');
    final wgs = ContractRegistry.I.schemaFor('wireguard')!;
    expect(wgs.levels, ['awg', 'awg1.5', 'awg2', 'awg3', 'awg3.1']);
    final rf = wgs.fields['peers']!.items!.fields!['persistent_keepalive_interval']!
        .rangeForm!;
    expect(rf.level, 'awg3');
    expect(rf.onCoreUnsupported?.code, 'awg3_core_unsupported');
  });

  test('tailscale: без тега — отказ с кодом, с тегом и без знания тегов — годен',
      () {
    final r = nodeCoreRefusal('tailscale', tsBody, CoreInfo(tags: noTs));
    expect(r?.code, 'tailscale_core_unsupported');
    expect(r?.path, isNull);
    expect(r?.reason, contains('with_tailscale'));
    expect(nodeCoreRefusal('tailscale', tsBody, const CoreInfo(tags: kCoreBuildTags)),
        isNull);
    expect(nodeCoreRefusal('tailscale', tsBody, const CoreInfo()), isNull);
  });

  test('AWG range_form: диапазон на старом ядре снимает узел, число — нет', () {
    const oldCore = CoreInfo(version: '1.14.0-lx.31', tags: kCoreBuildTags);
    final r = nodeCoreRefusal('wireguard', wg(keepalive: '5-10'), oldCore);
    expect(r?.code, 'awg3_core_unsupported');
    expect(r?.path, 'peers[].persistent_keepalive_interval');
    expect(nodeCoreRefusal('wireguard', wg(keepalive: 25), oldCore), isNull);
    // Ядро без with_awg — диапазон не годится и на новой версии.
    final noAwg = CoreInfo(
        version: '1.14.2-lx.4', tags: kCoreBuildTags.difference({'with_awg'}));
    expect(nodeCoreRefusal('wireguard', wg(keepalive: '5-10'), noAwg)?.code,
        'awg3_core_unsupported');
    // Встроенное ядро — годен.
    const cur = CoreInfo(version: '1.14.2-lx.4', tags: kCoreBuildTags);
    expect(nodeCoreRefusal('wireguard', wg(keepalive: '5-10'), cur), isNull);
  });

  test('AWG 3.x поле: min_core не выполнен — узел снят; версия неизвестна — нет',
      () {
    const oldCore = CoreInfo(version: '1.14.0-lx.31', tags: kCoreBuildTags);
    final r = nodeCoreRefusal('wireguard', wg(awg3: true), oldCore);
    expect(r?.code, 'awg3_core_unsupported');
    expect(r?.path, 'header_protection_key');
    expect(nodeCoreRefusal('wireguard', wg(awg3: true), const CoreInfo()),
        isNull);
  });

  test('пин тегов ядра совпадает с app/android/libbox.version', () {
    final pin = File('android/libbox.version').readAsStringSync().trim();
    expect(kCoreBuildTagsPin, pin,
        reason: 'ядро бампнуто: сверь kCoreBuildTags с sharedTags '
            'sing-box-lx cmd/internal/build_libbox/main.go и docs/KERNEL.md, '
            'затем обнови kCoreBuildTagsPin');
  });
}
