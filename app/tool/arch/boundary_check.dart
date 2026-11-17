import 'dart:io';

import '../l10n/src/check_common.dart';
import 'src/boundary_scan.dart';

// §742 C — сторож архитектурных границ. Грепом по import/export/part и по
// ссылкам в Kotlin; комментарии не считаются. Каждое правило — объект ниже со
// своим списком исключений «файл → причина». Новое исключение — только с
// причиной и ссылкой на задачу, см. tool/arch/README.md.
//
// Запуск: dart run tool/arch/boundary_check.dart [--strict]  (из app/)
// Без --strict печатает нарушения, но выходит с 0.

const _kotlinRoot = 'android/app/src/main/kotlin/';
const _frozenDebt =
    'долг 740/742: не расширять; файл убирается из списка, когда перестаёт '
    'ходить в мост';

class Rule {
  Rule({
    required this.id,
    required this.description,
    required this.applies,
    required this.check,
    this.allow = const {},
    this.warnStale = false,
  });

  final String id;
  final String description;

  /// Путь относительно app/ → искать ли в этом файле.
  final bool Function(String path) applies;

  /// Строка [i] (код без комментариев) → текст нарушения или null.
  final String? Function(String path, List<String> code, int i) check;

  /// файл (путь от app/) → причина исключения.
  final Map<String, String> allow;

  /// Предупреждать о файле из allow, который больше не нарушает правило.
  final bool warnStale;
}

bool _dart(String p) => p.endsWith('.dart');
bool _kt(String p) => p.endsWith('.kt');
bool _under(String p, String dir) => p.startsWith(dir);

/// Правило «слой A не импортирует слои B».
Rule _layerRule(
  String id,
  List<String> from,
  List<String> forbidden, {
  Map<String, String> allow = const {},
}) {
  return Rule(
    id: id,
    description:
        '${from.map((d) => '$d/').join(', ')} не импортируют '
        '${forbidden.map((d) => '$d/').join(', ')}',
    applies: (p) => _dart(p) && from.any((d) => _under(p, 'lib/$d/')),
    allow: allow,
    check: (p, code, i) {
      final t = importTarget(code[i]);
      if (t == null) return null;
      final layer = layerOf(resolveImport(p, t));
      return layer != null && forbidden.contains(layer) ? 'import $t' : null;
    },
  );
}

const _frozenUiBridge = <String, String>{
  'lib/screens/about_screen.dart': _frozenDebt,
  'lib/screens/app_settings_screen.dart': _frozenDebt,
  'lib/screens/app_settings_screen/widgets/automation_tab.dart': _frozenDebt,
  'lib/screens/backup_screen/restore_flow.dart': _frozenDebt,
  'lib/screens/connection_detail/detail_data.dart': _frozenDebt,
  'lib/screens/connection_detail/detail_sheet.dart': _frozenDebt,
  'lib/screens/connections_screen.dart': _frozenDebt,
  'lib/screens/debug/profiling_tab.dart': _frozenDebt,
  'lib/screens/diagnostics/url_check_tab.dart': _frozenDebt,
  'lib/screens/dns_settings_screen/widgets/merged_server_tile.dart':
      _frozenDebt,
  'lib/screens/dns_settings_tab.dart': _frozenDebt,
  'lib/screens/home/home_dialogs.dart': _frozenDebt,
  'lib/screens/home/node_actions.dart': _frozenDebt,
  'lib/screens/home/openconnect_auth_ui.dart': _frozenDebt,
  'lib/screens/home/startup_wizard.dart': _frozenDebt,
  'lib/screens/home_screen.dart': _frozenDebt,
  'lib/screens/node_settings/exit_node_store.dart': _frozenDebt,
  'lib/screens/node_settings_screen.dart': _frozenDebt,
  'lib/screens/outbound_view_screen.dart': _frozenDebt,
  'lib/screens/probe_gate_mixin.dart': _frozenDebt,
  'lib/screens/speed_test_screen.dart': _frozenDebt,
  'lib/screens/stats_screen.dart': _frozenDebt,
  'lib/screens/stats_screen/memory_detail_sheet.dart': _frozenDebt,
  'lib/widgets/node_diagnostics_tab.dart': _frozenDebt,
  'lib/widgets/node_row.dart': _frozenDebt,
  'lib/widgets/pool_view_dialog.dart': _frozenDebt,
  'lib/widgets/tailscale_network_tab.dart': _frozenDebt,
  'lib/widgets/wg_peers_section.dart': _frozenDebt,
};

