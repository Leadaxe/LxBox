// §834 — WARP endpoint scanner: движок двухфазного скана (warpscout-inspired).
//
// Phase 1 — живость: WG-handshake по UDP (или TCP-порт открыт как фолбэк на
// блокированном UDP) для каждого адреса из пула.
// Phase 2 — страна/нода: через probe-сессию ядра (probeGetUrl tag →
// https://speed.cloudflare.com/meta) — тот же способ, что warpscout: ответ
// meta отдаёт `country` и `colo`. Прогон идёт в батчах по одному узлу, чтобы
// не перегружать ядро и не ждать всю сессию.
//
// Результат — список живых эндпоинтов с (страна, нода, RTT), готовый к
// группировке по странам (UI с чекбоксами) и к генерации конфигов.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../../vpn/cc_channel.dart';
import 'scan_pool.dart';
import 'scan_wg_probe.dart';
import 'scan_wire.dart';

/// Один валидный эндпоинт с гео-метаданными.
class EndpointResult {
  const EndpointResult({
    required this.endpoint,
    required this.country,
    required this.colo,
    required this.rttMs,
    required this.alive,
  });

  final String endpoint;
  final String country;
  final String colo;
  final int rttMs;
  final bool alive;
}

/// Группа по стране: список эндпоинтов + счётчики.
class EndpointCountryGroup {
  const EndpointCountryGroup({
    required this.code,
    required this.name,
    required this.endpoints,
  });

  final String code;
  final String name;
  final List<EndpointResult> endpoints;

  int get found => endpoints.length;
  int get valid => endpoints.where((e) => e.alive).length;
}

/// Результат скана: группы по странам (отсортированы по valid desc).
class EndpointScanResult {
  const EndpointScanResult({
    required this.groups,
    required this.scanAt,
    required this.scanDurationMs,
    required this.failedCount,
    this.tcpFallbackUsed = false,
  });

  final List<EndpointCountryGroup> groups;
  final DateTime scanAt;
  final int scanDurationMs;
  final int failedCount;

  /// Был ли задействован TCP-fallback (UDP-фаза не дала живых).
  final bool tcpFallbackUsed;

  int get totalFound => groups.fold(0, (s, g) => s + g.endpoints.length);
  int get totalValid => groups.fold(0, (s, g) => s + g.valid);
}

/// Статический справочник стран (ISO 3166-1 alpha-2 → русские имена).
const Map<String, String> _countryNames = {
  'US': 'США',
  'DE': 'Германия',
  'NL': 'Нидерланды',
  'GB': 'Великобритания',
  'FR': 'Франция',
  'FI': 'Финляндия',
  'SE': 'Швеция',
  'PL': 'Польша',
  'CZ': 'Чехия',
  'EE': 'Эстония',
  'LV': 'Латвия',
  'LT': 'Литва',
  'UA': 'Украина',
  'BY': 'Беларусь',
  'KZ': 'Казахстан',
  'RU': 'Россия',
  'TR': 'Турция',
  'IL': 'Израиль',
  'AE': 'ОАЭ',
  'SG': 'Сингапур',
  'JP': 'Япония',
  'HK': 'Гонконг',
  'KR': 'Южная Корея',
  'IN': 'Индия',
  'BR': 'Бразилия',
  'CA': 'Канада',
  'AU': 'Австралия',
  'IT': 'Италия',
  'ES': 'Испания',
  'CH': 'Швейцария',
  'AT': 'Австрия',
  'BE': 'Бельгия',
  'IE': 'Ирландия',
  'NO': 'Норвегия',
  'DK': 'Дания',
  'RO': 'Румыния',
  'BG': 'Болгария',
  'GR': 'Греция',
  'PT': 'Португалия',
  'HU': 'Венгрия',
  'SK': 'Словакия',
  'SI': 'Словения',
  'HR': 'Хорватия',
  'RS': 'Сербия',
  'MD': 'Молдова',
  'GE': 'Грузия',
  'AM': 'Армения',
  'AZ': 'Азербайджан',
  'UZ': 'Узбекистан',
  'PH': 'Филиппины',
  'ID': 'Индонезия',
  'MY': 'Малайзия',
  'TH': 'Таиланд',
  'VN': 'Вьетнам',
  'TW': 'Тайвань',
  'MX': 'Мексика',
  'AR': 'Аргентина',
  'CL': 'Чили',
  'CO': 'Колумбия',
  'PE': 'Перу',
  'ZA': 'ЮАР',
  'NG': 'Нигерия',
  'EG': 'Египет',
  'SA': 'Саудовская Аравия',
};

