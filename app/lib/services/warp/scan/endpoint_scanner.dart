// §834 — WARP endpoint scanner: движок двухфазного скана (warpscout-inspired).
//
// Phase 1 — живость: WG-handshake по UDP (реальный Noise_IKpsk2-пакет,
// scan_wire.dart). Живым считается эндпоинт, ответивший type-4 (92 Б) или
// type-3 cookie (64 Б) — это единственный признак, отличающий «порт открыт»
// от «эндпоинт реально отвечает WARP».
//
// Phase 2 — страна/нода + подтверждение: через ШТАТНУЮ headless probe-сессию
// ядра (probeStart → probeGetUrl → probeStop, как в NodeDiagnosticsRunner и
// ProbeRunner). Запрос идёт по `https://1.1.1.1/cdn-cgi/trace`: строка `loc=`
// отдаёт страну (ISO-3166 alpha-2, верхний регистр), `colo=` — IATA-код узла.
// Без поднятой сессии probeGetUrl не работает вовсе — прежняя версия звала его
// с фиктивным тегом, из-за чего страна всегда была «??», а `valid` — 0.
//
// Если egress UDP режется (типично для РФ), WG-фаза не даёт живых. Тогда идём
// путём MASQUE: MASQUE-кандидаты (h3/h2) подтверждаются реальным GET через
// probe-сессию — открытый TCP 443 сам по себе «живостью» НЕ считается (CF-edge
// отвечает на 443 почти всегда, это ложный сигнал).
//
// Результат — список живых эндпоинтов с (страна, нода, RTT), готовый к
// группировке по странам (UI с чекбоксами) и к генерации конфигов.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../../models/node_spec.dart';
import '../../../models/tunnel_status.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../services/parser/mappers/uri_pipeline.dart'
    show parseLinkViaPipeline;
import '../../../vpn/box_vpn_client.dart';
import '../../../vpn/cc_channel.dart';
import '../../builder/core_chain_capability.dart';
import '../../probe/probe_config.dart';
import '../../settings_storage.dart';
import '../masque_account.dart';
import '../warp_account.dart';
import '../warp_client.dart';
import 'scan_models.dart';
import 'scan_node_builder.dart';
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

  /// ISO-3166 alpha-2 (верхний регистр) либо `''` — страна не определена
  /// (probe-сессия не дала `loc=`, напр. UDP-фаза прошла, а гео-фаза — нет).
  final String code;

  final String name;
  final List<EndpointResult> endpoints;

  int get found => endpoints.length;
  int get valid => endpoints.where((e) => e.alive).length;

  /// §834 — группа «страна не определена» (пустой код). UI рендерит её
  /// отдельной подписью, а не «()».
  bool get isUnknown => code.isEmpty;
}

/// Результат скана: группы по странам (отсортированы по valid desc).
class EndpointScanResult {
  const EndpointScanResult({
    required this.groups,
    required this.scanAt,
    required this.scanDurationMs,
    required this.failedCount,
    this.tcpFallbackUsed = false,
    this.note = '',
  });

  final List<EndpointCountryGroup> groups;
  final DateTime scanAt;
  final int scanDurationMs;
  final int failedCount;

  /// Был ли задействован путь MASQUE (UDP-фаза не дала живых).
  final bool tcpFallbackUsed;

  /// §834 — замечание для UI (напр. почему гео-фаза не отработала).
  final String note;

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

/// §834 — транспорт, которым эндпоинт подтверждён. Определяет, каким узлом
/// (WG/AWG или MASQUE h3/h2) его подтверждает гео-фаза.
enum EndpointTransport { wg, masqueH3, masqueH2 }

/// Тело `cdn-cgi/trace` (построчные `key=value`) → (код страны, IATA-узел).
/// Пусто/битый ответ → ('' , ''). Чистая функция — покрыта тестом.
({String country, String colo}) parseCloudflareTrace(String body) {
  var country = '';
  var colo = '';
  for (final line in const LineSplitter().convert(body)) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final k = line.substring(0, i).trim();
    final v = line.substring(i + 1).trim();
    if (k == 'loc') {
      country = v.toUpperCase();
    } else if (k == 'colo') {
      colo = v.toUpperCase();
    }
  }
  // trace может отдать `loc=` пустым (у CF это «неизвестно») — тогда страну
  // считаем неопределённой.
  if (country.length != 2) country = '';
  return (country: country, colo: colo);
}

