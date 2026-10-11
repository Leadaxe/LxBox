// §834 — экран «Сканер эндпоинтов»: двухфазный скан WARP-эндпоинтов, список
// стран с чекбоксами (+ количество найденных/валидных), просмотр деталей,
// «Использовать выбранное» → callback с выбранными эндпоинтами.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../services/l10n/locale_controller.dart';
import '../services/warp/scan/endpoint_scanner.dart';
import '../services/warp/scan/scan_pool.dart';
import '../widgets/safe_bottom.dart';

/// Возвращает выбранные эндпоинты через [Navigator.pop] или null (отмена).
class EndpointScanScreen extends StatefulWidget {
  const EndpointScanScreen({
    super.key,
    this.concurrency = 16,
    this.timeout = const Duration(seconds: 3),
    this.perCountryLimit = 200,
    this.excludeColos = const {'DME'},
  });

  final int concurrency;
  final Duration timeout;
  final int perCountryLimit;

  /// IATA-коды узлов, исключаемые из результатов (по умолчанию DME —
  /// московский узел с фильтрацией WARP; как `-exclude-node` в warpscout).
  final Set<String> excludeColos;

  @override
  State<EndpointScanScreen> createState() => _EndpointScanScreenState();
}

class _EndpointScanScreenState extends State<EndpointScanScreen> {
  final _scanner = EndpointScanner();
  ScanPool? _basePool;
  bool _scanning = false;
  bool _viaTcp = false;
  EndpointScanResult? _result;
  final _selected = <String>{}; // коды стран
  String? _error;
  int _phase1Done = 0;
  int _phase1Total = 0;
  int _phase2Done = 0;
  int _phase2Total = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scanner.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _result = null;
      _selected.clear();
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });

    try {
      final endpoints = await _scanner.loadPools();
      if (!mounted) return;
      // §834 — базовый bundled-пул (SNI/порты) для построения пула из выбранных.
      try {
        final raw = await rootBundle.loadString('assets/warp_endpoints.json');
        _basePool = ScanPool.fromFullJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        _basePool = null;
      }
      final result = await _scanner.scan(
        endpoints: endpoints,
        concurrency: widget.concurrency,
        timeout: widget.timeout,
        excludeColos: widget.excludeColos,
        onProgressPhase1: (d, t) {
          _phase1Done = d;
          _phase1Total = t;
        },
        onProgressPhase2: (d, t) {
          _phase2Done = d;
          _phase2Total = t;
        },
      );
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _result = result;
        _viaTcp = result.tcpFallbackUsed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '$e';
      });
    } finally {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _stopScan() {
    _scanner.cancel();
    setState(() => _scanning = false);
  }

  int get _selectedEndpointCount {
    final r = _result;
    if (r == null) return 0;
    return r.groups
        .where((g) => _selected.contains(g.code))
        .fold(0, (s, g) => s + g.valid);
  }

  void _useSelected() {
    final r = _result;
    if (r == null) return;
    final eps = <String>[
      for (final g in r.groups)
        if (_selected.contains(g.code))
          for (final e in g.endpoints.take(widget.perCountryLimit)) e.endpoint,
    ];
    // §834 — возвращаем ScanPool (а не строки): генератор сразу сгенерирует
    // конфиги WARP/MASQUE на выбранных эндпоинтах через poolOverride.
    final pool = ScanPool.fromEndpoints(eps, base: _basePool);
    Navigator.of(context).pop(pool);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Endpoint scanner")),
        actions: [
          if (_scanning)
            TextButton(
              onPressed: _stopScan,
              child: Text(getLocalText.s("Stop")),
            )
          else
            TextButton(
              onPressed: _startScan,
              child: Text(getLocalText.s("Rescan")),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: TextStyle(color: cs.error)),
            ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_phase1Total > 0)
                    LinearProgressIndicator(value: _phase1Done / _phase1Total),
                  const SizedBox(height: 4),
                  Text(
                    _phase2Total > 0
                        ? getLocalText.s(
                            "Phase 2: determining country of %1\$s endpoints…",
                            '$_phase2Done/$_phase2Total',
                          )
                        : getLocalText.s(
                            "Phase 1: probing %1\$s endpoints…",
                            '$_phase1Done/$_phase1Total',
                          ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_viaTcp)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        getLocalText.s(
                          "UDP blocked — using TCP fallback (443/8443)",
                        ),
                        style: TextStyle(color: cs.tertiary, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: r == null
                ? const Center(child: CircularProgressIndicator())
                : _buildList(r, cs),
          ),
          SafeArea(
            minimum: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(getLocalText.s("Cancel")),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _scanning || _selectedEndpointCount == 0
                        ? null
                        : _useSelected,
                    child: Text(
                      getLocalText.s(
                        "Use selected (%1\$s endpoints)",
                        '$_selectedEndpointCount',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(EndpointScanResult r, ColorScheme cs) {
    if (r.groups.isEmpty) {
      return Center(
        child: Text(
          getLocalText.s(
            "No endpoints found. All UDP is likely blocked on this network — try MASQUE (TCP) or a different network.",
          ),
          style: TextStyle(color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(8).withSafeBottom(context),
      children: [
        for (final g in r.groups)
          CheckboxListTile(
            value: _selected.contains(g.code),
            onChanged: (v) => setState(() {
              if (v == true) {
                _selected.add(g.code);
              } else {
                _selected.remove(g.code);
              }
            }),
            title: Text('${g.name} (${g.code})'),
            subtitle: Text(
              getLocalText.s(
                "%1\$s found · %2\$s valid",
                '${g.found}',
                '${g.valid}',
              ),
            ),
            secondary: _countryFlag(g.code),
            dense: true,
          ),
      ],
    );
  }

  Widget _countryFlag(String code) {
    if (code.length != 2) {
      return const Icon(Icons.public);
    }
    // Региональные индикаторы: буквы A..Z → U+1F1E6..U+1F1FF.
    final cps = code.toUpperCase().codeUnits;
    if (cps.any((c) => c < 0x41 || c > 0x5A)) {
      return const Icon(Icons.public);
    }
    final flag = String.fromCharCodes(cps.map((c) => 0x1F1E6 + (c - 0x41)));
    return Text(flag, style: const TextStyle(fontSize: 22));
  }
}
