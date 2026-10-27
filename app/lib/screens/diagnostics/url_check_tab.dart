import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/home_controller.dart';
import '../../services/app_info_cache.dart';
import '../../services/diagnostics/connection_test.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/ui_helpers.dart';
import '../../vpn/cc_channel.dart';
import '../../widgets/banner_palette.dart';
import '../../widgets/safe_bottom.dart';
import '../app_picker_screen.dart';

/// §687 — вкладка URL Check: активный тест соединения ядра (kernel SPEC 139)
/// через роутер. Дерево стадий приходит потоком; один тест за раз.
class UrlCheckTab extends StatefulWidget {
  const UrlCheckTab({super.key, required this.homeController});

  final HomeController homeController;

  @override
  State<UrlCheckTab> createState() => _UrlCheckTabState();
}

class _UrlCheckTabState extends State<UrlCheckTab>
    with SnackHelper, AutomaticKeepAliveClientMixin {
  final _cc = CcChannel.instance;
  final _urlCtrl = TextEditingController();
  StreamSubscription<ConnectionTestEvent>? _sub;

  String _packageName = '';
  ConnectionTestDepth _depth = ConnectionTestDepth.http;
  bool _fresh = false;
  String? _urlError;

  ConnectionTestTrace? _trace;
  String _runLink = '';
  ConnectionTestDepth _runDepth = ConnectionTestDepth.http;
  String _runApp = '';
  bool _running = false;

  /// Стадии, которые пользователь переключил против умолчания [_autoOpen].
  final Set<int> _toggled = {};

  /// Стадии находки, на которую нажали: подсвечены и раскрыты.
  Set<int> _focus = const {};

  @override
  bool get wantKeepAlive => true;

  bool get _tunnelUp => widget.homeController.state.tunnelUp;

  @override
  void initState() {
    super.initState();
    widget.homeController.addListener(_onHome);
  }

  @override
  void dispose() {
    widget.homeController.removeListener(_onHome);
    _stop();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _onHome() {
    if (!mounted) return;
    // Туннель упал во время теста — тест прерван вместе с ядром.
    if (!_tunnelUp && _running) _stop();
    setState(() {});
  }

  Future<void> _run() async {
    final link = normalizeCheckUrl(_urlCtrl.text);
    if (link == null) {
      setState(() => _urlError = getLocalText.s("Enter an http or https URL"));
      return;
    }
    FocusScope.of(context).unfocus();
    _stop();
    final trace = ConnectionTestTrace();
    setState(() {
      _urlError = null;
      _trace = trace;
      _runLink = link;
      _runDepth = _depth;
      _runApp = _packageName;
      _running = true;
      _toggled.clear();
      _focus = const {};
    });
    _sub = _cc.connectionTest.listen((e) {
      if (!mounted || !identical(_trace, trace)) return;
      setState(() {
        trace.apply(e);
        if (trace.finished) _running = false;
      });
      if (trace.finished) _sub?.cancel();
    });
    final ok = await _cc.startConnectionTest(
      link: link,
      packageName: _packageName,
      depth: _depth,
      fresh: _fresh,
    );
    if (!ok && mounted && identical(_trace, trace)) {
      setState(() {
        trace.transportError = getLocalText.s("VPN is not running");
        _running = false;
      });
      _sub?.cancel();
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (_running) {
      _cc.stopConnectionTest();
      _running = false;
    }
  }

  Future<void> _pickApp() async {
    final res = await Navigator.of(context).push<AppPickerResult>(
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(
          selected: {if (_packageName.isNotEmpty) _packageName},
        ),
      ),
    );
    if (res == null || !mounted) return;
    // Пикер множественный: берём добавленное, иначе единственное оставшееся.
    final added = res.packages.where((p) => p != _packageName).toList();
    setState(() {
      _packageName = added.isNotEmpty
          ? added.last
          : (res.packages.isEmpty ? '' : res.packages.first);
    });
  }

  String _appLabel(String pkg) {
    AppInfoCache.ensure(pkg);
    final info = AppInfoCache.of(pkg);
    return (info == null || info.appName.isEmpty) ? pkg : info.appName;
  }

  Future<void> _copy() async {
    final t = _trace;
    if (t == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: traceToText(t, link: _runLink, app: _runApp, depth: _runDepth),
      ),
    );
    showSnack(getLocalText.s("Copied to clipboard"));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final trace = _trace;
    final rows = trace?.rows() ?? const <TraceRow>[];
    return ListView(
      padding: const EdgeInsets.all(16).withSafeBottom(context),
      children: [
        TextField(
          controller: _urlCtrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) {
            if (_tunnelUp && !_running) _run();
          },
          onChanged: (_) => setState(() => _urlError = null),
          decoration: InputDecoration(
            suffixIcon: _urlCtrl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: getLocalText.s("Clear"),
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(_urlCtrl.clear),
                  ),
            labelText: getLocalText.s("URL"),
            hintText: getLocalText.s("example.com or https://…"),
            errorText: _urlError,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              getLocalText.s("App"),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _packageName.isEmpty
                    ? TextButton.icon(
                        onPressed: _running ? null : _pickApp,
                        icon: const Icon(Icons.apps, size: 18),
                        label: Text(getLocalText.s("Any app")),
                      )
                    : InputChip(
                        label: Text(
                          _appLabel(_packageName),
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: _running ? null : _pickApp,
                        onDeleted: _running
                            ? null
                            : () => setState(() => _packageName = ''),
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<ConnectionTestDepth>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ConnectionTestDepth.http,
              label: Text(getLocalText.s("Full")),
            ),
            ButtonSegment(
              value: ConnectionTestDepth.connect,
              label: Text(getLocalText.s("Connect")),
            ),
            ButtonSegment(
              value: ConnectionTestDepth.route,
              label: Text(getLocalText.s("Route")),
            ),
            ButtonSegment(
              value: ConnectionTestDepth.dns,
              label: Text(getLocalText.s("DNS")),
            ),
          ],
          selected: {_depth},
          onSelectionChanged:
              _running ? null : (s) => setState(() => _depth = s.first),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("From scratch")),
          subtitle: Text(
            getLocalText.s("Bypass DNS cache and open new connections"),
          ),
          value: _fresh,
          onChanged: _running ? null : (v) => setState(() => _fresh = v),
        ),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed:
              _running ? () => setState(_stop) : (_tunnelUp ? _run : null),
          icon: Icon(_running ? Icons.stop : Icons.play_arrow),
          label: Text(
            _running ? getLocalText.s("Stop") : getLocalText.s("Run"),
          ),
        ),
        if (!_tunnelUp && !_running)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              getLocalText.s("Start VPN to run a check"),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        if (trace != null) ...[
          const SizedBox(height: 16),
          _summary(context, trace),
          for (final f in trace.result?.findings ?? const <TestFinding>[])
            _finding(context, f),
          const SizedBox(height: 8),
          for (final row in rows) _stageRow(context, trace, row),
        ],
      ],
    );
  }

  Widget _summary(BuildContext context, ConnectionTestTrace t) {
    final r = t.result;
    final root = t.rootStage;
    late final BannerSeverity sev;
    late final String text;
    if (t.transportError.isNotEmpty) {
      sev = BannerSeverity.error;
      text = t.transportError;
    } else if (r == null) {
      sev = BannerSeverity.info;
      text = _running ? getLocalText.s("Running…") : getLocalText.s("Stopped");
    } else if (r.error.isNotEmpty) {
      sev = BannerSeverity.error;
      text = r.error == 'busy'
          ? getLocalText.s("Too many checks running, try again")
          : r.error;
    } else if (root != null) {
      sev = BannerSeverity.error;
      text = getLocalText.s(
        "Failed at %s: %s",
        '${root.kind} ${root.subject}'.trim(), // l10n-exempt: core identifiers
        root.error,
      );
    } else {
      sev = BannerSeverity.success;
      text = _runDepth == ConnectionTestDepth.http
          ? getLocalText.s("HTTP %d · %d ms", r.httpStatus, r.elapsedMs)
          : getLocalText.s("Completed · %d ms", r.elapsedMs);
    }
    final truncated = r?.stagesTruncated == true;
    final color = bannerIconColor(context, sev);
    return Row(
      children: [
        Icon(
            switch (sev) {
              BannerSeverity.success => Icons.check_circle,
              BannerSeverity.error => Icons.error,
              _ => _running ? Icons.hourglass_top : Icons.stop_circle_outlined,
            },
            color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            truncated ? '$text · ${getLocalText.s("trace truncated")}' : text,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: color),
          ),
        ),
        IconButton(
          tooltip: getLocalText.s("Copy"),
          icon: const Icon(Icons.copy, size: 20),
          onPressed: t.isEmpty ? null : _copy,
        ),
      ],
    );
  }

  Widget _finding(BuildContext context, TestFinding f) {
    final sev = switch (f.level) {
      FindingLevel.problem => BannerSeverity.error,
      FindingLevel.warning => BannerSeverity.warning,
      FindingLevel.info => BannerSeverity.info,
    };
    final text = findingText(f.code);
    final attrs = f.attrs.map((a) => '${a.key}=${a.value}').join(', ');
    final ids = f.stages.toSet();
    final focused = ids.isNotEmpty &&
        _focus.length == ids.length &&
        _focus.containsAll(ids);
    return InkWell(
      onTap: ids.isEmpty
          ? null
          : () => setState(() => _focus = focused ? const {} : ids),
      child: Container(
        color: focused
            ? Theme.of(
                context,
              ).colorScheme.tertiaryContainer.withValues(alpha: 0.5)
            : null,
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              switch (sev) {
                BannerSeverity.error => Icons.report,
                BannerSeverity.warning => Icons.warning_amber,
                _ => Icons.info_outline,
              },
              size: 18,
              color: bannerIconColor(context, sev),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: text ?? f.code),
                    if (attrs.isNotEmpty)
                      TextSpan(
                        text: '\n$attrs',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Раскрыта ли стадия без тапа: корневая причина, пустой или ошибочный
  /// ответ DNS приложения, стадии выбранной находки.
  bool _autoOpen(ConnectionTestTrace t, TestStage s) {
    if (s.id != 0 && t.result?.rootCause == s.id) return true;
    if (_focus.contains(s.id)) return true;
    if (s.kind == 'app_dns' && s.result != StageResult.running) {
      final rcode = s.attr('rcode');
      if (rcode.isNotEmpty && rcode != 'NOERROR') return true;
      if (rcode == 'NOERROR' && _answers(s).isEmpty) return true;
    }
    return false;
  }

  /// Записи ответа DNS приложения: атрибут `answer` по одной (ядро SPEC 139
  /// релиз 2). У стадии `dns` атрибут `answers` — число записей, не список.
  static List<String> _answers(TestStage s) => s.attrsOf('answer');

  static const _shownApart = {
    'answer',
    'authority',
    'source',
    'cache_age',
    'stale',
    'type',
  };

  Widget _stageRow(BuildContext context, ConnectionTestTrace t, TraceRow row) {
    final s = row.stage;
    final cs = Theme.of(context).colorScheme;
    final isRoot = t.result?.rootCause == s.id && s.id != 0;
    final auto = _autoOpen(t, s);
    final open = auto != _toggled.contains(s.id);
    final small = Theme.of(context).textTheme.bodySmall;
    final mono = small?.copyWith(fontFamily: 'monospace');
    final muted = small?.copyWith(color: cs.onSurfaceVariant);
    final rcode = s.attr('rcode');
    final badRcode = rcode.isNotEmpty && rcode != 'NOERROR';
    final details =
        open ? _details(context, t, s, mono, muted) : const <Widget>[];
    return InkWell(
      onTap: () => setState(
        () => _toggled.contains(s.id)
            ? _toggled.remove(s.id)
            : _toggled.add(s.id),
      ),
      child: Container(
        color: isRoot
            ? cs.errorContainer.withValues(alpha: 0.5)
            : _focus.contains(s.id)
                ? cs.tertiaryContainer.withValues(alpha: 0.5)
                : null,
        child: CustomPaint(
          painter: _TreeLinesPainter(
            lastPath: row.lastPath,
            color: cs.outlineVariant,
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: _TreeLinesPainter.indent(row.depth),
              right: 4,
              top: 4,
              bottom: 4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _resultIcon(context, s.result),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: s.kind,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            // Тип DNS-запроса (A/AAAA/HTTPS) — в строке: без него
                            // три app_dns одного домена неразличимы.
                            if (s.attr('type').isNotEmpty)
                              TextSpan(
                                text: ' ${s.attr('type')}',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            if (s.subject.isNotEmpty)
                              TextSpan(text: '  ${s.subject}'),
                            if (badRcode)
                              TextSpan(
                                text: '  $rcode',
                                style: TextStyle(color: cs.error),
                              ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: open ? 4 : 1,
                      ),
                    ),
                    if (s.durationMs > 0)
                      Text(
                        // l10n-exempt: unit
                        '${s.durationMs} ms',
                        style: muted,
                      ),
                    Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
                for (final w in details)
                  Padding(
                    padding: const EdgeInsets.only(left: 22, top: 2),
                    child: w,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Тело раскрытой стадии (§688): что за шаг, почему такой исход, откуда
  /// ответ DNS, записи ответа и authority, прочие атрибуты, ошибка.
  List<Widget> _details(
    BuildContext context,
    ConnectionTestTrace t,
    TestStage s,
    TextStyle? mono,
    TextStyle? muted,
  ) {
    final cs = Theme.of(context).colorScheme;
    final out = <Widget>[];
    final about = stageKindText(s.kind);
    if (about != null) out.add(Text(about, style: muted));
    final why = _resultNote(t, s);
    if (why != null) out.add(Text(why, style: muted));
    final source = _sourceText(s);
    if (source != null) out.add(Text(source, style: muted));
    final answers = _answers(s);
    if (answers.isNotEmpty) {
      out.add(Text(getLocalText.s("Answer"), style: muted));
      for (final a in answers) {
        out.add(SelectableText(a, style: mono));
      }
    } else if (s.kind == 'app_dns' && s.attr('rcode') == 'NOERROR') {
      out.add(Text(getLocalText.s("No records"), style: muted));
    }
    final authority = s.attrsOf('authority');
    if (authority.isNotEmpty) {
      out.add(Text(getLocalText.s("Authority"), style: muted));
      for (final a in authority) {
        out.add(SelectableText(a, style: mono));
      }
    }
    for (final a in s.attrs) {
      if (_shownApart.contains(a.key)) continue;
      out.add(SelectableText('${a.key}: ${a.value}', style: mono));
    }
    if (s.error.isNotEmpty) {
      out.add(SelectableText(s.error, style: mono?.copyWith(color: cs.error)));
    }
    return out;
  }

  String? _resultNote(ConnectionTestTrace t, TestStage s) {
    switch (s.result) {
      case StageResult.skipped:
        final root = t.rootStage;
        if (root == null || root.id == s.id) return getLocalText.s("Not run");
        return getLocalText.s(
          "Not run: %s failed",
          '${root.kind} ${root.subject}'.trim(),
        );
      case StageResult.reused:
        return getLocalText.s("Reused: an open connection or a cached answer");
      case StageResult.noAck:
        return getLocalText.s("Sent; the protocol gives no confirmation");
      case StageResult.notEvaluated:
        return getLocalText.s("Not evaluated");
      default:
        return null;
    }
  }

  String? _sourceText(TestStage s) {
    switch (s.attr('source')) {
      case 'network':
        return getLocalText.s("From the network");
      case 'cache':
        final age = int.tryParse(s.attr('cache_age'));
        final text = age == null
            ? getLocalText.s("From cache")
            : getLocalText.s("From cache, %d s old", age);
        return s.attr('stale') == 'true'
            ? '$text · ${getLocalText.s("expired, refreshing")}'
            : text;
      case 'local':
        return getLocalText.s("Local answer: fake IP or hosts");
      default:
        return null;
    }
  }

  Widget _resultIcon(BuildContext context, StageResult r) {
    final cs = Theme.of(context).colorScheme;
    // Тест остановлен или оборван: незавершённая стадия больше не идёт.
    if (r == StageResult.running && !_running) {
      return Tooltip(
        message: getLocalText.s("Stopped"),
        child: Icon(Icons.stop_circle_outlined, size: 16, color: cs.outline),
      );
    }
    if (r == StageResult.running) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final (icon, color, tip) = switch (r) {
      StageResult.ok => (
          Icons.check,
          bannerIconColor(context, BannerSeverity.success),
          getLocalText.s("OK"),
        ),
      StageResult.failed => (Icons.close, cs.error, getLocalText.s("Failed")),
      StageResult.skipped => (
          Icons.remove,
          cs.outline,
          getLocalText.s("Skipped"),
        ),
      StageResult.reused => (
          Icons.replay,
          cs.primary,
          getLocalText.s("Reused"),
        ),
      StageResult.noAck => (
          Icons.help_outline,
          bannerIconColor(context, BannerSeverity.warning),
          getLocalText.s("Sent, not confirmed"),
        ),
      _ => (Icons.block, cs.outline, getLocalText.s("Not evaluated")),
    };
    return Tooltip(
      message: tip,
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// §688 — одна строка о том, что за шаг, по `kind` ядра (SPEC 139 §4);
/// null — kind неизвестен (словарь ядра открыт), строки нет.
String? stageKindText(String kind) => switch (kind) {
      'app_dns' => getLocalText.s("DNS query the app makes for the site"),
      'route' => getLocalText.s(
          "Routing rule match: which outbound takes the connection",
        ),
      'group' => getLocalText.s("Node selection inside a group"),
      'chain' => getLocalText.s("Chain unfolded into its nodes"),
      'dial' => getLocalText.s("Connection through a node"),
      'detour' =>
        getLocalText.s("Hand-off to the detour that carries this node"),
      'lookup' => getLocalText.s(
          "Resolving the server address of a node or DNS server",
        ),
      'dns' => getLocalText.s("Query to a DNS server"),
      'wake' => getLocalText.s("Waking an endpoint that was idle-suspended"),
      'tcp_connect' => getLocalText.s("TCP connection to the server"),
      'quic' => getLocalText.s("QUIC connection to the server"),
      'tls' => getLocalText.s("TLS handshake with the server"),
      'reality' => getLocalText.s(
          "REALITY check: did the server recognize the client",
        ),
      'transport' => getLocalText.s(
          "Transport over TLS: WS, gRPC, XHTTP, HTTPUpgrade or H2",
        ),
      'auth' => getLocalText.s(
          "Authentication: the server confirms the credentials",
        ),
      'wg_handshake' => getLocalText.s("WireGuard handshake with the peer"),
      'proxy_header' => getLocalText.s(
          "Protocol header to the server; this protocol sends no confirmation",
        ),
      'target_tls' => getLocalText.s(
          "TLS with the site itself, through the tunnel",
        ),
      'first_byte' => getLocalText.s("First bytes of the site's response"),
      'http' => getLocalText.s("HTTP response of the site"),
      _ => null,
    };

/// §688 — линии дерева слева от строки стадии: вертикаль у предков, у
/// которых ниже есть ещё братья, уголок у самой строки. Высота строки любая
/// (раскрытая выше): вертикали тянутся на всю высоту и стыкуются с соседями.
class _TreeLinesPainter extends CustomPainter {
  _TreeLinesPainter({required this.lastPath, required this.color});

  final List<bool> lastPath;
  final Color color;

  static const double _step = 14;
  static const double _base = 4;

  /// Отступ содержимого строки глубины [depth].
  static double indent(int depth) => _base + depth * _step;

  /// Середина значка исхода по вертикали (top padding 4 + половина 16).
  static const double _elbowY = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final depth = lastPath.length - 1;
    if (depth <= 0) return;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    // Колонка уровня i стоит под значком предка уровня i.
    double col(int i) => _base + i * _step + 7;
    for (var i = 1; i < depth; i++) {
      if (!lastPath[i]) {
        canvas.drawLine(
          Offset(col(i - 1), 0),
          Offset(col(i - 1), size.height),
          p,
        );
      }
    }
    final x = col(depth - 1);
    final last = lastPath[depth];
    canvas.drawLine(Offset(x, 0), Offset(x, last ? _elbowY : size.height), p);
    canvas.drawLine(Offset(x, _elbowY), Offset(indent(depth) - 2, _elbowY), p);
  }

  @override
  bool shouldRepaint(_TreeLinesPainter old) =>
      old.color != color || !_sameList(old.lastPath, lastPath);

  static bool _sameList(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// §687 — текст находки по коду ядра (SPEC 139 §6); null — код неизвестен,
/// показывается как есть.
String? findingText(String code) => switch (code) {
      'excluded_from_vpn' => getLocalText.s(
          "This app does not go through the VPN. The path shown is hypothetical",
        ),
      'resolve_via_rules_in_source_context' => getLocalText.s(
          "The server address is resolved by DNS rules for this app; for another app the path may differ",
        ),
      'dependency_outside_route' => getLocalText.s(
          "The path depends on a server that is not on the route",
        ),
      'resolve_cycle' => getLocalText.s(
          "Resolve cycle: a server address is resolved through itself",
        ),
      'ip_rules_not_evaluated' => getLocalText.s(
          "IP rules were not evaluated: the address is unknown",
        ),
      'fakeip_not_persisted' => getLocalText.s(
          "Fake IP is not kept across restarts: apps with cached addresses fail after a restart",
        ),
      'fakeip_pool_wrapped' => getLocalText.s(
          "The fake IP pool wraps faster than the answer TTL: an old address may now belong to another domain",
        ),
      'fakeip_unknown_address' => getLocalText.s(
          "The address is in the fake IP range but has no record",
        ),
      'fakeip_address_reassigned' => getLocalText.s(
          "The address now belongs to another domain",
        ),
      'fakeip_ipv6_without_tun_ipv6' => getLocalText.s(
          "IPv6 fake IP is returned, but the tunnel has no IPv6 address",
        ),
      'https_query_rejected' => getLocalText.s(
          "HTTPS DNS queries are rejected: no ECH and no ALPN hints for the app",
        ),
      'quic_rejected' => getLocalText.s(
          "UDP 443 is rejected: browsers fall back to TCP",
        ),
      'reality_not_recognized' => getLocalText.s(
          "The REALITY server did not recognize the client: check public key, short ID, server name",
        ),
      'failed_after_no_ack' => getLocalText.s(
          "The connection broke after an unconfirmed step: wrong UUID or password, the server cannot reach the target, or large packets are lost",
        ),
      'partially_reused' => getLocalText.s(
          "Some steps were reused: this does not prove the path comes up from scratch",
        ),
      _ => null,
    };