String _kbase(String name) => '${_kotlinRoot}com/leadaxe/lxbox/$name';

/// §747 — файлы стороны окна (процесс `:ui`). Нативные окна Taildrop и
/// автоматизации сюда не входят: они живут в `:bg`, рядом с клиентом сервиса.
bool _isKotlinUi(String p) =>
    p == _kbase('MainActivity.kt') ||
    p == _kbase('LanTransferSender.kt') ||
    p == _kbase('vpn/VpnPlugin.kt') ||
    // §745 — клиент ядра роли UI и его держатель.
    p == _kbase('vpn/BoxCommandClient.kt') ||
    p == _kbase('vpn/UiCoreSession.kt') ||
    p == _kbase('vpn/UiSinks.kt') ||
    p == _kbase('vpn/UiLaunchRequests.kt') ||
    // §747 — вызывающая сторона канала окно → сервис.
    p == _kbase('vpn/BgClient.kt') ||
    p == _kbase('vpn/WifiNetworkObserver.kt') ||
    _under(p, _kbase('editor/'));

const _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const _manifestRuleId = 'manifest-process';
const _manifestRuleDescription =
    'каждый компонент исходного манифеста (кроме activity-alias) несёт '
    'android:process ":ui" или ":bg"';

final _vpnPluginRe = RegExp(r'\bVpnPlugin\b');
final _uiCoreSessionRe = RegExp(r'\bUiCoreSession\b');

/// §745 C — кто обращается к каким полям `UiSinks`: файл → разрешённые поля
/// (null — любые). Файл вне списка к `UiSinks` не обращается.
final _uiSinksUsers = <String, Set<String>?>{
  _kbase('vpn/VpnPlugin.kt'): null,
  _kbase('vpn/BoxCommandClient.kt'): null,
  // §747 — initUiSide отдаёт клиенту окна приёмник журнала; сервисная
  // сторона к UiSinks не обращается вовсе (лог идёт через pipe, openconnect —
  // событием).
  _kbase('vpn/BoxApplication.kt'): {'appLogWarning'},
};
final _automationBridgeRe = RegExp(r'(?<![A-Za-z0-9_])AutomationBridge\b');
final _eventSinkRe = RegExp(r'\bEventSink\b');
final _sharedPrefsRe = RegExp(r'\bgetSharedPreferences\(');
final _removedRe = RegExp(
  r'\bBoxVpnService\.(?:currentStatus|currentRevoked|tunnelStartedElapsedMs|currentSessionAllowBypass)\b|\bBoxService\.commandClient\b',
);

