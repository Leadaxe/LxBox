import 'dart:async';

import '../../models/node_spec.dart';
import '../../vpn/cc_channel.dart';
import '../app_log.dart';
import 'probe_config.dart';
import 'probe_lifecycle.dart';

/// §236 — маркер, что тест не запустился из-за активного VPN. UI ловит его
/// (равенством) и показывает попап-гейт с кнопкой Stop VPN вместо ошибки.
/// Не человеко-читаемый текст: наружу как сообщение не идёт.
const kProbeVpnRunning = '__vpn_running__';

/// §236 — вердикт теста одного члена папки.
enum ProbeStatus {
  /// Тест ещё не дошёл (или отменён до старта).
  pending,

  /// Успех: [ProbeResult.delayMs] валиден (0мс — тоже успех, Variant B).
  ok,

  /// Ядро вернуло ошибку/таймаут — нода недоступна.
  failed,

  /// raw члена не парсится (нода битая) — тесту не подлежит.
  broken,

  /// emit ноды упал — конфиг из неё не собрать.
  invalid,
}

class ProbeResult {
  const ProbeResult(this.status, {this.delayMs = 0, this.message = ''});

  final ProbeStatus status;
  final int delayMs;
  final String message;
}

/// §236/§296 — прогон теста по списку нод (общий для всей подсистемы
/// ServerList: папки/подписки/серверы).
///
/// Тест возможен только при выключенном VPN: probe-сессия — временный
/// CommandServer без tun (два CommandServer на процесс невозможны). При живом
/// туннеле `probeStart` вернёт «VPN is running…» → возвращаем [kProbeVpnRunning],
/// UI показывает гейт-попап (Stop VPN). Через боевое ядро НЕ тестируем: замер
/// шёл бы поверх активного детура/цепочки, а не по чистой ноде, и выключенные
/// ноды выпадали бы из конфига — вводило в заблуждение (§236 UI-rework).
class ProbeRunner {
  ProbeRunner({CcChannel? cc}) : _cc = cc ?? CcChannel.instance;

  final CcChannel _cc;
  bool _cancelled = false;

  /// Конкурентность пула: ядро меряет по одной ноде synchronous+stateless
  /// (SPEC 014), мультиплекс на одном клиенте — как mass-ping §209.
  static const _concurrency = 6;

  void cancel() => _cancelled = true;

  /// Прогоняет тест по всем [nodes] (null-слот → вердикт 'broken', индекс
  /// сохраняется). Результаты отдаются по мере готовности в [onResult]
  /// (index, result). Возвращает '' или текст фатальной ошибки (не пер-нодной).
  ///
  /// §296 — вызывающий приводит свой домен к `List<NodeSpec?>`: папка передаёт
  /// `folder.members.map((m)=>m.node)` (nullable, unfiltered — НЕ `folder.nodes`,
  /// тот отфильтрован); подписка/сервер — `list.nodes` (disabled §283 → null).
  Future<String> run(
    List<NodeSpec?> nodes, {
    required String url,
    required int timeoutMs,
    required void Function(int index, ProbeResult result) onResult,
  }) async {
    _cancelled = false;
    // §286 — регистрируем отмену в общем реестре: stop VPN / смерть туннеля /
    // сворадивание дёрнут ProbeLifecycle.haltAll() → cancel() здесь, и sweep
    // прекратится, даже если экран деталей папки не в фокусе. Снимаем в finally.
    final canceller = ProbeLifecycle.I.register(cancel);
    try {
      final cfg = buildProbeConfig(nodes);

      // Битые/несобираемые — вердикт сразу, без ядра.
      cfg.brokenByIndex.forEach((i, why) {
        onResult(
            i,
            ProbeResult(
              why == 'broken' ? ProbeStatus.broken : ProbeStatus.invalid,
              message: why,
            ));
      });
      if (cfg.configJson == null) return '';

      final err = await _cc.probeStart(cfg.configJson!);
      if (err.isEmpty) {
        try {
          await _runPool(
            cfg.tagByIndex,
            test: (tag) =>
                _cc.probeUrlTest(tag, link: url, timeoutMs: timeoutMs),
            onResult: onResult,
          );
        } finally {
          await _cc.probeStop();
        }
        return '';
      }

      // VPN активен → probe-сессию не поднять. UI гейтит тест ещё до run()
      // (getVpnStatus), но между проверкой и probeStart VPN мог стартовать —
      // ловим здесь маркером, не боевой веткой.
      if (_looksLikeVpnRunning(err)) return kProbeVpnRunning;

      AppLog.I.warning('Probe session failed to start: $err');
      return err;
    } finally {
      ProbeLifecycle.I.deregister(canceller);
    }
  }

  static bool _looksLikeVpnRunning(String err) =>
      err.toLowerCase().contains('vpn is running');

  Future<void> _runPool(
    Map<int, String> tags, {
    required Future<CcDelayResult> Function(String tag) test,
    required void Function(int index, ProbeResult result) onResult,
  }) async {
    final queue = tags.entries.toList();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_cancelled) return;
        if (next >= queue.length) return;
        final entry = queue[next++];
        final r = await test(entry.value);
        if (_cancelled) return;
        onResult(
          entry.key,
          r.ok
              ? ProbeResult(ProbeStatus.ok, delayMs: r.delay)
              : ProbeResult(ProbeStatus.failed, message: r.error),
        );
      }
    }

    await Future.wait([
      for (var w = 0; w < _concurrency; w++) worker(),
    ]);
  }
}

/// §236 — пороги цветовой шкалы (мс). Дефолты — из запроса NeoCat (4PDA).
class ProbeThresholds {
  const ProbeThresholds({
    this.greenMs = 250,
    this.yellowMs = 500,
    this.orangeMs = 700,
  });

  /// §296 — единственный источник дефолтов (был триплет 250/500/700,
  /// скопированный в folder_detail 3×).
  static const defaults = ProbeThresholds();

  final int greenMs;
  final int yellowMs;
  final int orangeMs;

  /// 0=зелёный, 1=жёлтый, 2=оранжевый, 3=красный.
  int bandOf(int delayMs) {
    if (delayMs <= greenMs) return 0;
    if (delayMs <= yellowMs) return 1;
    if (delayMs <= orangeMs) return 2;
    return 3;
  }
}
