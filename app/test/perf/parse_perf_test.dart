import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_identity.dart';
import 'package:lxbox/services/parser/engine/engine_mapper.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/mappers/uri_mapper.dart';
import 'package:lxbox/services/parser/mappers/uri_pipeline.dart';
import 'package:lxbox/services/parser/singbox_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

import 'vm_profile.dart';

/// §550 — ЗАМЕР разбора ссылок: из чего складывается `parseUri`.
///
/// Только замер, ассертов на время нет. «Лучший из N», как в
/// `test/parser/engine_perf_test.dart` и §548.
///
/// Этапы воронки меряются по отдельности, вызовом тех же публичных функций,
/// что зовёт `parseUri` → `parseUriViaPipeline` → `_runPipeline`:
///   маршрут  — схема, `_wireguardSchemes()`/`pipelineSchemes()`,
///              `registrySchemeType()` (копия логики, функции приватные);
///   маппер   — `mapViaEngine`;
///   санитайзер — `RegistrySanitizer.sanitize` на телах маппера;
///   модель   — `tagFromLabel` + `parseSingboxEntry`;
///   баннер   — `_providerBannerWarning` (копия: `isBannerTarget`).
/// Вход каждого этапа готовится вне замера. Identity (`nodeIdentityKey`) в
/// `parseUri` не входит — меряется для справки (её зовёт разбор подписки).
///
/// `LX_PERF=1` — таблица; без переменной тест молчит. `LX_PERF_RUNS` —
/// число прогонов (по умолчанию 3). `LX_PERF_PROFILE=1` — профиль VM:
/// `parseUri` по смешанному корпусу, `LX_PERF_PROFILE_SHAPE=<тип>` — один
/// тип, `LX_PERF_PROFILE_SCENARIO=json` — вход sing-box JSON.
/// `LX_PERF_QUICK=1` — только (a) и (b), без разбивки по типам.
///
/// Запуск (из `app/`):
///   LX_PERF=1 flutter test test/perf/parse_perf_test.dart
///   LX_PERF=1 LX_PERF_PROFILE=1 flutter test --coverage \
///     --coverage-path=/tmp/lcov.info test/perf/parse_perf_test.dart
void main() {
  final on = Platform.environment['LX_PERF'] == '1';
  final profile = Platform.environment['LX_PERF_PROFILE'] == '1';
  final quick = Platform.environment['LX_PERF_QUICK'] == '1';

  test('§550 разбор ссылок: мкс на ссылку', () async {
    if (!on) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I.loadDrafts(
      dir: 'assets/contract_draft',
      files: kDraftFiles,
    );

    final mixed = _links(_shapes.values.toList());
    final out = StringBuffer()
      ..writeln('§550 перф разбора (лучший из $_runs, мкс/ссылка, $_n ссылок)');

    // (a) parseUri целиком и sing-box JSON на тех же узлах.
    out.writeln('\n(a) целиком');
    out.writeln(_row(['корпус', 'parseUri', 'sing-box JSON', 'узлов JSON']));
    for (final c in _corpora.entries) {
      final links = _links(c.value);
      final uri = _best(() {
        for (final l in links) {
          parseUri(l);
        }
      });
      final cfg = _singboxConfig(links);
      var count = 0;
      final json = _best(() => count = parseSingboxConfigs([cfg]).length);
      out.writeln(_row([c.key, _us(uri), _us(json), '$count']));
    }

    // (b) этапы воронки на смешанном корпусе.
    out.writeln('\n(b) этапы parseUri, смешанный корпус');
    out.writeln(_row(['этап', 'мкс/ссылка']));
    final stages = _stages(mixed);
    for (final e in stages.entries) {
      out.writeln(_row([e.key, _us(e.value)]));
    }

    // (c) по типам ссылки; `LX_PERF_QUICK=1` — пропустить (A/B гипотез
    // сверяли по (a)/(b), (c) идёт ещё ~2 минуты).
    if (!quick) {
      out.writeln('\n(c) по типам ссылки');
      out.writeln(
        _row([
          'тип',
          'parseUri',
          'маршрут',
          'маппер',
          'санитайзер',
          'модель',
          'остаток',
          'JSON',
        ]),
      );
      for (final s in _shapes.entries) {
        final links = _links([s.value]);
        final st = _stages(links);
        final cfg = _singboxConfig(links);
        final json = _best(() => parseSingboxConfigs([cfg]));
        out.writeln(
          _row([
            s.key,
            _us(st['parseUri']!),
            _us(st['маршрут']!),
            _us(st['маппер']!),
            _us(st['санитайзер']!),
            _us(st['модель']!),
            _us(st['остаток']!),
            _us(json),
          ]),
        );
      }
    }

    // ignore: avoid_print
    print(out);

    if (profile) {
      final shape = Platform.environment['LX_PERF_PROFILE_SHAPE'];
      final links = shape == null ? mixed : _links([_shapes[shape]!]);
      final json = Platform.environment['LX_PERF_PROFILE_SCENARIO'] == 'json';
      final cfg = _singboxConfig(links);
      // ignore: avoid_print
      print(
        await vmProfile(
          json
              ? () => parseSingboxConfigs([cfg])
              : () {
                  for (final l in links) {
                    parseUri(l);
                  }
                },
          const Duration(seconds: 5),
          tag: '§550',
          unit: 'по $_n ссылок${json ? ' (sing-box JSON)' : ''}',
          probes: _probes,
        ),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

const _n = 2000;

final _runs = int.tryParse(Platform.environment['LX_PERF_RUNS'] ?? '') ?? 3;

/// Точки гипотез H1–H6 (§550).
const _probes = [
  'RegExp',
  'Uri.',
  '_Uri',
  'jsonEncode',
  'jsonDecode',
  '_JsonStringifier',
  '_prettyJson',
  'sanitize',
  'newUuidV4',
  'Random',
  'registrySchemeType',
  'pipelineSchemes',
  'registryUriSchemes',
  '_wireguardSchemes',
  'sectionFor',
  'typesFor',
  'runSection',
  'decodeBase64',
  'nodeIdentity',
  'tagFromLabel',
  'Map.from',
  '_interpolate',
  'split',
];

const _pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
const _uuid = '8f2e1c44-0000-4000-8000-0000000000';

String _vmess(int i) =>
    'vmess://${base64.encode(utf8.encode(jsonEncode({'v': '2', 'ps': 'm$i', 'add': 'h$i.example.com', 'port': '443', 'id': '${_uuid}09', 'aid': '0', 'scy': 'auto', 'net': 'ws', 'host': 'h$i.example.com', 'path': '/v', 'tls': 'tls', 'sni': 'h$i.example.com'})))}';

/// Шаблоны ссылок; `@I@` — номер (уникальные хост и имя, как в подписке).
/// Trojan — пять форм §480 (`engine_perf_test`).
final Map<String, List<String Function(int)>> _shapes = {
  'vless vision': [
    _t(
      'vless://${_uuid}01@h@I@.example.com:443?security=tls'
      '&sni=h@I@.example.com&fp=chrome&flow=xtls-rprx-vision&type=tcp#v@I@',
    ),
  ],
  'vless ws': [
    _t(
      'vless://${_uuid}02@h@I@.example.com:443?security=tls'
      '&sni=h@I@.example.com&fp=chrome&type=ws&path=%2Fws&host=h@I@.example.com#w@I@',
    ),
  ],
  'vless reality grpc': [
    _t(
      'vless://${_uuid}03@h@I@.example.com:443'
      '?security=reality&sni=www.example.org&fp=chrome&pbk=$_pbk&sid=abcd'
      '&type=grpc&serviceName=gsvc#r@I@',
    ),
  ],
  'trojan 5 форм': [
    _t(
      'trojan://pass123@h@I@.example.com:443?security=tls&sni=h@I@.example.com#t@I@',
    ),
    _t(
      'trojan://pass123@h@I@.example.com:443?type=ws&security=tls'
      '&host=h@I@.example.com&path=%2Fws&sni=h@I@.example.com#t@I@',
    ),
    _t(
      'trojan://pass123@h@I@.example.com:443?type=ws&path=%2Fx%3Fed%3D2560'
      '&security=tls&sni=h@I@.example.com#t@I@',
    ),
    _t(
      'trojan://pass123@h@I@.example.com:443?type=grpc&security=tls'
      '&serviceName=gsvc&sni=h@I@.example.com#t@I@',
    ),
    _t(
      'trojan://pass123@h@I@.example.com:443?security=tls&alpn=h2%2Chttp%2F1.1'
      '&fp=hellochrome_auto&sni=h@I@.example.com#t@I@',
    ),
  ],
  'hysteria2 obfs': [
    _t(
      'hysteria2://pass123@h@I@.example.com:443'
      '?sni=h@I@.example.com&obfs=salamander&obfs-password=op#y@I@',
    ),
  ],
  'ss plugin': [
    _t(
      'ss://YWVzLTI1Ni1nY206cGFzczEyMw==@h@I@.example.com:8388'
      '?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dx.example#s@I@',
    ),
  ],
  'tuic': [
    _t(
      'tuic://22222222-2222-2222-2222-222222222222:tuic-pass'
      '@h@I@.example.com:443?congestion_control=bbr&alpn=h3'
      '&sni=h@I@.example.com#u@I@',
    ),
  ],
  'wireguard': [
    _t(
      'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA='
      '@h@I@.example.com:51820?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
      '&address=10.0.0.2/32#g@I@',
    ),
  ],
  'awg': [
    _t(
      'awg://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA='
      '@h@I@.example.com:51820?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
      '&address=10.0.0.2/32&jc=4&jmin=40&jmax=70&s1=0&s2=0'
      '&h1=1&h2=2&h3=3&h4=4#a@I@',
    ),
  ],
  'vmess ws': [_vmess],
};

String Function(int) _t(String tpl) =>
    (i) => tpl.replaceAll('@I@', '$i');

final _corpora = {
  'смешанный': _shapes.values.toList(),
  'trojan §480': [_shapes['trojan 5 форм']!],
};

/// [groups] — формы по типам; ссылки идут по кругу типов, внутри типа — по
/// кругу форм.
List<String> _links(List<List<String Function(int)>> groups) => [
  for (var i = 0; i < _n; i++)
    () {
      final g = groups[i % groups.length];
      return g[(i ~/ groups.length) % g.length](i);
    }(),
];

/// Те же узлы sing-box-конфигом: тела `getEntries(null)` разобранных ссылок.
Map<String, dynamic> _singboxConfig(List<String> links) {
  final outbounds = <Object?>[];
  final endpoints = <Object?>[];
  for (final l in links) {
    final n = parseUri(l);
    if (n == null) throw StateError('не разобралось: $l');
    final e = n.getEntries(null).main;
    final m = jsonDecode(jsonEncode(e.map));
    (e.map['type'] == 'wireguard' ? endpoints : outbounds).add(m);
  }
  return {'outbounds': outbounds, 'endpoints': endpoints};
}

String _scheme(String l) => l.trim().split('://').first.toLowerCase();

/// Копия `_wireguardSchemes()` из `uri_parsers.dart`.
Set<String> _wgSchemes() {
  final out = <String>{'wireguard', 'wg', 'awg'};
  for (final s in pipelineSchemes()) {
    if (registrySchemeType(s) == 'wireguard') out.add(s);
  }
  return out;
}

Map<String, Duration> _stages(List<String> links) {
  final types = [
    for (final l in links)
      registrySchemeType(_scheme(l)) ?? (throw StateError('схема: $l')),
  ];
  final parseAll = _best(() {
    for (final l in links) {
      parseUri(l);
    }
  });
  final route = _best(() {
    for (final l in links) {
      final s = _scheme(l);
      final wg = _wgSchemes();
      if (pipelineSchemes().contains(s) || wg.contains(s)) {
        registrySchemeType(s);
      }
    }
  });
  final map = _best(() {
    for (var i = 0; i < links.length; i++) {
      mapViaEngine(links[i], types[i]);
    }
  });
  List<UriMapping> mappings() => [
    for (var i = 0; i < links.length; i++) mapViaEngine(links[i], types[i])!,
  ];
  Map<String, dynamic> merged(UriMapping m) =>
      m.extensionFields.isEmpty ? m.body : {...m.body, ...m.extensionFields};
  final sanitize = _bestPrepared(mappings, (all) {
    for (final m in all) {
      final b = merged(m);
      RegistrySanitizer.sanitize(
        b,
        scheme: b['type'] as String,
        coreVersion: '0.0.0',
        applyCoreGates: false,
        source: m.bodySource,
        kinds: m.kinds,
      );
    }
  });
  List<(UriMapping, Map<String, dynamic>)> sanitized() => [
    for (final m in mappings())
      () {
        final b = merged(m);
        final r = RegistrySanitizer.sanitize(
          b,
          scheme: b['type'] as String,
          coreVersion: '0.0.0',
          applyCoreGates: false,
          source: m.bodySource,
          kinds: m.kinds,
        );
        return (m, r.body!);
      }(),
  ];
  final model = _bestPrepared(sanitized, (all) {
    for (var i = 0; i < all.length; i++) {
      final (m, body) = all[i];
      final (server, port) =
          m.tagAddress ??
          (
            body['server']?.toString() ?? '',
            (body['server_port'] as num?)?.toInt() ?? 0,
          );
      body['tag'] = tagFromLabel(m.label, body['type'] as String, server, port);
      final node = parseSingboxEntry(
        body,
        rawSource: links[i],
        label: m.label,
        wsEarlyDataHeaderImplicit: m.wsEarlyDataHeaderImplicit,
      );
      if (node != null) markPipelineParsed(node);
    }
  });
  final nodes = [for (final l in links) parseUri(l)!];
  final banner = _best(() {
    for (final n in nodes) {
      MapperSections.I.documents
          ?.sourceByKind('uri_lines')
          ?.isBannerTarget(n.server);
    }
  });
  final identity = _best(() {
    for (final n in nodes) {
      nodeIdentityKey(n);
    }
  });
  final sum = route + map + sanitize + model + banner;
  return {
    'parseUri': parseAll,
    'маршрут': route,
    'маппер': map,
    'санитайзер': sanitize,
    'модель': model,
    'баннер': banner,
    'сумма этапов': sum,
    'остаток': parseAll - sum,
    'identity (вне)': identity,
  };
}

Duration _best(void Function() f) {
  f();
  var best = const Duration(days: 1);
  for (var r = 0; r < _runs; r++) {
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    if (sw.elapsed < best) best = sw.elapsed;
  }
  return best;
}

/// Вход готовится заново на каждый прогон и вне замера: санитайзер и модель
/// пишут в тело.
Duration _bestPrepared<T>(T Function() prepare, void Function(T) f) {
  f(prepare());
  var best = const Duration(days: 1);
  for (var r = 0; r < _runs; r++) {
    final input = prepare();
    final sw = Stopwatch()..start();
    f(input);
    sw.stop();
    if (sw.elapsed < best) best = sw.elapsed;
  }
  return best;
}

String _us(Duration d) => (d.inMicroseconds / _n).toStringAsFixed(1);

String _row(List<String> cells) =>
    '| ${[for (final c in cells) c.padRight(12)].join(' | ')} |';