String countryName(String code) =>
    _countryNames[code.toUpperCase()] ?? code.toUpperCase();

/// Движок сканера. Не хранит состояние UI; отдаёт результаты по мере готовности.
class EndpointScanner {
  EndpointScanner({CcChannel? cc}) : _cc = cc ?? CcChannel.instance;

  final CcChannel _cc;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get cancelled => _cancelled;

  /// Источники адресов: официальные CF-блоки WARP + MASQUE-пулы из asset.
  Future<List<String>> loadPools() async {
    try {
      final raw = await rootBundle.loadString('assets/warp_endpoints.json');
      final pool = ScanPool.fromFullJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      final out = <String>[];
      if (pool != null) {
        for (final c in pool.wgV4Cidr) {
          out.addAll(expandCidrV4(c));
        }
        for (final h in pool.masqueH3Hosts) {
          out.add(h);
        }
      }
      return out.isEmpty ? _fallbackPools() : out;
    } catch (_) {
      return _fallbackPools();
    }
  }

  List<String> _fallbackPools() {
    // Проверенные CF-адреса (см. docs/§834 notes): WARP anycast + h3/h2 MASQUE.
    return const [
      '162.159.192.1',
      '162.159.192.2',
      '162.159.193.1',
      '162.159.195.1',
      '188.114.96.1',
      '188.114.97.1',
      '188.114.98.1',
      '188.114.99.1',
      '162.159.198.1',
      '162.159.198.2',
      '162.159.199.1',
      '162.159.199.2',
    ];
  }

