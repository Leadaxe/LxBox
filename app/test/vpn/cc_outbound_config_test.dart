import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/vpn/platform_channels.dart';

/// §761 — ответ `GetOutboundConfig(tag)` ядра v1.14.4-lx.37-rc.2 (SPEC 165
/// форка §2.2, `daemon/started_service_config_lx.go`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Пример из SPEC 165 §2.2 / docs-lx/lx-observability.md.
  const nodeReply = '''
{
  "tag": "NL-FREE#114",
  "original":  { "type": "wireguard", "tag": "NL-FREE#114", "detour": "o-ru" },
  "effective": { "type": "wireguard", "tag": "NL-FREE#114", "detour": "c-proton#0", "mtu": 1200 },
  "changes": [
    { "field": "detour", "from": "o-ru", "to": "c-proton#0",
      "by": { "type": "chain", "chain": "c-proton", "position": 1 } },
    { "field": "mtu", "to": 1200,
      "by": { "type": "mtu_align", "mode": "clamp", "below": "c-proton#0",
              "overhead": 80, "reason": "limited by warp" } },
    { "field": "tls.server_name", "from": "a.example",
      "by": { "type": "chain_rewrite", "chain": "c-proton", "position": 1,
              "node_type": "wireguard" } }
  ]
}
''';

  test('узел: original, effective и changes по полям', () {
    final c = CcOutboundConfig.tryParse(nodeReply)!;
    expect(c.tag, 'NL-FREE#114');
    expect(c.original!['detour'], 'o-ru');
    expect(c.effective['detour'], 'c-proton#0');
    expect(c.changes, hasLength(3));

    final d = c.changes[0];
    expect(d.field, 'detour');
    expect((d.from, d.to, d.hasFrom, d.hasTo), ('o-ru', 'c-proton#0', true, true));
    expect(d.by.type, CcConfigChangeBy.typeChain);
    expect((d.by.chain, d.by.position), ('c-proton', 1));

    final m = c.changes[1];
    expect(m.hasFrom, isFalse, reason: 'поля не было');
    expect(m.to, 1200);
    expect(m.by.type, CcConfigChangeBy.typeMtuAlign);
    expect((m.by.mode, m.by.below, m.by.overhead), ('clamp', 'c-proton#0', 80));
    expect(m.by.reason, 'limited by warp');

    final r = c.changes[2];
    expect(r.hasTo, isFalse, reason: 'поле снято');
    expect(r.by.type, CcConfigChangeBy.typeChainRewrite);
    expect(r.by.nodeType, 'wireguard');
  });

  test('хоп: только effective, original нет, changes пуст', () {
    final c = CcOutboundConfig.tryParse('{"tag":"c#0","effective":'
        '{"type":"chain-hop","tag":"c#0","chain":"c","position":0,"outbound":"a"}}')!;
    expect(c.original, isNull);
    expect(c.changes, isEmpty);
    expect(c.effective['type'], 'chain-hop');
  });

  test('мусор и пустой ответ — null', () {
    for (final s in [null, '', 'not json', '[1]', '{"tag":"x"}', '{"effective":1}']) {
      expect(CcOutboundConfig.tryParse(s), isNull, reason: '$s');
    }
  });

  group('MethodChannel', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('getOutboundConfig передаёт tag и разбирает ответ', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return nodeReply;
      });
      final c = await CcChannel.instance.getOutboundConfig('NL-FREE#114');
      expect(seen.method, 'ccGetOutboundConfig');
      expect(seen.arguments, {'tag': 'NL-FREE#114'});
      expect(c!.changes, hasLength(3));
    });

    test('туннель не поднят / ошибка ядра — null, без подстановки', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await CcChannel.instance.getOutboundConfig('x'), isNull);
      expect(await CcChannel.instance.getEffectiveConfig(), isNull);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NotFound');
      });
      expect(await CcChannel.instance.getOutboundConfig('x'), isNull);
      expect(await CcChannel.instance.getEffectiveConfig(), isNull);
    });

    test('getEffectiveConfig отдаёт строку как есть', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'ccGetEffectiveConfig');
        return '{"outbounds":[]}';
      });
      expect(await CcChannel.instance.getEffectiveConfig(), '{"outbounds":[]}');
    });
  });
}