/// Движок сканера. Не хранит состояние UI; отдаёт результаты по мере готовности.
class EndpointScanner {
  EndpointScanner({
    CcChannel? cc,
    BoxVpnClient? vpn,
    WarpClient? warpClient,
  })  : _cc = cc ?? CcChannel.instance,
        _vpn = vpn ?? BoxVpnClient(),
        _injectedWarp = warpClient;

  final CcChannel _cc;
  final BoxVpnClient _vpn;
  final WarpClient? _injectedWarp;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get cancelled => _cancelled;

  /// Максимум кандидатов за один скан (стратифицированная выборка по блокам):
  /// полный перебор /22×4 = 1280 адресов на телефоне бессмысленно долог.
  static const int maxCandidates = 256;

  /// Сколько эндпоинтов максимум подтверждаем/геолоцируем через probe-сессию.
  /// Каждая probe-сессия поднимает ядро (WG-endpoint'ы предвыделяют пулы,
  /// §523), поэтому фаза ограничена и по числу, и по батчам.
  static const int maxGeoLookups = 32;

  String _trace() => 'https://1.1.1.1/cdn-cgi/trace';

  /// Источники адресов: официальные CF-блоки WARP (WG) + MASQUE-пулы из asset.
  /// Возвращает `ip` (порт подставляется фазой) и `ip:port` (MASQUE).
  Future<List<String>> loadPools() async {
    final pool = await loadPool();
    if (pool == null) return _fallbackPools();
    // v4-блоки WG (v6-разворот здесь не делаем: expandCidrV4 работает по v4).
    final wg = _sampleIps(pool.wgV4Cidr, maxCandidates);
    final out = <String>[...wg];
    // MASQUE-кандидаты: h3-хосты + стратифицированная выборка h2-блока.
    final masqueSeen = <String>{};
    for (final h in pool.masqueH3Hosts) {
      if (masqueSeen.add(h)) out.add(h);
    }
    for (final ip in _sampleIps(pool.masqueV4Cidr, 32)) {
      if (pool.masqueH2Exclude.contains(ip)) continue;
      if (masqueSeen.add(ip)) out.add(ip);
    }
    return out.isEmpty ? _fallbackPools() : out;
  }

