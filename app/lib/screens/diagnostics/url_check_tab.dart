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
  final Set<int> _expanded = {};

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
      _expanded.clear();
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
    await Clipboard.setData(ClipboardData(
      text: traceToText(t, link: _runLink, app: _runApp, depth: _runDepth),
    ));
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
          decoration: InputDecoration(
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
            Text(getLocalText.s("App"),
                style: Theme.of(context).textTheme.bodyMedium),
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
                        label: Text(_appLabel(_packageName),
                            overflow: TextOverflow.ellipsis),
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
                label: Text(getLocalText.s("Full"))),
            ButtonSegment(
                value: ConnectionTestDepth.connect,
                label: Text(getLocalText.s("Connect"))),
            ButtonSegment(
                value: ConnectionTestDepth.route,
                label: Text(getLocalText.s("Route"))),
            ButtonSegment(
                value: ConnectionTestDepth.dns,
                label: Text(getLocalText.s("DNS"))),
          ],
          selected: {_depth},
          onSelectionChanged:
              _running ? null : (s) => setState(() => _depth = s.first),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("From scratch")),
          subtitle: Text(getLocalText.s("Bypass DNS cache and open new connections")),
          value: _fresh,
          onChanged: _running ? null : (v) => setState(() => _fresh = v),
        ),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: _running
              ? () => setState(_stop)
              : (_tunnelUp ? _run : null),
          icon: Icon(_running ? Icons.stop : Icons.play_arrow),
          label: Text(_running
              ? getLocalText.s("Stop")
              : getLocalText.s("Run")),
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
            _ => Icons.hourglass_top,
          },
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            truncated
                ? '$text · ${getLocalText.s("trace truncated")}'
                : text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: color),
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
    return Padding(
      padding: const EdgeInsets.only(top: 4),
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
            child: Text.rich(TextSpan(children: [
              TextSpan(text: text ?? f.code),
              if (attrs.isNotEmpty)
                TextSpan(
                  text: '\n$attrs',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ])),
          ),
        ],
      ),
    );
  }

  Widget _stageRow(BuildContext context, ConnectionTestTrace t, TraceRow row) {
    final s = row.stage;
    final cs = Theme.of(context).colorScheme;
    final isRoot = t.result?.rootCause == s.id && s.id != 0;
    final open = _expanded.contains(s.id);
    final hasDetails = s.attrs.isNotEmpty || s.error.isNotEmpty;
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
        );
    return InkWell(
      onTap: hasDetails
          ? () => setState(() => open ? _expanded.remove(s.id) : _expanded.add(s.id))
          : null,
      child: Container(
        color: isRoot ? cs.errorContainer.withValues(alpha: 0.5) : null,
        padding: EdgeInsets.only(
          left: 4.0 + row.depth * 14,
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
                    TextSpan(children: [
                      TextSpan(
                        text: s.kind,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (s.subject.isNotEmpty) TextSpan(text: '  ${s.subject}'),
                    ]),
                    overflow: TextOverflow.ellipsis,
                    maxLines: open ? 4 : 1,
                  ),
                ),
                if (s.durationMs > 0 || s.result != StageResult.running)
                  Text(
                    // l10n-exempt: unit
                    '${s.durationMs} ms',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
            if (open) ...[
              for (final a in s.attrs)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 2),
                  child: SelectableText('${a.key}: ${a.value}', style: mono),
                ),
              if (s.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 2),
                  child: SelectableText(
                    s.error,
                    style: mono?.copyWith(color: cs.error),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _resultIcon(BuildContext context, StageResult r) {
    final cs = Theme.of(context).colorScheme;
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
      StageResult.failed => (
          Icons.close,
          cs.error,
          getLocalText.s("Failed"),
        ),
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
      _ => (
          Icons.block,
          cs.outline,
          getLocalText.s("Not evaluated"),
        ),
    };
    return Tooltip(
      message: tip,
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// §687 — текст находки по коду ядра (SPEC 139 §6); null — код неизвестен,
/// показывается как есть.
String? findingText(String code) => switch (code) {
      'excluded_from_vpn' => getLocalText.s(
          "This app does not go through the VPN. The path shown is hypothetical"),
      'resolve_via_rules_in_source_context' => getLocalText.s(
          "The server address is resolved by DNS rules for this app; for another app the path may differ"),
      'dependency_outside_route' => getLocalText
          .s("The path depends on a server that is not on the route"),
      'resolve_cycle' => getLocalText
          .s("Resolve cycle: a server address is resolved through itself"),
      'ip_rules_not_evaluated' =>
        getLocalText.s("IP rules were not evaluated: the address is unknown"),
      'fakeip_not_persisted' => getLocalText.s(
          "Fake IP is not kept across restarts: apps with cached addresses fail after a restart"),
      'fakeip_pool_wrapped' => getLocalText.s(
          "The fake IP pool wraps faster than the answer TTL: an old address may now belong to another domain"),
      'fakeip_unknown_address' => getLocalText
          .s("The address is in the fake IP range but has no record"),
      'fakeip_address_reassigned' =>
        getLocalText.s("The address now belongs to another domain"),
      'fakeip_ipv6_without_tun_ipv6' => getLocalText.s(
          "IPv6 fake IP is returned, but the tunnel has no IPv6 address"),
      'https_query_rejected' => getLocalText.s(
          "HTTPS DNS queries are rejected: no ECH and no ALPN hints for the app"),
      'quic_rejected' =>
        getLocalText.s("UDP 443 is rejected: browsers fall back to TCP"),
      'reality_not_recognized' => getLocalText.s(
          "The REALITY server did not recognize the client: check public key, short ID, server name"),
      'failed_after_no_ack' => getLocalText.s(
          "The connection broke after an unconfirmed step: wrong UUID or password, the server cannot reach the target, or large packets are lost"),
      'partially_reused' => getLocalText.s(
          "Some steps were reused: this does not prove the path comes up from scratch"),
      _ => null,
    };