final rules = <Rule>[
  _layerRule(
    'dart-layer-core',
    ['services', 'models', 'config'],
    ['screens', 'widgets'],
    allow: {
      'lib/services/debug/handlers/taildrop.dart':
          'Debug API читает exit_node_store экрана (единственное исключение '
          'по спеке 742; снять при выносе стора из screens/)',
    },
  ),
  _layerRule('dart-layer-vpn', ['vpn'], ['controllers', 'screens', 'widgets']),
  _layerRule('dart-layer-controllers', ['controllers'], ['screens', 'widgets']),
  Rule(
    id: 'dart-channel-literal',
    description:
        'MethodChannel/EventChannel/BasicMessageChannel со строковым '
        'литералом имени — только в vpn/platform_channels.dart',
    applies: (p) => _dart(p) && _under(p, 'lib/'),
    allow: const {'lib/vpn/platform_channels.dart': 'реестр имён каналов'},
    check: (p, code, i) =>
        isChannelLiteral(code, i) ? 'литерал имени канала' : null,
  ),
  Rule(
    id: 'dart-ui-bridge-frozen',
    description:
        'screens/ и widgets/ не получают новых импортов '
        'vpn/box_vpn_client.dart и vpn/cc_channel.dart (список заморожен)',
    applies: (p) =>
        _dart(p) && (_under(p, 'lib/screens/') || _under(p, 'lib/widgets/')),
    allow: _frozenUiBridge,
    warnStale: true,
    check: (p, code, i) {
      final t = importTarget(code[i]);
      if (t == null) return null;
      final r = resolveImport(p, t);
      return r == 'lib/vpn/box_vpn_client.dart' ||
              r == 'lib/vpn/cc_channel.dart'
          ? 'import $t'
          : null;
    },
  ),
  Rule(
    id: 'kt-vpnplugin-ref',
    description:
        'VpnPlugin упоминается только в VpnPlugin.kt и MainActivity.kt',
    applies: _kt,
    allow: {
      _kbase('vpn/VpnPlugin.kt'): 'сам класс',
      _kbase('MainActivity.kt'): 'регистрирует плагин в configureFlutterEngine',
    },
    check: (p, code, i) =>
        // Строковые литералы (тег лога "VpnPlugin") не ссылка на класс.
        _vpnPluginRe.hasMatch(code[i].replaceAll(RegExp(r'"[^"]*"'), '""'))
        ? 'ссылка на VpnPlugin'
        : null,
  ),
  Rule(
    id: 'kt-eventsink-type',
    description:
        'EventSink как тип поля/параметра — только UiSinks.kt, '
        'VpnPlugin.kt и CommandClientShared.kt (эмиттеры)',
    applies: _kt,
    allow: {
      _kbase('vpn/UiSinks.kt'): 'держатель приёмников UI',
      _kbase('vpn/VpnPlugin.kt'): 'onListen/onCancel и локальный statusSink',
      _kbase('vpn/CommandClientShared.kt'):
          'существующее, разобрать: SnapshotEmitter/EventEmitter принимают '
          'sinkProvider: () -> EventSink? (общие для двух клиентов, §745)',
    },
    check: (p, code, i) =>
        _eventSinkRe.hasMatch(code[i]) ? 'тип EventSink' : null,
  ),
  Rule(
    id: 'kt-ui-service-side',
    description:
        'файлы стороны окна (:ui — VpnPlugin, MainActivity, BoxCommandClient, '
        'UiCoreSession, UiSinks, BgClient, editor/ …) не трогают сервисную '
        'сторону (:bg): CoreSession, ServiceCommandClient, BootReceiver, '
        'NativeCache, AutomationCache, Taildrop*, ConfigManager, BoxService, '
        'BgMethods и др.; из BoxVpnService — только константы',
    applies: _isKotlinUi,
    check: (p, code, i) => uiServiceSideUse(code[i]),
  ),
  Rule(
    id: 'kt-automationbridge-ref',
    description:
        'AutomationBridge (канал Dart) упоминается только в '
        'AutomationBridge.kt и VpnPlugin.kt — сервисная сторона шлёт команды '
        'через AutomationRelay',
    applies: _kt,
    allow: {
      _kbase('vpn/AutomationBridge.kt'): 'сам мост и AutomationRelay',
      _kbase('vpn/VpnPlugin.kt'): 'ставит канал и принимает событие из :bg',
    },
    check: (p, code, i) => _automationBridgeRe.hasMatch(code[i])
        ? 'ссылка на AutomationBridge'
        : null,
  ),
  Rule(
    id: 'kt-uicoresession-ref',
    description:
        'UiCoreSession упоминается только в UiCoreSession.kt, VpnPlugin.kt '
        'и BoxApplication.kt — сервисная сторона о клиенте UI не знает',
    applies: _kt,
    allow: {
      _kbase('vpn/UiCoreSession.kt'): 'сам держатель',
      _kbase('vpn/VpnPlugin.kt'): 'единственный вызывающий клиента UI',
      _kbase('vpn/BoxApplication.kt'): 'initUiSide: приёмник журнала клиента',
    },
    check: (p, code, i) =>
        _uiCoreSessionRe.hasMatch(code[i]) ? 'ссылка на UiCoreSession' : null,
  ),
  Rule(
    id: 'kt-uisinks-member',
    description:
        'UiSinks: VpnPlugin.kt и BoxCommandClient.kt — любые поля, '
        'BoxApplication.kt — appLogWarning, остальные файлы (вся сервисная '
        'сторона) — никаких',
    applies: (p) => _kt(p) && p != _kbase('vpn/UiSinks.kt'),
    check: (p, code, i) {
      final members = uiSinksMembers(code[i]);
      if (members.isEmpty) return null;
      if (!_uiSinksUsers.containsKey(p)) return 'UiSinks.${members.first}';
      final ok = _uiSinksUsers[p];
      if (ok == null) return null;
      for (final m in members) {
        if (!ok.contains(m)) return 'UiSinks.$m';
      }
      return null;
    },
  ),
  Rule(
    id: 'kt-sharedprefs',
    description:
        'getSharedPreferences( — только BootReceiver.kt, '
        'NativeCache.kt, AutomationCache.kt',
    applies: _kt,
    allow: {
      _kbase('vpn/BootReceiver.kt'): 'читает настройки до запуска UI',
      _kbase('vpn/NativeCache.kt'): 'нативный кэш настроек',
      _kbase('vpn/AutomationCache.kt'): 'кэш состояния автоматизации',
    },
    check: (p, code, i) =>
        _sharedPrefsRe.hasMatch(code[i]) ? 'getSharedPreferences(' : null,
  ),
  Rule(
    id: 'removed-fields',
    description:
        'удалённые поля BoxVpnService.(currentStatus|currentRevoked|'
        'tunnelStartedElapsedMs|currentSessionAllowBypass) и '
        'BoxService.commandClient не встречаются',
    applies: (p) => _kt(p) || (_dart(p) && _under(p, 'lib/')),
    check: (p, code, i) => _removedRe.firstMatch(code[i])?.group(0),
  ),
];

