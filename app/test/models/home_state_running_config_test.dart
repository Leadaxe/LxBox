import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';

/// §311 — running config от ядра (клиентская часть kernel SPEC 036).
///
/// Корень бага: список нод приходит из памяти ядра (`ccGroups`, §122), а
/// resolve тега шёл по пересобранному файлу — в окне «пересборка до рестарта»
/// UI мешал срезы и отдавал «Not found» на видимую в списке ноду. §311 держит
/// снапшот работающего конфига (`runningConfigRaw`, от `GetRunningConfig`)
/// и резолвит по нему через `activeModel`.
void main() {
  String cfg(List<String> tags) => jsonEncode({
        'outbounds': [
          for (final t in tags) {'tag': t, 'type': 'vless'},
        ],
      });

  final saved = cfg(['L: zФранция']); // import-rule §302: ⚡ → z
  final running = cfg(['L: ⚡Франция']); // ядро стартовало ДО пересборки

  group('§311 activeModel — выбор среза', () {
    test('туннель down → configModel (снапшота нет и не надо)', () {
      final s = HomeState(configRaw: saved);
      expect(identical(s.activeModel, s.configModel), isTrue);
      expect(s.activeConfigRaw, saved);
    });

    test('туннель up + снапшот → runningModel', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: saved,
        runningConfigRaw: running,
      );
      expect(identical(s.activeModel, s.runningModel), isTrue);
      expect(s.activeConfigRaw, running);
    });

    test('туннель up БЕЗ снапшота → configModel (деградация: старое ядро)',
        () {
      final s = HomeState(tunnel: TunnelStatus.connected, configRaw: saved);
      expect(identical(s.activeModel, s.configModel), isTrue);
      expect(s.activeConfigRaw, saved);
    });

    test('туннель down при живом снапшоте → configModel (снапшот протух)', () {
      // Guard на случай, если какой-то down-путь забыл сбросить снапшот:
      // activeModel не должен его отдавать при tunnelUp == false.
      final s = HomeState(configRaw: saved, runningConfigRaw: running);
      expect(identical(s.activeModel, s.configModel), isTrue);
    });
  });

  group('§311 РЕГРЕСС — смешение срезов', () {
    test('тег из ядра резолвится при переименованном saved', () {
      // Ровно сценарий бага (device-verified 26.07): ядро крутит '⚡Франция'
      // и отдаёт этот тег в списке; пересборка уже переписала файл в 'z'.
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: saved,
        runningConfigRaw: running,
      );
      expect(s.activeModel['L: ⚡Франция'], isNotNull);
      expect(s.activeModel.outboundChain('L: ⚡Франция'), isNotEmpty,
          reason: 'нода из списка (= из ядра) обязана резолвиться');
      expect(s.activeModel['L: zФранция'], isNull,
          reason: 'тега из непримененной пересборки в ядре нет — и не должно');
    });

    test('после рестарта (снапшот пере-захвачен) resolve переезжает', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: saved,
        runningConfigRaw: saved, // ядро перечитало файл
      );
      expect(s.activeModel['L: zФранция'], isNotNull);
      expect(s.activeModel['L: ⚡Франция'], isNull);
    });
  });

  group('§311 copyWith — снапшот', () {
    test('set / preserve / clear', () {
      final s0 = HomeState(configRaw: saved);
      final s1 = s0.copyWith(runningConfigRaw: running);
      expect(s1.runningConfigRaw, running);
      expect(s1.runningModel, isNotNull);

      final s2 = s1.copyWith(busy: true); // _unset → не трогаем
      expect(s2.runningConfigRaw, running);

      final s3 = s2.copyWith(runningConfigRaw: null); // явный сброс
      expect(s3.runningConfigRaw, isNull);
      expect(s3.runningModel, isNull, reason: 'модель гаснет вместе с raw');
    });

    test('runningModel шарится между copyWith без смены raw (§091)', () {
      final s1 = HomeState(configRaw: saved, runningConfigRaw: running);
      final s2 = s1.copyWith(busy: true);
      expect(identical(s2.runningModel, s1.runningModel), isTrue,
          reason: 'лишний jsonDecode на каждый copyWith недопустим');
      final s3 = s1.copyWith(runningConfigRaw: running);
      expect(identical(s3.runningModel, s1.runningModel), isFalse,
          reason: 'явная передача raw → честный ре-парс');
    });

    test('configModel не зависит от снапшота', () {
      final s1 = HomeState(configRaw: saved);
      final s2 = s1.copyWith(runningConfigRaw: running);
      expect(identical(s2.configModel, s1.configModel), isTrue);
    });
  });

  group('§311 kernel-style JSON (re-marshal форма SPEC 036)', () {
    test('парсится: null-поля, endpoints, подмешанный tun', () {
      // GetRunningConfig отдаёт re-marshal распарсенных options: omitempty,
      // `[] → null`, post-override tun с IncludePackage. ParsedConfig обязан
      // это прожевать как обычный JSON.
      final kernelStyle = jsonEncode({
        'inbounds': [
          {
            'type': 'tun',
            'tag': 'tun-in',
            'include_package': ['com.example.app'],
          },
        ],
        'outbounds': [
          {
            'tag': 'L: ⚡Франция',
            'type': 'vless',
            'server': '45.192.2.51',
            'tls': {'enabled': true, 'alpn': null},
          },
          {'tag': 'vpn-1', 'type': 'selector', 'outbounds': null},
        ],
        'endpoints': [
          {'tag': 'warp-out', 'type': 'wireguard'},
        ],
      });
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: saved,
        runningConfigRaw: kernelStyle,
      );
      expect(s.activeModel['L: ⚡Франция']?.type, 'vless');
      expect(s.activeModel['warp-out']?.kind, 'endpoint');
      expect(s.activeModel['vpn-1']?.isControl, isTrue);
    });
  });

  group('§311 потребители типа узла', () {
    test('isControlTag / sortedNodes pin-by-type берут тип из снапшота', () {
      // В снапшоте ядра direct-двойник есть, в (испорченном) saved — нет:
      // разница видна только если потребитель реально смотрит в снапшот.
      final runningWithDirect = jsonEncode({
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
          {'tag': 'L: ⚡Франция', 'type': 'vless'},
        ],
      });
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: cfg(['что-то-другое']),
        runningConfigRaw: runningWithDirect,
        nodes: ['direct-out', 'L: ⚡Франция'],
      );
      expect(s.isControlTag('direct-out'), isTrue);
      expect(s.sortedNodes.first, 'direct-out',
          reason: 'pin-by-type (§125) обязан видеть direct в срезе ядра');
    });
  });
}
