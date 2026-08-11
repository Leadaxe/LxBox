import '../../models/node_spec.dart';
import '../../models/tunnel_status.dart';
import '../../vpn/box_vpn_client.dart';
import '../../vpn/cc_channel.dart';
import '../probe/probe_config.dart';
import '../probe/probe_lifecycle.dart';

/// §392 — итог одного диагностического прогона по узлу.
///
/// [source] говорит, ЧЕРЕЗ ЧТО шёл запрос: две ветки взаимоисключающи (два
/// CommandServer на процесс невозможны, см. §236), и разница видна юзеру.
class DiagnosticOutcome {
  const DiagnosticOutcome({
    required this.source,
    required this.result,
  });

  final DiagnosticSource source;
  final CcGetUrlResult result;

  bool get ok => result.ok;
}

/// Через какое ядро прошла проба.
enum DiagnosticSource {
  /// VPN выключен — временная probe-сессия из одного этого узла.
  probe,

  /// VPN включён — боевое ядро, узел адресован тегом (selector не тронут).
  live,
}

/// §392 — прогон одного диагностического GET через конкретный узел.
///
/// Ветка выбирается автоматически по состоянию VPN, потому что выбора и нет:
/// probe-сессия — временный CommandServer без tun, а он не поднимается рядом с
/// боевым (`command.sock` один на basePath, §236). При живом туннеле работает
/// только боевой клиент, при выключенном — только probe.
///
/// Обе ветки отвечают на один вопрос — «что видно через ЭТОТ узел». Ни одна не
/// отвечает на «через что я хожу прямо сейчас»: живой маршрут с правилами,
/// sniff'ом и выбором группы проверяется только обычным запросом с устройства
/// (граница kernel SPEC 058 §5).
class NodeDiagnosticsRunner {
  NodeDiagnosticsRunner({CcChannel? cc, BoxVpnClient? vpn})
      : _cc = cc ?? CcChannel.instance,
        _vpn = vpn ?? BoxVpnClient();

  final CcChannel _cc;
  final BoxVpnClient _vpn;

  /// Таймаут обмена. Диагностика идёт под глазом пользователя — висеть дольше
  /// бессмысленно, а дефолт ядра (0) не ограничен ничем, кроме самого вызова.
  static const int kTimeoutMs = 10000;

  /// Кламп тела. Диагностические ответы — сотни байт; дефолт ядра (256 KiB)
  /// избыточен. Обрезка не молчаливая — приезжает флагом `truncated`.
  static const int kMaxBytes = 64 * 1024;

  bool _cancelled = false;

  /// §286 — отмена кооперативная, как у ProbeRunner: гасит уже незначимый
  /// результат и не даёт поднимать probe-сессию после stop/ухода в фон.
  void cancel() => _cancelled = true;

  /// Гоняет [url] через узел.
  ///
  /// [node] — распарсенный узел; `null` = вызывающий знает только тег в
  /// собранном конфиге (экран просмотра outbound'а). Без узла probe-ветка
  /// невозможна — временный конфиг не из чего собрать, и при выключенном VPN
  /// вызов отдаёт `'no_node'`.
  ///
  /// [liveTag] — тег узла в БОЕВОМ конфиге (с префиксом списка): в живом ядре
  /// узлы подписки живут под отображаемым тегом, а не bare. Нужен только для
  /// ветки [DiagnosticSource.live].
  ///
  /// Бросает [DiagnosticUnavailable], если прогон невозможен в принципе
  /// (узел-группа, не собирается конфиг, нет живого клиента).
  Future<DiagnosticOutcome> run(
    NodeSpec? node, {
    required String url,
    required String liveTag,
  }) async {
    _cancelled = false;
    final canceller = ProbeLifecycle.I.register(cancel);
    try {
      final vpnUp = (await _vpn.getVpnStatus()) != TunnelStatus.disconnected;
      if (_cancelled) throw const DiagnosticUnavailable('cancelled');
      if (vpnUp) return await _runLive(url: url, tag: liveTag);
      if (node == null) throw const DiagnosticUnavailable('no_node');
      return await _runProbe(node, url: url);
    } finally {
      ProbeLifecycle.I.deregister(canceller);
    }
  }

  /// Боевая ветка: узел уже есть в работающем конфиге, поднимать ничего не надо.
  Future<DiagnosticOutcome> _runLive({
    required String url,
    required String tag,
  }) async {
    final r = await _cc.getUrlViaOutbound(
      tag,
      link: url,
      timeoutMs: kTimeoutMs,
      maxBytes: kMaxBytes,
    );
    return DiagnosticOutcome(source: DiagnosticSource.live, result: r);
  }

  /// Probe-ветка: поднимаем временное ядро из ОДНОГО этого узла.
  ///
  /// Тег берём из `tagByIndex`, а не из `node.tag`: `allocate()` в
  /// [buildProbeConfig] мог его уникализировать (коллизия с `direct`/`local-dns`
  /// или с тегом собственного detour'а узла).
  Future<DiagnosticOutcome> _runProbe(
    NodeSpec node, {
    required String url,
  }) async {
    final cfg = buildProbeConfig([node]);
    final tag = cfg.tagByIndex[0];
    if (cfg.configJson == null || tag == null) {
      // Узел-группа (§322/§336) или несобираемый emit — ядро на таком конфиге
      // падает целиком («missing tags»), звать его нечем.
      throw DiagnosticUnavailable(cfg.brokenByIndex[0] ?? 'invalid node');
    }

    final err = await _cc.probeStart(cfg.configJson!);
    if (err.isNotEmpty) throw DiagnosticUnavailable(err);
    try {
      if (_cancelled) throw const DiagnosticUnavailable('cancelled');
      final r = await _cc.probeGetUrl(
        tag,
        link: url,
        timeoutMs: kTimeoutMs,
        maxBytes: kMaxBytes,
      );
      return DiagnosticOutcome(source: DiagnosticSource.probe, result: r);
    } finally {
      // Сессия одноразовая: держать её после ответа незачем, а живой probe
      // блокирует старт VPN (BoxService гасит его принудительно).
      await _cc.probeStop();
    }
  }
}

/// §392 — прогон невозможен как таковой (в отличие от состоявшегося обмена с
/// плохим статусом, который является нормальным результатом).
class DiagnosticUnavailable implements Exception {
  const DiagnosticUnavailable(this.reason);

  final String reason;

  /// Узел — группа (§322): своего соединения у неё нет, диагностировать нечего.
  bool get isGroup => reason == 'group';

  @override
  String toString() => reason;
}