List<File> _walk(String dir, String ext) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith(ext))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main(List<String> args) {
  ensureAppCwd();
  final strict = parseStrict(args);

  final files = <String, List<String>>{};
  for (final f in [..._walk('lib', '.dart'), ..._walk(_kotlinRoot, '.kt')]) {
    files[f.path.replaceAll(r'\', '/')] = stripComments(f.readAsLinesSync());
  }

  final violations = <String, List<String>>{for (final r in rules) r.id: []};
  final warnings = <String>[];
  for (final r in rules) {
    final hit = <String>{};
    for (final e in files.entries) {
      if (!r.applies(e.key)) continue;
      for (var i = 0; i < e.value.length; i++) {
        final msg = r.check(e.key, e.value, i);
        if (msg == null) continue;
        if (r.allow.containsKey(e.key)) {
          hit.add(e.key);
          continue;
        }
        violations[r.id]!.add('${e.key}:${i + 1} [${r.id}] $msg');
      }
    }
    if (r.warnStale) {
      for (final f in r.allow.keys) {
        if (!hit.contains(f)) {
          warnings.add(
            '$f [${r.id}] больше не нарушает правило — убери из '
            'списка исключений',
          );
        }
      }
    }
  }

  // §747 F — правило не построчное: исходный манифест целиком.
  final manifest = File(_manifestPath);
  final manifestViolations = <String>[
    if (!manifest.existsSync())
      '$_manifestPath [$_manifestRuleId] файл не найден'
    else
      for (final v in manifestProcessViolations(manifest.readAsStringSync()))
        '$_manifestPath [$_manifestRuleId] $v',
  ];
  var total = 0;
  for (final r in rules) {
    for (final v in violations[r.id]!) {
      stdout.writeln('FAIL: $v');
    }
    total += violations[r.id]!.length;
  }
  for (final v in manifestViolations) {
    stdout.writeln('FAIL: $v');
  }
  total += manifestViolations.length;
  for (final w in warnings) {
    stdout.writeln('warn: $w');
  }
  stdout.writeln(
    '[boundary_check] violations: $total, warnings: '
    '${warnings.length}',
  );
  for (final r in rules) {
    stdout.writeln(
      '  ${violations[r.id]!.length.toString().padLeft(3)}  '
      '[${r.id}] ${r.description}',
    );
  }
  stdout.writeln(
    '  ${manifestViolations.length.toString().padLeft(3)}  '
    '[$_manifestRuleId] $_manifestRuleDescription',
  );
  appendStepSummary(
    '### boundary_check\n\nviolations: $total, '
    'warnings: ${warnings.length}\n',
  );
  exit(strict && total > 0 ? 1 : 0);
}
