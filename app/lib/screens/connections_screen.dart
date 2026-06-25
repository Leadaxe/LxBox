import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_info_cache.dart';
import '../services/format_utils.dart';
import '../vpn/cc_channel.dart';
import 'connections_screen/connection_detail_sheet.dart';

/// §153 — «однобокое» (зависшее) соединение: TCP, прожившее ≥
/// [oneWayMinAge], где трафик идёт строго в одну сторону (up>0/down=0 или
/// up=0/down>0). Сигнатура зависшего потока (напр. WhatsApp ↑517 ↓0 —
/// ClientHello ушёл, ответа нет). Порог по возрасту отсекает свежие conns
/// в процессе handshake. Закрытые соединения не маркируются.
///
/// Чистая функция (без BuildContext) — покрыта юнит-тестом на живой
/// фикстуре. [now] инъектируется для детерминизма в тестах.
const Duration oneWayMinAge = Duration(seconds: 3);

bool isOneWayStuck({
  required String network,
  required int upload,
  required int download,
  required DateTime? startTime,
  required bool closed,
  DateTime? now,
}) {
  if (closed) return false;
  if (network != 'tcp') return false;
  if (startTime == null) return false;
  final age = (now ?? DateTime.now()).difference(startTime);
  if (age < oneWayMinAge) return false;
  return (upload > 0 && download == 0) || (upload == 0 && download > 0);
}

/// §166 — человекочитаемое имя правила для Conns/Stats из `rule.String()` ядра.
///
/// КЛЮЧЕВОЙ ФАКТ: наш билдер зашивает имя правила (`custom_rules[].name`) как
/// **тег rule_set'а** (`custom_rules.dart`: `tag: cr.name`). Поэтому ядро в
/// `connection.rule` отдаёт его как `rule_set=<имя>` — наш title УЖЕ там.
///
/// Приоритет:
///   1. `rule_set=Home wifi`  → `Home wifi` (имя ЦЕЛИКОМ, с пробелами — это title)
///   2. `rule_set=[ru-domains ru-services]` → `ru-domains` (НАБОР srs → первый тег)
///   3. `rule=<name>` (если ядро дублирует имя отдельным полем) → целиком
///   4. одиночное условие `domain_suffix=google.com` → `google.com`
///   5. без `=` (`final`/`direct`) → строка как есть
/// Хвост действия `=> route(...)` отрезается. Top-level — общая для Conns+Stats.
String ruleName(String rule) {
  var r = rule.trim();
  if (r.isEmpty) return r;
  // Отрезаем хвост действия `=> route(...)` (не часть имени).
  final arrow = r.indexOf('=>');
  if (arrow >= 0) r = r.substring(0, arrow).trim();
  // 1-2. rule_set= несёт наш title-тег (приоритет — он осмысленнее условий).
  final rs = _kvValue(r, 'rule_set=');
  if (rs != null && rs.isNotEmpty) {
    if (rs.startsWith('[')) {
      var v = rs.substring(1);
      if (v.endsWith(']')) v = v.substring(0, v.length - 1);
      return _firstToken(v.trim()); // набор srs → первый тег
    }
    return rs; // одно имя rule_set'а целиком (с пробелами)
  }
  // 3. rule=<name> — запасной канал имени.
  final name = _kvValue(r, 'rule=');
  if (name != null && name.isNotEmpty) return name;
  // 4-5. Одиночное условие type=value / строка как есть.
  final eq = r.indexOf('=');
  if (eq < 0) return _firstToken(r);
  var val = r.substring(eq + 1).trim();
  if (val.startsWith('[')) val = val.substring(1).trim();
  if (val.endsWith(']')) val = val.substring(0, val.length - 1).trim();
  if (val.isEmpty) return r.substring(0, eq);
  return _firstToken(val);
}

// §166 — regex'ы СТАТИЧЕСКИЕ (компиляция один раз). ruleName вызывается в
// цикле по всем connections на КАЖДЫЙ снапшот (0.1с на Stats) → компиляция
// regex на каждый вызов давала фриз UI.
final _kvBoundary = RegExp(r'\s+\w+=');
final _tokenSep = RegExp(r'[\s,]');

/// Значение `<key>...` до следующего ` <слово>=` (границы k=v-пары) или конца.
/// `rule=Home wifi` → `Home wifi` (имя с пробелами сохраняется целиком).
String? _kvValue(String s, String key) {
  final i = s.indexOf(key);
  if (i < 0) return null;
  final rest = s.substring(i + key.length);
  // Следующая k=v-пара начинается с ` <ident>=` — обрезаем по ней.
  final next = rest.indexOf(_kvBoundary);
  return (next < 0 ? rest : rest.substring(0, next)).trim();
}

