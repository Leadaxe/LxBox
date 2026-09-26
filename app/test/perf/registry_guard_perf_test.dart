import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/services/builder/registry_gate.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/probe/probe_config.dart';

import 'vm_profile.dart';

/// §548 — ЗАМЕР гарда реестра на probe-конфиге (§546) и санитайзера под ним.
///
/// Только замер: поведение не проверяется, ассертов на время нет. Порядок
/// чисел — «лучший из трёх», как в `test/parser/engine_perf_test.dart`:
/// меряем стоимость работы, а не шум планировщика.
///
/// `LX_PERF=1` — таблица в stdout; без переменной тест молчит (на CI машина
/// общая, время там ничего не говорит). `LX_PERF_PROFILE=1` вдобавок снимает
/// профиль сэмплирующим профилировщиком VM (сценарий «сборка батчей с
/// гардом», ~5 с) и печатает top по self- и inclusive-времени. Клиент
/// VM service — голый JSON-RPC по WebSocket: `dart run` на этом пакете не
/// работает (`package:lxbox` тянет `dart:ui` через `flutter/foundation`), а
/// `package:vm_service` в зависимостях приложения нет.
///
/// Запуск (из `app/`):
///   LX_PERF=1 flutter test test/perf/registry_guard_perf_test.dart
///   LX_PERF=1 LX_PERF_PROFILE=1 flutter test --coverage \
///     --coverage-path=/tmp/lcov.info test/perf/registry_guard_perf_test.dart
///
/// Профилю нужен VM service, а `flutter test` поднимает его только с
/// `--coverage` (или `--start-paused`); без него профиль печатает
/// «VM service недоступен». Таблица под `--coverage` совпала с обычной в
/// пределах шума (§548); файл покрытия — во временный каталог.
void main() {
  final on = Platform.environment['LX_PERF'] == '1';
  final profile = Platform.environment['LX_PERF_PROFILE'] == '1';

  test('§548 гард реестра: мкс на узел', () async {
    if (!on) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I.loadDrafts(
      dir: 'assets/contract_draft',
      files: kDraftFiles,
    );

    final out = StringBuffer()
      ..writeln(
        '§548 перф гарда (лучший из $_runs, мкс/узел, $_n узлов, '
        'ядро $_core)',
      );

    // (a) сборка батчей: §546-набор и разнородный корпус.
    out.writeln('\n(a) buildProbeBatches / части');
    out.writeln(
      _row([
        'корпус',
        'батчи+гард',
        'батчи ""',
        'эмит',
        'гард',
        'гард ""',
        'батчи−гард',
      ]),
    );
    for (final c in _corpora.entries) {
      final nodes = _nodes(c.value);
      final full = _best(() => buildProbeBatches(nodes, coreVersion: _core));
      final fullNoVer = _best(() => buildProbeBatches(nodes));
      final emit = _best(() {
        for (final n in nodes) {
          final raw = n.getEntries(null);
          <SingboxEntry>[...raw.detours, raw.main];
        }
      });
      final gate = _bestPrepared(() => [for (final n in nodes) _entriesOf(n)], (
        all,
      ) {
        for (final e in all) {
          applyRegistryGate(e, coreVersion: _core);
        }
      });
      final gateNoVer = _bestPrepared(
        () => [for (final n in nodes) _entriesOf(n)],
        (all) {
          for (final e in all) {
            applyRegistryGate(e, coreVersion: '');
          }
        },
      );
      out.writeln(
        _row([
          c.key,
          _us(full),
          _us(fullNoVer),
          _us(emit),
          _us(gate),
          _us(gateNoVer),
          _us(full - gate),
        ]),
      );
    }

    // (b) санитайзер сам по себе на готовых телах (копия тела — вне замера).
    out.writeln('\n(b) RegistrySanitizer.sanitize на готовых телах');
    out.writeln(
      _row(['корпус', 'ядро задано', 'версия ""', 'гейты ядра выкл']),
    );
    for (final c in _corpora.entries) {
      final nodes = _nodes(c.value);
      List<Map<String, dynamic>> bodies() => [
        for (final n in nodes)
          for (final e in _entriesOf(n))
            (jsonDecode(jsonEncode(e.map)) as Map).cast<String, dynamic>(),
      ];
      Duration run(String ver, {bool gates = true}) =>
          _bestPrepared(bodies, (all) {
            for (final b in all) {
              RegistrySanitizer.sanitize(
                b,
                scheme: b['type'] as String,
                coreVersion: ver,
                applyCoreGates: gates,
                source: BodySource.other,
              );
            }
          });
      out.writeln(
        _row([
          c.key,
          _us(run(_core)),
          _us(run('')),
          _us(run(_core, gates: false)),
        ]),
      );
    }

    // (c) по схемам: один тип на весь набор.
    out.writeln('\n(c) по типам узла');
    out.writeln(_row(['тип', 'батчи+гард', 'гард', 'батчи−гард', 'коды/узел']));
    for (final s in _shapes.entries) {
      final nodes = _nodes([s.value]);
      final full = _best(() => buildProbeBatches(nodes, coreVersion: _core));
      final gate = _bestPrepared(() => [for (final n in nodes) _entriesOf(n)], (
        all,
      ) {
        for (final e in all) {
          applyRegistryGate(e, coreVersion: _core);
        }
      });
      final sample = applyRegistryGate(
        _entriesOf(nodes.first),
        coreVersion: _core,
      );
      out.writeln(
        _row([
          s.key,
          _us(full),
          _us(gate),
          _us(full - gate),
          '${sample.warnings.length}',
        ]),
      );
    }

    // (d) узел с предупреждением: чистый узел после разбора кодов не даёт
    // (разбор уже прошёл санитайзер), поэтому в тело подкладывается чужой
    // ключ — `unknown_key`, одна строка отчёта на узел (гипотеза 4: цена
    // текста кода).
    out.writeln('\n(d) гард на телах с чужим ключом (1 код на узел)');
    out.writeln(_row(['корпус', 'гард', 'чистые', 'разница']));
    for (final c in _corpora.entries) {
      final nodes = _nodes(c.value);
      final clean = _bestPrepared(
        () => [for (final n in nodes) _entriesOf(n)],
        (all) {
          for (final e in all) {
            applyRegistryGate(e, coreVersion: _core);
          }
        },
      );
      final dirty = _bestPrepared(
        () => [for (final n in nodes) _entriesOf(n)..last.map['x_junk'] = 1],
        (all) {
          for (final e in all) {
            applyRegistryGate(e, coreVersion: _core);
          }
        },
      );
      out.writeln(_row([c.key, _us(dirty), _us(clean), _us(dirty - clean)]));
    }

    // ignore: avoid_print
    print(out);

    if (profile) {
      // `LX_PERF_PROFILE_SHAPE=<тип из _shapes>` — профиль одного типа узла
      // вместо §546-набора.
      final shape = Platform.environment['LX_PERF_PROFILE_SHAPE'];
      final nodes = _nodes(
        shape == null ? _corpora['§546 vless']! : [_shapes[shape]!],
      );
      // ignore: avoid_print
      print(
        await vmProfile(
          () => buildProbeBatches(nodes, coreVersion: _core),
          const Duration(seconds: 5),
          tag: '§548',
          unit: 'по $_n узлов',
          probes: _probes,
        ),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

const _n = 2000;

/// Прогонов на замер, берётся лучший. По умолчанию три, как в
/// `engine_perf_test`; `LX_PERF_RUNS` — больше, когда машина шумит (A/B
/// §548 шли с 7).
final _runs = int.tryParse(Platform.environment['LX_PERF_RUNS'] ?? '') ?? 3;

/// Версия ядра — текущий пин (`docs/KERNEL.md`): гейты `min_core` реестра
/// сравниваются с ней, как в боевой сборке.
const _core = '1.14.2-lx.4';

const _pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
const _uuid = '8f2e1c44-0000-4000-8000-0000000000';

/// Шаблоны ссылок; `@I@` — номер узла (уникальные хост и имя, как в живой
/// подписке: одноимённые узлы добавили бы стоимость уникализации тегов).
const _shapes = {
  'vless vision':
      'vless://${_uuid}01@h@I@.example.com:443?security=tls'
      '&sni=h@I@.example.com&fp=chrome&flow=xtls-rprx-vision&type=tcp#v@I@',
  'vless ws':
      'vless://${_uuid}02@h@I@.example.com:443?security=tls'
      '&sni=h@I@.example.com&fp=chrome&type=ws&path=%2Fws&host=h@I@.example.com#w@I@',
  'vless reality grpc':
      'vless://${_uuid}03@h@I@.example.com:443'
      '?security=reality&sni=www.example.org&fp=chrome&pbk=$_pbk&sid=abcd'
      '&type=grpc&serviceName=gsvc#r@I@',
  'trojan':
      'trojan://pass123@h@I@.example.com:443?security=tls'
      '&sni=h@I@.example.com#t@I@',
  'hysteria2 obfs':
      'hysteria2://pass123@h@I@.example.com:443'
      '?sni=h@I@.example.com&obfs=salamander&obfs-password=op#y@I@',
  'shadowsocks': 'ss://YWVzLTI1Ni1nY206dGVzdHBhc3Mx@h@I@.example.com:8388#s@I@',
  'tuic':
      'tuic://22222222-2222-2222-2222-222222222222:tuic-pass'
      '@h@I@.example.com:443?congestion_control=bbr&alpn=h3'
      '&sni=h@I@.example.com#u@I@',
  'wireguard':
      'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA='
      '@h@I@.example.com:51820?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
      '&address=10.0.0.2/32#g@I@',
};

/// §546-набор (vless vision + ws, uTLS) — чтобы сверить с 213/34 мс §546;
/// и разнородный корпус из всех форм по кругу.
final _corpora = {
  '§546 vless': [_shapes['vless vision']!, _shapes['vless ws']!],
  'смешанный': _shapes.values.toList(),
};

List<NodeSpec> _nodes(List<String> templates) {
  final out = <NodeSpec>[];
  for (var i = 0; i < _n; i++) {
    final link = templates[i % templates.length].replaceAll('@I@', '$i');
    final n = parseUri(link);
    if (n == null) throw StateError('не разобралось: $link');
    out.add(n);
  }
  return out;
}

List<SingboxEntry> _entriesOf(NodeSpec n) {
  final raw = n.getEntries(null);
  return <SingboxEntry>[...raw.detours, raw.main];
}

Duration _best(void Function() f) {
  f(); // прогрев: JIT и ленивые кеши реестра
  var best = const Duration(days: 1);
  for (var r = 0; r < _runs; r++) {
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    if (sw.elapsed < best) best = sw.elapsed;
  }
  return best;
}

/// Как [_best], но вход готовится заново на каждый прогон и ВНЕ замера:
/// гард переписывает тела на месте, второй прогон по тем же телам мерил бы
/// уже чистые.
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

/// Точки гипотез §548: что из библиотеки Dart стоит проверить отдельно.
const _probes = [
  'RegExp',
  '_parseCore',
  'coreAtLeast',
  'message',
  'LinkedHashMap.from',
  'Map.from',
  '_JsonStringifier',
  'jsonEncode',
  '_interpolate',
  '_concatAll',
  'CastMap',
  'renderWarningValue',
];