  /// Пул из bundled asset (root-секция; регион здесь не важен — сканируем
  /// физические адреса CF, а не региональные списки SNI).
  Future<ScanPool?> loadPool() async {
    try {
      final raw = await rootBundle.loadString('assets/warp_endpoints.json');
      return ScanPool.fromFullJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
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

  /// Запускает двухфазный скан. [endpoints] — адреса (IP или `host:port`;
  /// пустой порт → WG 2408). [excludeColos] — IATA-коды узлов (например `DME`),
  /// которые исключаются из результатов (как `-exclude-node` в warpscout).
  Future<EndpointScanResult> scan({
    required List<String> endpoints,
    int concurrency = 16,
    Duration timeout = const Duration(seconds: 3),
    bool tcpFallback = true,
    Set<String> excludeColos = const {},
    int maxGeoLookups = EndpointScanner.maxGeoLookups,
    void Function(int done, int total)? onProgressPhase1,
    void Function(int done, int total)? onProgressPhase2,
    void Function(String note)? onNote,
  }) async {
    _cancelled = false;
    final sw = Stopwatch()..start();
    var note = '';

    // ── Phase 1 — UDP WG-проба ────────────────────────────────────────────
    // Кандидаты WG — те, у кого нет не-WG порта; MASQUE-адреса (h3-хосты и
    // h2-блок) в WG-фазу не идут: они не отвечают на WG-handshake.
    final pool = await loadPool();
    final wgPorts = <int>{
      2408,
      ...?pool?.wgPorts,
    }.toList();

    final byTransport = <String, EndpointTransport>{};
    final wgCandidates = <String>[];
    final masqueCandidates = <String>[];
    for (final ep in endpoints) {
      if (_isMasqueEndpoint(ep, pool)) {
        masqueCandidates.add(ep);
        byTransport[ep] = _masqueTransport(ep, pool);
      } else {
        wgCandidates.add(ep);
      }
    }

    final alive = <String, WgProbeResult>{};
    final aliveTransport = <String, EndpointTransport>{};
    final failed = <String>[];

    Future<void> wgPass(List<int> ports) async {
      final cand = <String>[
        for (final ip in wgCandidates)
          for (final p in ports) ip.contains(':') ? ip : '$ip:$p',
      ];
      final batch = await scanWgBatch(
        endpoints: cand,
        concurrency: concurrency,
        timeout: timeout,
        onProgress: onProgressPhase1,
        cancelled: () => _cancelled,
      );
      batch.forEach((ep, r) {
        if (r.alive) {
          alive[ep] = r;
          aliveTransport[ep] = EndpointTransport.wg;
        }
      });
    }

    if (wgCandidates.isNotEmpty && !_cancelled) {
      await wgPass([2408]);
      // Другие WG-порты — только если канонический ничего не дал: операторы
      // режут 2408, но пропускают 500/1701/4500.
      if (!_cancelled && alive.isEmpty && wgPorts.isNotEmpty) {
        await wgPass(wgPorts.where((p) => p != 2408).toList());
      }
    }
    failed.addAll(wgCandidates.where((ip) => !alive.keys.any(
          (a) => a == ip || a.startsWith('$ip:'),
        )));

    // ── Phase 1b — MASQUE-путь, если UDP не дал живых ─────────────────────
    // Открытый TCP 443 НЕ считаем живостью (CF-edge отвечает почти всегда):
    // кандидаты MASQUE подтверждаются реальным GET через probe-сессию ниже.
    var usedMasque = false;
    if (tcpFallback && !_cancelled && alive.isEmpty && masqueCandidates.isNotEmpty) {
      usedMasque = true;
    }

    // ── Phase 2 — подтверждение + гео через probe-сессию ядра ─────────────
    final geoMeta = <String, ({String country, String colo})>{};
    final ordered = <String>[
      ...alive.keys,
      if (usedMasque) ...masqueCandidates,
    ];
    // Сначала самые «перспективные» (WG-ответ прошёл быстрее) — по RTT.
    final orderedSorted = [...ordered]
      ..sort((a, b) =>
          (alive[a]?.rttMs ?? 1 << 30).compareTo(alive[b]?.rttMs ?? 1 << 30));
    final geoList = orderedSorted.take(maxGeoLookups).toList();

    if (!_cancelled && geoList.isNotEmpty) {
      try {
        final res = await _probeGeo(
          geoList,
          byTransport: byTransport,
          pool: pool,
          onProgress: onProgressPhase2,
        );
        geoMeta.addAll(res.meta);
        // MASQUE-кандидаты, прошедшие GET, становятся живыми эндпоинтами.
        for (final ep in geoList) {
          if (res.meta.containsKey(ep) && !alive.containsKey(ep)) {
            alive[ep] = const WgProbeResult(WgProbeKind.response,
                rttMs: 0); // подтверждён probe-GET (MASQUE)
            aliveTransport[ep] = byTransport[ep] ?? EndpointTransport.masqueH3;
          }
        }
        if (res.error != null && res.error!.isNotEmpty) note = res.error!;
      } catch (e) {
        note = 'probe: $e';
      }
    }

    // ── Сборка результата ────────────────────────────────────────────────
    final byCountry = <String, List<EndpointResult>>{};
    for (final ep in ordered) {
      if (!alive.containsKey(ep)) continue;
      final meta = geoMeta[ep];
      final country = meta?.country ?? '';
      final colo = meta?.colo ?? '';
      if (colo.isNotEmpty && excludeColos.contains(colo)) continue;
      final r = EndpointResult(
        endpoint: ep,
        country: country,
        colo: colo,
        rttMs: alive[ep]?.rttMs ?? 0,
        alive: true,
      );
      byCountry.putIfAbsent(country, () => []).add(r);
    }

    final groups = [
      for (final e in byCountry.entries)
        EndpointCountryGroup(
          code: e.key,
          name: countryName(e.key),
          endpoints: e.value,
        ),
    ]..sort((a, b) {
        // Известные страны — выше; «не определена» — в конце.
        if (a.isUnknown != b.isUnknown) return a.isUnknown ? 1 : -1;
        return b.valid.compareTo(a.valid);
      });

    return EndpointScanResult(
      groups: groups,
      scanAt: DateTime.now().toUtc(),
      scanDurationMs: sw.elapsedMilliseconds,
      failedCount: failed.length,
      tcpFallbackUsed: usedMasque && groups.isNotEmpty,
      note: note,
    );
  }

  /// MASQUE-ли это адрес (h3-хост блока или адрес h2-блока).
  bool _isMasqueEndpoint(String ep, ScanPool? pool) {
    if (pool == null) return false;
    final host = ep.contains(':') ? ep.split(':').first : ep;
    if (pool.masqueH3Hosts.contains(host)) return true;
    return _ipInCidrs(host, pool.masqueV4Cidr);
  }

  EndpointTransport _masqueTransport(String ep, ScanPool? pool) {
    final host = ep.contains(':') ? ep.split(':').first : ep;
    if (pool == null) return EndpointTransport.masqueH3;
    // В сетях, режущих UDP (РФ), рабочий транспорт — h2 (TCP): h3 — это QUIC
    // поверх UDP. Поэтому адрес, живущий и в h2-блоке (не из exclude), ведём
    // как h2; на h3 остаются только h3-only хосты.
    final inH2 = _ipInCidrs(host, pool.masqueV4Cidr) &&
        !pool.masqueH2Exclude.contains(host);
    return inH2 ? EndpointTransport.masqueH2 : EndpointTransport.masqueH3;
  }

  /// Подтверждение + гео через probe-сессию. Возвращает карту `endpoint →
  /// (страна, узел)` по тем, через кого GET прошёл; эндпоинты, не прошедшие
  /// пробу, в карту не попадают.
  Future<
      ({
        Map<String, ({String country, String colo})> meta,
        String? error,
      })> _probeGeo(
    List<String> eps, {
    required Map<String, EndpointTransport> byTransport,
    required ScanPool? pool,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <String, ({String country, String colo})>{};
    if (eps.isEmpty) return (meta: out, error: null);

    // VPN активен → probe-сессию не поднять (два CommandServer на процесс
    // невозможны, §236). Скан от этого не рушится: живость из фазы 1 остаётся.
    try {
      final status = await _vpn.getVpnStatus();
      if (status != TunnelStatus.disconnected) {
        return (
          meta: out,
          error: getLocalText.s('VPN active — geo phase skipped'),
        );
      }
    } catch (_) {
      // Состояние VPN не спросилось — пробуем всё равно.
    }

    // Аккаунты: кеш → регистрация. Для WG нужен WarpAccount, для MASQUE —
    // MasqueAccount (обфускация/SNI — из пула).
    final client = _injectedWarp ?? WarpClient();
    WarpAccount? warpAcc;
    MasqueAccount? masqueAcc;
    String? regError;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      warpAcc = await SettingsStorage.getWarpAccount();
      masqueAcc = await SettingsStorage.getMasqueAccount();
      if (eps.any((e) => (byTransport[e] ?? EndpointTransport.wg) ==
              EndpointTransport.wg) &&
          warpAcc == null) {
        try {
          warpAcc = await client.register(
            endpoint: WarpAccount.defaultEndpoint,
            nowIso8601: now,
          );
          await SettingsStorage.setWarpAccount(warpAcc);
        } catch (e) {
          regError ??= 'WARP register failed: $e';
        }
      }
      if (eps.any((e) => (byTransport[e] ?? EndpointTransport.wg) !=
              EndpointTransport.wg) &&
          masqueAcc == null) {
        try {
          masqueAcc = await client.registerMasque(nowIso8601: now);
          await SettingsStorage.setMasqueAccount(masqueAcc);
        } catch (e) {
          regError ??= 'MASQUE register failed: $e';
        }
      }
    } finally {
      if (_injectedWarp == null) client.close();
    }

    final builder = ScanNodeBuilder(
      warp: warpAcc,
      masque: masqueAcc,
      wgKeepalive: pool?.wgKeepalive ?? 0,
    );

    // Узлы строятся в порядке [eps] (null — не собирается; индекс сохраняется,
    // `buildProbeBatches` вернёт его в `brokenByIndex`).
    final nodes = <NodeSpec?>[
      for (final ep in eps)
        _buildNodeFor(ep, byTransport[ep] ?? EndpointTransport.wg, builder, pool),
    ];

    final coreVersion = await CoreVersionCache.ensure(
      () => _vpn.getCoreVersion(),
    );
    final vars = await loadProbeVars();
    final batches = buildProbeBatches(
      nodes,
      coreVersion: coreVersion,
      vars: vars,
    );

    var done = 0;
    for (final cfg in batches) {
      if (_cancelled) break;
      if (cfg.configJson == null) continue;
      final err = await _cc.probeStart(cfg.configJson!);
      if (err.isNotEmpty) {
        return (meta: out, error: err);
      }
      try {
        for (final entry in cfg.tagByIndex.entries) {
          if (_cancelled) break;
          final ep = eps[entry.key];
          try {
            final r = await _cc.probeGetUrl(
              entry.value,
              link: _trace(),
              timeoutMs: 8000,
              maxBytes: 4096,
            );
            if (r.ok && r.content.isNotEmpty) {
              final parsed = parseCloudflareTrace(r.content);
              if (parsed.country.isNotEmpty || parsed.colo.isNotEmpty) {
                out[ep] = parsed;
              }
            }
          } catch (_) {
            // Один узел не ответил — не валим весь батч.
          }
          done++;
          onProgress?.call(done, eps.length);
        }
      } finally {
        await _cc.probeStop();
      }
    }
    return (meta: out, error: regError);
  }

  /// Строит узел-кандидат для probe-сессии под конкретный эндпоинт.
  NodeSpec? _buildNodeFor(
    String ep,
    EndpointTransport transport,
    ScanNodeBuilder builder,
    ScanPool? pool,
  ) {
    final parts = ep.split(':');
    final ip = parts[0];
    final explicitPort =
        parts.length > 1 ? int.tryParse(parts[1]) : null;
    switch (transport) {
      case EndpointTransport.wg:
        final c = ScanCandidate(
          ip: ip,
          port: explicitPort ?? 2408,
          protocol: ScanProtocol.awg,
          sni: (pool?.wgSniPool.isNotEmpty ?? false)
              ? pool!.wgSniPool.first
              : '',
          awgParams: const AwgParams(ip: 'quic', jc: 4, jmin: 40, jmax: 70),
        );
        final uri = builder.uriFor(c);
        return uri == null ? null : parseLinkViaPipeline(uri);
      case EndpointTransport.masqueH3:
      case EndpointTransport.masqueH2:
        final isH3 = transport == EndpointTransport.masqueH3;
        final ports = isH3 ? pool?.masquePortsH3 : pool?.masquePortsH2;
        final c = ScanCandidate(
          ip: ip,
          port: explicitPort ??
              ((ports?.isNotEmpty ?? false) ? ports!.first : 443),
          protocol: isH3 ? ScanProtocol.masqueH3 : ScanProtocol.masqueH2,
          sni: (pool?.masqueSniPool.isNotEmpty ?? false)
              ? pool!.masqueSniPool.first
              : '',
        );
        final uri = builder.uriFor(c);
        return uri == null ? null : parseLinkViaPipeline(uri);
    }
  }
}

/// Стратифицированная выборка IP из списка CIDR: /22 разбиваем на /24 (иначе
/// [expandCidrV4] их не разворачивает), затем берём не более [max] адресов,
/// равномерно по всем блокам.
List<String> _sampleIps(List<String> cidrs, int max) {
  final all = <String>[];
  for (final cidr in cidrs) {
    for (final c24 in _toSlash24(cidr)) {
      all.addAll(expandCidrV4(c24));
    }
  }
  if (all.length <= max) return all;
  final step = all.length / max;
  final out = <String>[];
  for (var i = 0; i < max; i++) {
    out.add(all[(i * step).floor()]);
  }
  return out;
}

/// CIDR → список /24-блоков (для /24 — он сам; для широких — под-блоки; для
/// /32 — сам адрес).
List<String> _toSlash24(String cidr) {
  final slash = cidr.indexOf('/');
  if (slash < 0) return [cidr];
  final mask = int.tryParse(cidr.substring(slash + 1));
  if (mask == null || mask > 32) return const [];
  if (mask >= 24) return [cidr];
  final parts = cidr.substring(0, slash).split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return const [];
  final base = (parts[0]! << 24) | (parts[1]! << 16) | (parts[2]! << 8) | parts[3]!;
  final mask24 = 24;
  final hostBits = mask24 - mask;
  final count = 1 << hostBits;
  final netBase = base & (~((1 << (32 - mask)) - 1) & 0xFFFFFFFF);
  return [
    for (var i = 0; i < count; i++)
      '${(netBase + (i << 8)) >> 24 & 0xFF}.'
          '${(netBase + (i << 8)) >> 16 & 0xFF}.'
          '${(netBase + (i << 8)) >> 8 & 0xFF}.0/24',
  ];
}

/// Адрес входит в любой из CIDR (сравнение по сети/хосту, v4).
bool _ipInCidrs(String ip, List<String> cidrs) {
  final addr = _ipv4ToInt(ip);
  if (addr == null) return false;
  for (final c in cidrs) {
    final slash = c.indexOf('/');
    if (slash < 0) continue;
    final net = _ipv4ToInt(c.substring(0, slash));
    final mask = int.tryParse(c.substring(slash + 1));
    if (net == null || mask == null || mask < 0 || mask > 32) continue;
    final m = mask == 0 ? 0 : (~((1 << (32 - mask)) - 1) & 0xFFFFFFFF);
    if ((addr & m) == (net & m)) return true;
  }
  return false;
}

int? _ipv4ToInt(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  var v = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    v = (v << 8) | n;
  }
  return v;
}
