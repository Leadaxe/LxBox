import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

void main() {
  group('buildConfig — smoke', () {
    final template = WizardTemplate(
      parserConfig: ParserConfigBlock(),
      // §267 — group_templates: vpn-1 канал (direct+auto), auto-подгруппа.
      groupTemplates: GroupTemplates(
        channel: ChannelTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {'url': 'https://x', 'interval': '30s'},
        ),
        defaultChannels: [
          DefaultChannel(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
        ],
      ),
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
        'route': {'rules': []},
      },
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

    test('two VLESS nodes from UserServer → 2 outbounds + vpn-1 + auto', () async {
      final specs = [
        parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!,
        parseUri('vless://u2@h2.com:443?type=ws&security=tls#B')!,
      ];
      final list = UserServer(
        id: 'u1',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: specs,
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {
            'clash_api': '127.0.0.1:9090',
          },
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final tags = outs.map((o) => (o as Map)['tag']).toList();
      // §125 — глобальный ✨auto заменён на per-channel двойник vpn-1-auto.
      expect(tags, containsAll(['A', 'B', 'direct-out', 'vpn-1', 'vpn-1-auto']));
      expect(tags, isNot(contains(kAutoOutboundTag)));

      // vpn-1 includes node tags.
      final vpn1 =
          outs.firstWhere((o) => (o as Map)['tag'] == 'vpn-1') as Map;
      expect(vpn1['outbounds'], containsAll(['A', 'B']));
    });

    test('WireGuard node → endpoints array, not outbounds', () async {
      final wg = parseWireguardUri(
        'wireguard://pk_a@wg.example.com:51820?publickey=pk_b&address=10.0.0.2%2F32&mtu=1420#WG',
      )!;
      final list = UserServer(
        id: 'u2',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [wg],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );

      final endpoints = result.config['endpoints'] as List?;
      expect(endpoints, isNotNull);
      expect(endpoints!.any((e) => (e as Map)['tag'] == 'WG'), true);
      final outs = result.config['outbounds'] as List;
      expect(outs.any((o) => (o as Map)['tag'] == 'WG'), false);
    });

    test('tls_fragment=true fragments first-hop TLS only', () async {
      final spec = parseUri('vless://u@h:443?type=tcp&security=tls&sni=h#A')!;
      final list = UserServer(
        id: 'u3',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {
          'clash_api': '127.0.0.1:9090',
          'tls_fragment': 'true',
          'tls_record_fragment': 'true',
        }),
      );
      final outs = result.config['outbounds'] as List;
      final a = outs.firstWhere((o) => (o as Map)['tag'] == 'A') as Map;
      expect((a['tls'] as Map)['fragment'], true);
      expect((a['tls'] as Map)['record_fragment'], true);
    });

    test('§270 — tls_fragment пропускает naive (ядро отвергает fragment)', () async {
      final vless = parseUri('vless://u@h:443?type=tcp&security=tls&sni=h#V')!;
      final naive = parseUri('naive+https://p@n.example:443#N')!;
      final list = UserServer(
        id: 'u4',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [vless, naive],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {
          'clash_api': '127.0.0.1:9090',
          'tls_fragment': 'true',
          'tls_record_fragment': 'true',
        }),
      );
      final outs = result.config['outbounds'] as List;
      final v = outs.firstWhere((o) => (o as Map)['tag'] == 'V') as Map;
      final n = outs.firstWhere((o) => (o as Map)['tag'] == 'N') as Map;
      // vless получает fragment, naive — нет (иначе ядро: fatal).
      expect((v['tls'] as Map)['fragment'], true);
      expect((n['tls'] as Map).containsKey('fragment'), isFalse);
      expect((n['tls'] as Map).containsKey('record_fragment'), isFalse);
    });

    test('duplicate node tags across and within lists get -N suffix + prefix applied', () async {
      final a1 = parseUri('vless://u1@h1:443?type=ws&security=tls#Frankfurt')!;
      final a2 = parseUri('vless://u2@h2:443?type=ws&security=tls#Frankfurt')!;
      final b1 = parseUri('vless://u3@h3:443?type=ws&security=tls#Frankfurt')!;
      final listA = UserServer(
        id: 'A', name: 'A', enabled: true, tagPrefix: 'BL:',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste, createdAt: DateTime.now(),
        nodes: [a1, a2],
      );
      final listB = UserServer(
        id: 'B', name: 'B', enabled: true, tagPrefix: 'W:',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste, createdAt: DateTime.now(),
        nodes: [b1],
      );
      final result = await buildConfig(
        lists: [listA, listB],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );

      final outs = result.config['outbounds'] as List;
      final tags = outs.map((o) => (o as Map)['tag'] as String).toList();
      // Все теги уникальны.
      expect(tags.toSet().length, tags.length, reason: 'tags must be unique: $tags');
      // Префикс применён.
      expect(tags, contains('BL: Frankfurt'));
      expect(tags, contains('BL: Frankfurt-1'));
      expect(tags, contains('W: Frankfurt'));
      expect(result.validation.isOk, true);
    });

    // §122 Фаза 1b — clash_api БОЛЬШЕ НЕ инжектится/рандомизируется (ядро rc.2
    // без with_clash_api → блок даёт фатальный отказ старта). Раньше тут был
    // тест рандомизации порта; теперь проверяем ОБРАТНОЕ: clash_api НЕ попадает
    // в выходной конфиг даже если пришёл в userVars.
    test('§122 — clash_api НЕ инжектится в выходной конфиг', () async {
      final list = UserServer(
        id: 'u4',
        name: 'E',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: const [],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );
      expect(result.emitWarnings, isEmpty);
      // experimental.clash_api отсутствует в собранном конфиге.
      expect(result.config, isNot(contains('clash_api')));
      expect(result.config, isNot(contains('external_controller')));
    });

    // §215 — idle-suspend (ядро SPEC 020, route.lx_idle_suspend). Порог
    // прокидывается в route только когда задан; пусто = omitempty (поля нет).
    test('§215 idleSuspend="30s" → route.lx_idle_suspend', () async {
      final wg = parseWireguardUri(
        'wireguard://pk_a@wg.example.com:51820?publickey=pk_b&address=10.0.0.2%2F32&mtu=1420#WG',
      )!;
      final list = UserServer(
        id: 'u5',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [wg],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          idleSuspend: '30s',
        ),
      );
      final route = result.config['route'] as Map;
      expect(route['lx_idle_suspend'], '30s');
    });

    test('§215 idleSuspend="" (default) → нет route.lx_idle_suspend', () async {
      final wg = parseWireguardUri(
        'wireguard://pk_a@wg.example.com:51820?publickey=pk_b&address=10.0.0.2%2F32&mtu=1420#WG',
      )!;
      final list = UserServer(
        id: 'u6',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [wg],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
        ),
      );
      final route = result.config['route'] as Map;
      // Kill-switch: поле не пишется, дефолт ядра (idle-тик не запущен).
      expect(route.containsKey('lx_idle_suspend'), false);
    });

    // §272 — reachable-окно (route.lx_idle_suspend_reachable) эмитится только
    // вместе с базовым порогом: ядро отвергает reachable без lx_idle_suspend.
    test('§272 reachable пишется только при включённом idleSuspend', () async {
      final wg = parseWireguardUri(
        'wireguard://pk_a@wg.example.com:51820?publickey=pk_b&address=10.0.0.2%2F32&mtu=1420#WG',
      )!;
      final list = UserServer(
        id: 'u7',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [wg],
      );
      // Оба порога заданы → оба в route.
      final both = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          idleSuspend: '30s',
          idleSuspendReachable: '30m',
        ),
      );
      final bothRoute = both.config['route'] as Map;
      expect(bothRoute['lx_idle_suspend'], '30s');
      expect(bothRoute['lx_idle_suspend_reachable'], '30m');

      // Базовый выключен → reachable подавлен (иначе ядро упало бы на старте).
      final orphan = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          idleSuspendReachable: '30m',
        ),
      );
      final orphanRoute = orphan.config['route'] as Map;
      expect(orphanRoute.containsKey('lx_idle_suspend'), false);
      expect(orphanRoute.containsKey('lx_idle_suspend_reachable'), false);
    });
  });

  group('buildConfig — §161 empty required-var → default backstop', () {
    // Template с required int-var `tol` (default "30"), плейсхолдер в config.
    WizardTemplate templateWithTol() => WizardTemplate(
          parserConfig: ParserConfigBlock(),
          groupTemplates: GroupTemplates(),
          vars: [
            WizardVar(name: 'tol', type: 'int', defaultValue: '30'),
            WizardVar(
                name: 'opt',
                type: 'text',
                defaultValue: 'fallback',
                required: false),
          ],
          varSections: const [],
          config: {
            'experimental': {'tolerance': '@tol', 'opt': '@opt'},
            'outbounds': [
              {'tag': 'direct-out', 'type': 'direct'},
            ],
            'route': {'rules': []},
          },
          selectableRules: const [],
          dnsOptions: const {},
          pingOptions: const {},
          speedTestOptions: const {},
        );

    test('пустой userVar для required int → default (число, не "")', () async {
      final result = await buildConfig(
        lists: const [],
        template: templateWithTol(),
        settings: const BuildSettings(userVars: {'tol': ''}), // пусто в state
      );
      final exp = result.config['experimental'] as Map<String, dynamic>;
      expect(exp['tolerance'], 30); // backstop подставил default, coerce → int
      expect(exp['tolerance'], isA<int>());
    });

    test('непустой userVar для required int → используется как есть', () async {
      final result = await buildConfig(
        lists: const [],
        template: templateWithTol(),
        settings: const BuildSettings(userVars: {'tol': '50'}),
      );
      final exp = result.config['experimental'] as Map<String, dynamic>;
      expect(exp['tolerance'], 50);
    });

    test('optional (required:false) пустой → НЕ подставляет default (§033)',
        () async {
      final result = await buildConfig(
        lists: const [],
        template: templateWithTol(),
        settings: const BuildSettings(userVars: {'tol': '30', 'opt': ''}),
      );
      final exp = result.config['experimental'] as Map<String, dynamic>;
      // opt — optional: пусто → "" остаётся, default НЕ навязывается. coerce
      // text → пустая строка (не Dropped: это build_config-движок, не preset).
      expect(exp['opt'], '');
    });
  });
}