/// Первый токен набора (через пробел/запятую) — `[a b c]` → `a`.
String _firstToken(String s) {
  final sep = s.indexOf(_tokenSep);
  return sep < 0 ? s : s.substring(0, sep);
}

/// Embeddable view: toolbar + список соединений. Без Scaffold, без AppBar —
/// сидит во вкладке StatsScreen.
///
/// §122 — источник = `CcChannel.instance.connections` (libbox CommandClient
/// push-стрим), а не Clash HTTP-pull. Native-аккумулятор отдаёт АКТИВНЫЕ
/// соединения; closed-историю (режим «закрытые не исчезают») ведёт ЭТОТ виджет
/// (`_accumulate`/`_closedIds`/`_closedAt`) — точно как раньше с Clash-pull.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key});

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  final _cc = CcChannel.instance;
  StreamSubscription<List<CcConnection>>? _sub;

  /// Последний снапшот живых соединений (id → conn), плюс — в режиме accumulate
  /// — недавно закрытые (помечены через [_closedIds]).
  final Map<String, CcConnection> _byId = {};
  final Set<String> _closedIds = {};
  final Map<String, DateTime> _closedAt = {};
  bool _accumulate = false;
  bool _loading = true;

  /// §122 — закрытые соединения держим [_closedWindow] (видно недавнюю историю,
  /// иначе при закрытии всё мгновенно исчезает и «ничего не ясно»). В режиме
  /// accumulate — без срока (до ручной очистки toggle'ом).
  static const _closedWindow = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _sub = _cc.connections.listen(_onConnections);
  }

  void _onConnections(List<CcConnection> conns) {
    if (!mounted) return;
    final liveIds = conns.map((c) => c.id).where((id) => id.isNotEmpty).toSet();
    final now = DateTime.now();

    // Соединения, пропавшие из живого снапшота → закрыты (метим + timestamp).
    for (final id in _byId.keys.toList()) {
      if (id.isNotEmpty && !liveIds.contains(id) && _closedIds.add(id)) {
        _closedAt[id] = now;
      }
    }
    // Свежие данные поверх (живые перетирают; закрытые остаются с прежними
    // байтами — у CcConnection.closedAt>0 они и так помечены).
    for (final c in conns) {
      if (c.id.isNotEmpty) _byId[c.id] = c;
    }
    // Истечение закрытых: в обычном режиме — старше окна; в accumulate — никогда.
    if (!_accumulate) {
      _closedIds.removeWhere((id) {
        final at = _closedAt[id];
        final expired = at == null || now.difference(at) > _closedWindow;
        if (expired) {
          _byId.remove(id);
          _closedAt.remove(id);
        }
        return expired;
      });
    }

    // §166 — аккумуляция (closed-tracking выше) идёт КАЖДЫЙ тик (иначе пропустим
    // закрытие), но ребилд (setState + ruleName/_appIcon по всему списку) —
    // троттлим: снапшоты на FAST 0.1с=10/сек, без троттла вкладка ВИСЛА.
    if (!_loading &&
        _rebuildAt != null &&
        now.difference(_rebuildAt!) < _rebuildThrottle) {
      return;
    }
    _rebuildAt = now;
    setState(() => _loading = false);
  }

  // §166 — троттл ребилда (см. _onConnections).
  static const _rebuildThrottle = Duration(milliseconds: 700);
  DateTime? _rebuildAt;

  /// Отсортированный список: новейшие сверху (по createdAt epoch ms).
  List<CcConnection> get _sorted {
    final list = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _closeConnection(String id) async {
    if (id.isEmpty) return;
    await _cc.closeConnection(id);
  }

  Future<void> _closeAll() async {
    await _cc.closeConnections();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = _sorted;
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: cs.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // Toggle: 30s-история (закрытые серым ~30с) ↔ Accumulate (навсегда).
              IconButton(
                tooltip: _accumulate
                    ? 'Keeping all closed (tap for 30s window)'
                    : 'Closed kept 30s (tap to keep all)',
                icon: Icon(
                  _accumulate ? Icons.history_toggle_off : Icons.history,
                ),
                onPressed: () {
                  setState(() {
                    _accumulate = !_accumulate;
                    if (!_accumulate) {
                      // Выключили accumulate → убираем закрытые из набора.
                      _byId.removeWhere((id, _) => _closedIds.contains(id));
                      _closedIds.clear();
                      _closedAt.clear();
                    }
                  });
                },
              ),
              const Spacer(),
              Text('${list.length}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (list.isNotEmpty)
                IconButton(
                  tooltip: 'Close all',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _closeAll,
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const Center(child: Text('No active connections'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _buildTile(list[i]),
                    ),
        ),
      ],
    );
  }

  /// Порт из "host:port" — часть после последнего ':'.
  static String _portOf(String destination) {
    final i = destination.lastIndexOf(':');
    if (i < 0 || i == destination.length - 1) return '';
    return destination.substring(i + 1);
  }

  /// Host из "host:port" — часть до последнего ':'.
  static String _hostOf(String destination) {
    final i = destination.lastIndexOf(':');
    return i < 0 ? destination : destination.substring(0, i);
  }

  Widget _buildTile(CcConnection conn) {
    final network = conn.network;
    final destPort = _portOf(conn.destination);
    // host: domain, иначе host-часть destination (IP-соединения без домена).
    final host = conn.domain.isNotEmpty ? conn.domain : _hostOf(conn.destination);
    final display = destPort.isNotEmpty ? '$host:$destPort' : host;

    final upload = conn.uplink;
    final download = conn.downlink;
    final id = conn.id;
    final closed = conn.isClosed || _closedIds.contains(id);

    final startTime = conn.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(conn.createdAt)
        : null;
    final endTime = closed
        ? (conn.closedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(conn.closedAt)
            : (_closedAt[id] ?? DateTime.now()))
        : DateTime.now();
    final duration = startTime != null ? endTime.difference(startTime) : null;

    final oneWay = isOneWayStuck(
      network: network,
      upload: upload,
      download: download,
      startTime: startTime,
      closed: closed,
    );

    final cs = Theme.of(context).colorScheme;
    final rule = ruleName(conn.rule);

    return Container(
      // §153 — розовый фон у однобоких (зависших) TCP; закрытые — без подсветки.
      color: oneWay && !closed
          ? Color.alphaBlend(Colors.pink.withValues(alpha: 0.16), cs.surface)
          : null,
      child: Opacity(
        opacity: closed ? 0.5 : 1.0,
        child: InkWell(
          onTap: () => unawaited(showConnectionDetailSheet(
            context,
            conn,
            oneWay: oneWay,
            closed: closed,
            onClose: (cid) => unawaited(_closeConnection(cid)),
          )),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: app-иконка (по getProcessInfo.package) + host:port +
                // traffic + close. §122 — иконка вернулась (ProcessInfo есть в
                // Connection); fallback на стрелку tcp/udp если pkg нет.
                Row(
                  children: [
                    _appIcon(conn.packageName, network: network, closed: closed),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        display,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '↑${formatBytes(upload)} ↓${formatBytes(download)}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        padding: EdgeInsets.zero,
                        tooltip: 'Close',
                        onPressed: (closed || id.isEmpty)
                            ? null
                            : () => _closeConnection(id),
                      ),
                    ),
                  ],
                ),
                // Row 2: outbound (нода/цепочка) — getOutbound, ОБЯЗАТЕЛЬНО.
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: Text(
                    conn.outbound.isNotEmpty ? conn.outbound : '—',
                    style: TextStyle(fontSize: 11, color: cs.primary),
                    overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // Row 3: protocol · rule · duration. Пустой rule = соединение
                // пошло по route.final (default-маршрут, без явного правила) —
                // пишем `final`, как Clash (а не `—`).
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: Text(
                    '${network.toUpperCase()}'
                    '  ·  ${rule.isNotEmpty ? rule : 'final'}'
                    '${closed ? '  ·  closed' : ''}'
                    '${duration != null ? '  ·  ${_formatDuration(duration)}' : ''}',
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// §154/§122 — launcher-иконка приложения по package name (из `getProcessInfo`).
  /// 16×16, перерисовывается через `AppInfoCache.revision` когда иконка
  /// дотянулась из native асинхронно. Fallback (нет pkg/иконки) — стрелка
  /// tcp/udp (как до §154), а для закрытых — галочка.
  Widget _appIcon(String pkg, {required String network, required bool closed}) {
    const double size = 16;
    final cs = Theme.of(context).colorScheme;
    final fallback = Icon(
      closed
          ? Icons.check_circle_outline
          : (network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward),
      size: size,
      color: closed ? cs.primary : cs.onSurfaceVariant,
    );
    if (pkg.isEmpty) return fallback;
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (context, _) {
        final icon = AppInfoCache.of(pkg)?.icon;
        if (icon == null) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(icon,
              width: size, height: size, gaplessPlayback: true),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}
