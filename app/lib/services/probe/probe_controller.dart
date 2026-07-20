// ===========================================================================
// §296 — общий probe-контроллер над подсистемой ServerList (папки/подписки/
// одиночные серверы). Владеет тем, что раньше жило россыпью в
// folder_detail_screen: пороги (probe_ms_*), ping-опции, прогон и чистые
// bulk-решения (unreachable/slower/sort-by-ping). Экраны остаются тонкими:
// держат transient-результаты (Map<int,ProbeResult>), рендер и применение
// решений к своему мутатору (folder — позиционный, subs — §283 hash).
//
// Per-run stateless (как ProbeRunner): каждый run() — свой canceller в
// ProbeLifecycle (§286), без общего мутабельного состояния.
// ===========================================================================

import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../settings_storage.dart';
import 'probe_runner.dart';

class ProbeController {
  ProbeController({ProbeRunner? runner}) : _runner = runner ?? ProbeRunner();

  final ProbeRunner _runner;

  void cancel() => _runner.cancel();

  // ─── Прогон ────────────────────────────────────────────────────────────────

  /// Общий прогон по нодам. Домен приводит себя к `List<NodeSpec?>`:
  /// - папка: `[for (m in folder.members) m.node]` (nullable, unfiltered);
  /// - подписка/сервер: `list.nodes` (disabled §283 → null-слот).
  Future<String> run({
    required List<NodeSpec?> nodes,
    required String url,
    required int timeoutMs,
    required void Function(int index, ProbeResult result) onResult,
  }) =>
      _runner.run(nodes, url: url, timeoutMs: timeoutMs, onResult: onResult);

  /// Эргономичный оверлоуд: switch member-vs-nodes[] в ОДНОМ месте.
  Future<String> runList(
    ServerList list, {
    required String url,
    required int timeoutMs,
    required void Function(int index, ProbeResult result) onResult,
  }) =>
      run(nodes: probeNodesOf(list), url: url, timeoutMs: timeoutMs, onResult: onResult);

  /// §296 — приведение любого [ServerList] к списку нод для probe. Единственное
  /// место, где решается member-vs-nodes[]. Папка отдаёт члены (nullable,
  /// unfiltered — сохраняет индекс и вердикт выключенных/битых). Подписка/сервер
  /// отдают `nodes` как есть (skip-disabled §283 применяет вызывающий экран,
  /// подменяя слот на null ПЕРЕД вызовом — здесь фильтра нет).
  static List<NodeSpec?> probeNodesOf(ServerList list) => switch (list) {
        FolderServers(:final members) => [for (final m in members) m.node],
        _ => list.nodes,
      };

  // ─── Пороги ─────────────────────────────────────────────────────────────────

  /// Читает пороги цветовой шкалы из `probe_ms_*`; отсутствующие → дефолт.
  static Future<ProbeThresholds> loadThresholds() async {
    final g = int.tryParse(await SettingsStorage.getVar('probe_ms_green', ''));
    final y = int.tryParse(await SettingsStorage.getVar('probe_ms_yellow', ''));
    final o = int.tryParse(await SettingsStorage.getVar('probe_ms_orange', ''));
    return ProbeThresholds(
      greenMs: g ?? ProbeThresholds.defaults.greenMs,
      yellowMs: y ?? ProbeThresholds.defaults.yellowMs,
      orangeMs: o ?? ProbeThresholds.defaults.orangeMs,
    );
  }

  /// Сохраняет пороги (невалидные/непозитивные → дефолт).
  static Future<ProbeThresholds> saveThresholds({
    int? greenMs,
    int? yellowMs,
    int? orangeMs,
  }) async {
    final next = ProbeThresholds(
      greenMs: (greenMs == null || greenMs <= 0)
          ? ProbeThresholds.defaults.greenMs
          : greenMs,
      yellowMs: (yellowMs == null || yellowMs <= 0)
          ? ProbeThresholds.defaults.yellowMs
          : yellowMs,
      orangeMs: (orangeMs == null || orangeMs <= 0)
          ? ProbeThresholds.defaults.orangeMs
          : orangeMs,
    );
    await SettingsStorage.setVar('probe_ms_green', '${next.greenMs}');
    await SettingsStorage.setVar('probe_ms_yellow', '${next.yellowMs}');
    await SettingsStorage.setVar('probe_ms_orange', '${next.orangeMs}');
    return next;
  }

