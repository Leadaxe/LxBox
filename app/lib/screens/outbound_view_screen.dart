import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/config_node.dart';
import '../services/runtime_chain.dart';
import '../services/settings_storage.dart';
import 'owner_navigation.dart';

/// §258 — экран деталей outbound'а («View details» из меню ноды): вкладки
/// **Overview** (основные параметры + рантайм-цепочка detour, хопы
/// кликабельны → экран владельца) и **JSON** (прежний read-only дамп §099
/// с Copy-аффордансом в AppBar).
class OutboundViewScreen extends StatefulWidget {
  const OutboundViewScreen({
    super.key,
    required this.tag,
    required this.kind,
    required this.json,
    required this.detourCount,
    required this.onCopy,
    required this.config,
    required this.subController,
    required this.homeController,
  });

  final String tag;
  final String kind;
  final String json;

  /// §099 — число detour-хопов у ноды (0 = нет). Определяет вид Copy-аффорданса
  /// и лейбл «server + detour(s)».
  final int detourCount;

  /// Копирование JSON-варианта (перенесено из контекстного меню ноды, §099).
  /// `mode`: `'server'` | `'detour'` | `'both'` → `copyNodeJson`.
  final void Function(String mode) onCopy;

  /// §258 — распарсенный собранный конфиг (источник параметров и цепочки).
  final ParsedConfig config;

  /// §258 — навигация по хопам (openTagOwner) требует оба контроллера.
  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<OutboundViewScreen> createState() => _OutboundViewScreenState();
}

class _OutboundViewScreenState extends State<OutboundViewScreen> {
  late final TextEditingController _jsonCtrl;

  // §258 — каналы: подпись канальных хопов «⚙ label» + канальная ветка
  // навигации. Цепочка строится после загрузки (initState → _load).
  List<Channel> _channels = const [];
  List<RuntimeHop> _hops = const [];

  @override
  void initState() {
    super.initState();
    _jsonCtrl = TextEditingController(text: widget.json);
    _hops = runtimeChainOf(widget.tag, widget.config, channels: _channels);
    unawaited(_load());
  }

  @override
  void dispose() {
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final channels = await SettingsStorage.getChannels();
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _hops = runtimeChainOf(widget.tag, widget.config, channels: channels);
    });
  }

  void _onHopTap(RuntimeHop hop) {
    unawaited(openTagOwner(
      context,
      hop.tag,
      subController: widget.subController,
      homeController: widget.homeController,
      channels: _channels,
      onOwnerNotFound: () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Source not found in your lists')),
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    // §099 — лейбл «both»: единственное «detour» или «detours(N)» при N>1.
    final bothLabel = widget.detourCount > 1
        ? 'Copy server + detours(${widget.detourCount})'
        : 'Copy server + detour';
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.kind} · ${widget.tag}',
              overflow: TextOverflow.ellipsis),
          bottom: const TabBar(
            tabs: [Tab(text: 'Overview'), Tab(text: 'JSON')],
          ),
          actions: [
            // §099 — без detour: простая кнопка Copy (JSON ноды). С detour:
            // выпадашка (Copy server JSON / Copy detour / Copy server + detour(s)).
            if (widget.detourCount > 0)
              PopupMenuButton<String>(
                tooltip: 'Copy',
                icon: const Icon(Icons.content_copy),
                onSelected: widget.onCopy,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'server',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.content_copy, size: 20),
                      title: Text('Copy server JSON'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'detour',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.alt_route, size: 20),
                      title: Text('Copy detour'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'both',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy_all, size: 20),
                      title: Text(bothLabel),
                    ),
                  ),
                ],
              )
            else
              IconButton(
                tooltip: 'Copy JSON',
                icon: const Icon(Icons.content_copy),
                onPressed: () => widget.onCopy('server'),
              ),
          ],
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildOverviewTab(context),
              _buildJsonTab(context),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Overview ──────────────────────────────────────────────────────────

  Widget _buildOverviewTab(BuildContext context) {
    final node = widget.config[widget.tag];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _sectionHeader(context, 'Parameters'),
        ..._paramRows(context, node),
        const SizedBox(height: 16),
        _sectionHeader(context, 'Route'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Live path in packet order. Tap a hop to open its source.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ..._routeRows(context),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// Основные параметры из `ConfigNode` (§091/§102/§103): без ре-парса JSON.
  List<Widget> _paramRows(BuildContext context, ConfigNode? node) {
    if (node == null) {
      return [_kvRow(context, 'Type', 'not in current config')];
    }
    final raw = node.raw;
    final server = raw['server'];
    final port = raw['server_port'];
    final members = raw['outbounds'];
    final typeLabel =
        node.kind == 'endpoint' ? '${node.type} · endpoint' : node.type;
    return [
      _kvRow(context, 'Type', typeLabel),
      if (server is String && server.isNotEmpty)
        _kvRow(context, 'Server', port == null ? server : '$server:$port'),
      if (node.transportLabel != null)
        _kvRow(context, 'Transport', node.transportLabel!),
      if (node.securityLabel != null)
        _kvRow(context, 'Security', node.securityLabel!),
      if (members is List) _kvRow(context, 'Members', '${members.length}'),
    ];
  }

  Widget _kvRow(BuildContext context, String k, String v) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(k,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(v,
                style:
                    const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  /// Цепочка «по ходу пакета»: Phone → хопы → Internet. Обрыв на
  /// неразрешённом селекторе (туннель down) / битом теге — строка-эллипсис
  /// сразу после Phone (обрыв всегда на глубоком, Phone-краю цепочки).
  /// Первый хоп-группа = выбор не разрешён: при известном выборе глубже
  /// лежал бы сам pick. Битый тег (`isUnknown`) эллипсиса не получает — его
  /// хоп-строка сама говорит «not in config» (и §172 такие detour лечит ещё
  /// при сборке).
  List<Widget> _routeRows(BuildContext context) {
    final truncated = _hops.isNotEmpty && _hops.first.isGroup;
    return [
      _endpointRow(context, Icons.smartphone, 'Phone'),
      if (truncated) _ellipsisRow(context),
      for (var i = 0; i < _hops.length; i++)
        _hopRow(context, _hops[i], isSelf: i == _hops.length - 1),
      _endpointRow(context, Icons.public, 'Internet'),
    ];
  }

  Widget _endpointRow(BuildContext context, IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      title: Text(label,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
    );
  }

  Widget _ellipsisRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
      title: Text(
        'connect to see the full path',
        style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _hopRow(BuildContext context, RuntimeHop hop,
      {required bool isSelf}) {
    final cs = Theme.of(context).colorScheme;
    // §274 — ⚙ по флагу канала (displayLabel), а не по факту «хоп — канал»:
    // единый source-of-truth маркера.
    final ch = hop.channel;
    final title = ch != null ? ch.displayLabel : hop.tag;
    final subtitle = [
      if (hop.isUnknown) 'not in config' else hop.type,
      if (hop.viaSelection) 'current pick',
      if (isSelf) 'this node',
    ].join(' · ');
    final icon = hop.isUnknown
        ? Icons.help_outline
        : hop.isGroup
            ? Icons.hub_outlined
            : Icons.dns_outlined;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20,
          color: isSelf ? cs.primary : cs.onSurfaceVariant),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelf ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      trailing: Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
      onTap: () => _onHopTap(hop),
    );
  }

  // ─── JSON ───────────────────────────────────────────────────────────────

  Widget _buildJsonTab(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _jsonCtrl,
        readOnly: true,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: theme.colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.all(10),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerLow,
        ),
      ),
    );
  }
}
