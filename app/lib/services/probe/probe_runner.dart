import 'dart:async';

import '../../models/server_list.dart';
import '../../vpn/cc_channel.dart';
import '../app_log.dart';
import '../tag_resolver.dart';
import 'probe_config.dart';

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

  /// VPN запущен, член выключен → его нет в боевом конфиге. Включи — протестируем.
  notInConfig,
}

class ProbeResult {
  const ProbeResult(this.status, {this.delayMs = 0, this.message = ''});

  final ProbeStatus status;
  final int delayMs;
  final String message;
}

/// §236 — прогон теста по членам папки.
///
/// Ветвление по состоянию VPN решает НЕ UI, а native-гейт: пробуем поднять
/// probe-сессию; ответ «VPN is running…» → тестируем через боевое ядро
/// (это честный тест — outbound-dial ядра protected, мимо tun), но только
/// включённых членов (остальные [ProbeStatus.notInConfig]).
class FolderProbeRunner {
  FolderProbeRunner({CcChannel? cc}) : _cc = cc ?? CcChannel.instance;

  final CcChannel _cc;
  bool _cancelled = false;

  /// Конкурентность пула: ядро меряет по одной ноде synchronous+stateless
  /// (SPEC 014), мультиплекс на одном клиенте — как mass-ping §209.
  static const _concurrency = 6;

  void cancel() => _cancelled = true;

  /// Прогоняет тест по всем членам [folder]. Результаты отдаются по мере
  /// готовности в [onResult] (memberIndex, result). Возвращает '' или текст
  /// фатальной ошибки (не пер-нодной).
  Future<String> run(
    FolderServers folder, {
    required String url,
    required int timeoutMs,
    required void Function(int memberIndex, ProbeResult result) onResult,
  }) async {
    _cancelled = false;
    final cfg = buildProbeConfig(folder);

    // Битые/несобираемые — вердикт сразу, без ядра.
    cfg.brokenByMember.forEach((i, why) {
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
          cfg.tagByMember,
          test: (tag) => _cc.probeUrlTest(tag, link: url, timeoutMs: timeoutMs),
          onResult: onResult,
        );
      } finally {
        await _cc.probeStop();
      }
      return '';
    }

    if (!_looksLikeVpnRunning(err)) {
      AppLog.I.warning('Probe session failed to start: $err');
      return err;
    }

    // VPN запущен → тестируем через боевое ядро. В конфиге только включённые
    // члены (и только если сама папка включена); теги — display-form с
    // префиксом папки (§080-паттерн; collision-суффикс ядра не учитывается —
    // известное ограничение).
    final liveTags = <int, String>{};
    for (final i in cfg.tagByMember.keys) {
      final m = folder.members[i];
      if (!folder.enabled || !m.enabled) {
        onResult(i, const ProbeResult(ProbeStatus.notInConfig));
        continue;
      }
      liveTags[i] = TagResolver.displayTag(folder.tagPrefix, m.node!.tag);
    }
    await _runPool(
      liveTags,
      test: (tag) => _cc.urlTestOutbound(tag, link: url, timeoutMs: timeoutMs),
      onResult: onResult,
    );
    return '';
  }

  static bool _looksLikeVpnRunning(String err) =>
      err.toLowerCase().contains('vpn is running');

  Future<void> _runPool(
    Map<int, String> tags, {
    required Future<CcDelayResult> Function(String tag) test,
    required void Function(int memberIndex, ProbeResult result) onResult,
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