  // ─── Ping ────────────────────────────────────────────────────────────────────

  /// Разрешает (url, timeoutMs) для теста: per-list override поверх глобальных
  /// `ping_options`. Папка передаёт `folder.pingUrl/pingTimeoutMs`; подписка/
  /// сервер — null → чистый глобал. Дефолт timeout — 3000мс.
  static Future<({String url, int timeoutMs})> resolvePingOptions({
    String? overrideUrl,
    int? overrideTimeoutMs,
  }) async {
    final ping = await SettingsStorage.getPingOptions();
    final url = (overrideUrl ?? (ping['url'] as String?))?.trim() ?? '';
    final timeoutMs = overrideTimeoutMs ??
        (ping['timeout_ms'] as num?)?.toInt() ??
        3000;
    return (url: url, timeoutMs: timeoutMs);
  }

  /// Текущий глобальный ping-target (для диалога редактирования).
  static Future<({String url, int timeoutMs})> globalPingTarget() async {
    final ping = await SettingsStorage.getPingOptions();
    return (
      url: (ping['url'] as String?) ?? '',
      timeoutMs: (ping['timeout_ms'] as num?)?.toInt() ?? 3000,
    );
  }

  /// Сохраняет глобальный ping URL (+ timeout, если задан положительный).
  static Future<void> saveGlobalPing(String url, {int? timeoutMs}) async {
    await SettingsStorage.setGlobalPingUrl(url);
    if (timeoutMs != null && timeoutMs > 0) {
      await SettingsStorage.setGlobalPingTimeout(timeoutMs);
    }
  }

  // ─── Чистые bulk-решения (доменно-агностичны; экран применяет к мутатору) ────

  /// Индексы нод, не прошедших последний тест (failed/broken/invalid).
  static Set<int> unreachableIndexes(Map<int, ProbeResult> probe) => {
        for (final e in probe.entries)
          if (e.value.status == ProbeStatus.failed ||
              e.value.status == ProbeStatus.broken ||
              e.value.status == ProbeStatus.invalid)
            e.key,
      };

  /// Индексы успешно протестированных нод медленнее [ms].
  static Set<int> slowerThan(Map<int, ProbeResult> probe, int ms) => {
        for (final e in probe.entries)
          if (e.value.status == ProbeStatus.ok && e.value.delayMs > ms) e.key,
      };

  /// Порядок сортировки по пингу для [count] нод: ok по возрастанию delay,
  /// нетестированные/pending — следом, err/broken/invalid — в конец.
  /// Stable tie-break по исходному индексу.
  static List<int> pingSortOrder(Map<int, ProbeResult> probe, int count) {
    int rank(int i) {
      final r = probe[i];
      if (r == null) return 1 << 30;
      return switch (r.status) {
        ProbeStatus.ok => r.delayMs,
        ProbeStatus.pending => 1 << 30,
        ProbeStatus.failed ||
        ProbeStatus.broken ||
        ProbeStatus.invalid =>
          (1 << 30) + 1,
      };
    }

    return [for (var i = 0; i < count; i++) i]
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : a.compareTo(b);
      });
  }

  /// Перепривязка результатов к новым индексам после reorder по [order]
  /// (order[newIndex] = oldIndex).
  static Map<int, ProbeResult> remapAfterReorder(
    Map<int, ProbeResult> probe,
    List<int> order,
  ) {
    final remapped = <int, ProbeResult>{};
    for (var newI = 0; newI < order.length; newI++) {
      final r = probe[order[newI]];
      if (r != null) remapped[newI] = r;
    }
    return remapped;
  }
}