  /// Запускает двухфазный скан. [endpoints] — адреса (IP или `host:port`,
  /// пустой порт → 2408). [onProgressPhase1]/[onProgressPhase2] — прогресс.
  /// [excludeColos] — IATA-коды узлов (например `DME`), которые исключаются
  /// из результатов (как `-exclude-node` в warpscout); '??' исключает
  /// эндпоинты, чью страну определить не удалось.
  Future<EndpointScanResult> scan({
    required List<String> endpoints,
    int concurrency = 16,
    Duration timeout = const Duration(seconds: 3),
    bool tcpFallback = true,
    Set<String> excludeColos = const {},
    void Function(int done, int total)? onProgressPhase1,
    void Function(int done, int total)? onProgressPhase2,
  }) async {
    _cancelled = false;
    final sw = Stopwatch()..start();
    final failed = <String>[];

    // Phase 1 — UDP WG-проба (warpscout-метод); те, кто ответил, живут.
    // Если UDP заблокирован провайдером (РФ), WG-ответа не будет — тогда
    // используем TCP-fallback (cf-scanner-метод): открытый 443 = кандидат.
    final alive = <String, WgProbeResult>{};
    final batch = await scanWgBatch(
      endpoints: endpoints,
      concurrency: concurrency,
      timeout: timeout,
      onProgress: onProgressPhase1,
      cancelled: () => _cancelled,
    );
    batch.forEach((ep, r) {
      if (r.alive) {
        alive[ep] = r;
      } else {
        failed.add(ep);
      }
    });

    // TCP-fallback: если UDP-фаза дала 0 живых — скорее всего egress UDP
    // режется. Прогоняем TCP 443/8443 (MASQUE h2 работает по TCP в РФ).
    if (tcpFallback && !_cancelled && alive.isEmpty && endpoints.isNotEmpty) {
      final byTcp = await _tcpProbeBatch(endpoints, concurrency, timeout);
      byTcp.forEach((ep, ok) {
        if (ok && !alive.containsKey(ep)) {
          alive[ep] = WgProbeResult(WgProbeKind.tcpOpen);
        }
      });
    }

    // Phase 2 — страна через probe-сессию ядра (fingerprint живых).
    final results = <EndpointResult>[];
    if (!_cancelled && alive.isNotEmpty) {
      final aliveList = alive.keys.toList();
      var done2 = 0;
      final byCountry = <String, List<EndpointResult>>{};

      for (final ep in aliveList) {
        if (_cancelled) break;
        final meta = await _metaViaNode(ep);
        final country = meta?.country ?? '??';
        final colo = meta?.colo ?? '';
        if (colo.isNotEmpty && excludeColos.contains(colo)) continue;
        results.add(
          EndpointResult(
            endpoint: ep,
            country: country,
            colo: colo,
            rttMs: alive[ep]?.rttMs ?? 0,
            alive: meta != null,
          ),
        );
        byCountry.putIfAbsent(country, () => []).add(results.last);
        done2++;
        onProgressPhase2?.call(done2, aliveList.length);
      }

      final groups = [
        for (final e in byCountry.entries)
          EndpointCountryGroup(
            code: e.key,
            name: countryName(e.key),
            endpoints: e.value,
          ),
      ]..sort((a, b) => b.valid.compareTo(a.valid));

      return EndpointScanResult(
        groups: groups,
        scanAt: DateTime.now().toUtc(),
        scanDurationMs: sw.elapsedMilliseconds,
        failedCount: failed.length,
        tcpFallbackUsed: alive.isNotEmpty && failed.isNotEmpty,
      );
    }

    return EndpointScanResult(
      groups: const [],
      scanAt: DateTime.now().toUtc(),
      scanDurationMs: sw.elapsedMilliseconds,
      failedCount: failed.length,
      tcpFallbackUsed: alive.isNotEmpty && failed.isNotEmpty,
    );
  }

  /// Проба TCP-открытости (443/8443) — fallback для сетей, режущих UDP (РФ).
  Future<Map<String, bool>> _tcpProbeBatch(
    List<String> endpoints,
    int concurrency,
    Duration timeout,
  ) async {
    final out = <String, bool>{};
    final ports = const [443, 8443];
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled) {
        final i = next++;
        if (i >= endpoints.length) return;
        final ep = endpoints[i];
        var ok = false;
        for (final p in ports) {
          final host = ep.contains(':') ? ep.split(':').first : ep;
          try {
            final s = await Socket.connect(host, p, timeout: timeout);
            await s.close();
            ok = true;
            break;
          } catch (_) {
            // пробуем следующий порт
          }
        }
        out[ep] = ok;
      }
    }

    await Future.wait([
      for (var w = 0; w < concurrency && w < endpoints.length; w++) worker(),
    ]);
    return out;
  }

  /// Через узел тянет /meta (speed.cloudflare.com) — страна/нода эндпоинта.
  /// Возвращает null, если узел не прошёл (сеть/ядро недоступно).
  Future<({String country, String colo})?> _metaViaNode(String endpoint) async {
    try {
      // probe-сессия: одна на скан, узлы переключаются тегом (см. ProbeRunner).
      // Формат ответа meta: JSON {country, colo:{iata,city,cca2}}.
      final r = await _cc.probeGetUrl(
        'ep_$endpoint',
        link: 'https://speed.cloudflare.com/meta',
        timeoutMs: 8000,
        maxBytes: 4096,
      );
      final body = r.content;
      final m = RegExp(r'"country"\s*:\s*"([^"]+)"').firstMatch(body);
      final c = RegExp(r'"iata"\s*:\s*"([^"]+)"').firstMatch(body);
      if (m == null) return null;
      return (country: m.group(1)!, colo: c?.group(1) ?? '');
    } catch (_) {
      return null;
    }
  }
}
