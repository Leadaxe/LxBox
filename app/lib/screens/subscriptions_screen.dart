import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../config/consts.dart';
import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../services/community_servers_loader.dart';
import '../services/settings_storage.dart';
import '../services/url_mask.dart';
import '../services/subscription/auto_updater.dart';
import '../services/subscription/input_helpers.dart';
import '../services/url_launcher.dart';
import 'node_filter_screen.dart';
import 'node_settings_screen.dart';
import 'subscription_detail_screen.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({
    super.key,
    required this.subController,
    required this.homeController,
    required this.autoUpdater,
  });

  final SubscriptionController subController;
  final HomeController homeController;
  final AutoUpdater autoUpdater;

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  final _inputController = TextEditingController();
  bool _autoUpdateEnabled = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoUpdateFlag());
  }

  Future<void> _loadAutoUpdateFlag() async {
    final v = await SettingsStorage.getAutoUpdateSubs();
    if (!mounted) return;
    setState(() => _autoUpdateEnabled = v);
  }

  Future<void> _toggleAutoUpdate() async {
    final next = !_autoUpdateEnabled;
    await SettingsStorage.setAutoUpdateSubs(next);
    if (!mounted) return;
    setState(() => _autoUpdateEnabled = next);
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    // Unsaved-input guard (night T4-3): если юзер ввёл что-то в поле и
    // уходит со screen без сабмита — подтверждаем, чтобы не терять URL
    // / proxy-link, который он только что вставил.
    final pending = _inputController.text.trim();
    if (pending.isEmpty) return true;
    if (!mounted) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard input?'),
        content: const Text(
            'You have unsaved text in the input field. Leave and discard it?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _add() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      // Пустое поле + тап «+» = paste-from-clipboard поток с диалогом
      // подтверждения (анализ + предпросмотр).
      await _pasteFromClipboard();
      return;
    }
    await widget.subController.addFromInput(text);
    if (widget.subController.lastError.isEmpty) {
      _inputController.clear();
      await _regenerateAndSave();
    }
  }

  /// После любого add'а — пересобрать конфиг и сохранить, чтобы новые
  /// узлы попали в выбираемые group'ы без ручного нажатия rebuild.
  Future<void> _regenerateAndSave() async {
    final config = await widget.subController.generateConfig();
    if (!mounted || config == null) return;
    await widget.homeController.saveParsedConfig(config);
    if (!mounted) return;
    final n = widget.subController.entries
        .where((e) => e.enabled)
        .fold<int>(0, (s, e) => s + e.nodeCount);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Config regenerated: $n nodes'),
          duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
        );
      }
      return;
    }

    final analysis = _analyzeClipboard(text);
    if (!mounted) return;

    if (analysis.type == 'unknown') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add from clipboard'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  const Text('Unknown format', style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                text.length > 100 ? '${text.substring(0, 100)}...' : text,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add from clipboard'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Detected: ${analysis.title}', style: const TextStyle(fontWeight: FontWeight.bold)),
            if (analysis.subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(analysis.subtitle, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await widget.subController.addFromInput(text);
    if (widget.subController.lastError.isEmpty) {
      await _regenerateAndSave();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.subController.lastError)),
      );
    }
  }

  _ClipboardAnalysis _analyzeClipboard(String text) {
    if (isSubscriptionUrl(text)) {
      final uri = Uri.tryParse(text);
      return _ClipboardAnalysis(
        type: 'subscription',
        title: 'Subscription URL',
        subtitle: uri?.host ?? text,
      );
    }
    if (isWireGuardConfig(text)) {
      final lines = text.split('\n');
      final endpoint = lines
          .where((l) => l.trim().toLowerCase().startsWith('endpoint'))
          .map((l) => l.split('=').last.trim())
          .firstOrNull ?? '';
      return _ClipboardAnalysis(
        type: 'wireguard_config',
        title: 'WireGuard config',
        subtitle: endpoint.isNotEmpty ? endpoint : '[Interface] + [Peer]',
      );
    }
    if (isDirectLink(text)) {
      final uri = Uri.tryParse(text);
      final scheme = text.split('://').first.toUpperCase();
      final label = uri?.fragment ?? '';
      final server = uri != null ? '${uri.host}:${uri.port}' : '';
      return _ClipboardAnalysis(
        type: 'direct',
        title: '$scheme link',
        subtitle: '${label.isNotEmpty ? "$label\n" : ""}$server',
      );
    }
    // JSON outbound
    if ((text.startsWith('{') || text.startsWith('[')) && text.contains('"type"')) {
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map<String, dynamic>) {
          final type = parsed['type'] ?? 'unknown';
          final tag = parsed['tag'] ?? '';
          return _ClipboardAnalysis(
            type: 'json_outbound',
            title: 'Outbound JSON',
            subtitle: '$type${tag.toString().isNotEmpty ? " — $tag" : ""}',
          );
        }
        if (parsed is List) {
          final types = parsed
              .whereType<Map<String, dynamic>>()
              .map((o) => o['type']?.toString() ?? '?')
              .toList();
          return _ClipboardAnalysis(
            type: 'json_outbound',
            title: 'Outbound JSON',
            subtitle: '${parsed.length} outbounds (${types.join(" + ")})',
          );
        }
      } catch (_) {}
    }
    return _ClipboardAnalysis(type: 'unknown', title: 'Unknown', subtitle: '');
  }

  Future<void> _scanQrCode() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR scanner coming soon')),
      );
    }
  }

  Future<void> _updateAll() async {
    // Ручной force-refresh: сбрасываем session-cap (5 фейлов) и форсим через
    // AutoUpdater — так получаем `_running` guard от дубль-кликов и общий
    // логирующий путь. После fetch'а — локальный generateConfig (без HTTP).
    widget.autoUpdater.resetAllFailCounts();
    await widget.autoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: true);
    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (!mounted) return;
    if (config != null) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Config generated: '
              '${widget.subController.entries.fold<int>(0, (s, e) => s + e.nodeCount)} nodes',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.subController,
      builder: (context, _) {
        final ctrl = widget.subController;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (await _onWillPop()) {
              if (context.mounted) Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Servers'),
                  Text('Subscriptions & proxy', style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Update all & generate',
                  onPressed: ctrl.busy ? null : () => unawaited(_updateAll()),
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'public') unawaited(_pickPublicTestServer());
                    if (v == 'paste') unawaited(_pasteFromClipboard());
                    if (v == 'qr') unawaited(_scanQrCode());
                    if (v == 'auto_update') unawaited(_toggleAutoUpdate());
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'paste', child: Text('Paste from clipboard')),
                    const PopupMenuItem(value: 'qr', child: Text('Scan QR code')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'public', child: Text('Get Public Test Servers')),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem<String>(
                      value: 'auto_update',
                      checked: _autoUpdateEnabled,
                      child: const Text('Auto-update subscriptions'),
                    ),
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                _buildInputBar(ctrl),
                if (ctrl.lastError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      ctrl.lastError,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (ctrl.progressMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(ctrl.progressMessage)),
                      ],
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    // Pull-to-refresh (night T3-2): стандартный Android UX-жест,
                    // альтернативный кнопке refresh в AppBar. Эквивалент
                    // `_updateAll()`; noop если уже busy.
                    onRefresh: () async {
                      if (ctrl.busy) return;
                      await _updateAll();
                    },
                    child: _buildList(ctrl),
                  ),
                ),
                if (ctrl.entries.isNotEmpty)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => NodeFilterScreen(
                                subController: widget.subController,
                                homeController: widget.homeController,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.filter_list, size: 18),
                          label: const Text(kAutoOutboundTag),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputBar(SubscriptionController ctrl) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              decoration: const InputDecoration(
                hintText: 'Subscription URL or proxy link',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Add',
            onPressed: ctrl.busy ? null : () => unawaited(_add()),
            icon: const Icon(Icons.add, size: 20),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, int index, SubscriptionEntry entry) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy URL'),
              onTap: () {
                final url = entry.url.isNotEmpty
                    ? entry.url
                    : entry.connections.isNotEmpty
                        ? entry.connections.first
                        : '';
                if (url.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('URL copied')),
                  );
                }
                Navigator.pop(ctx);
              },
            ),
            // Share (night T6-2): for SubscriptionServers с URL даём masked-
            // share по умолчанию. Юзер может включить "Share with token"
            // через confirm-dialog (с предупреждением).
            if (entry.url.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('Share URL…'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _shareSubscriptionUrl(entry);
                },
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Update'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(widget.subController.updateAt(index));
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('Delete subscription?'),
                    content: Text('Remove "${entry.displayName}"?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx, true),
                        style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await widget.subController.removeAt(index);
                            }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied: $url')),
      );
    }
  }

  /// Share URL подписки (night T6-2). По умолчанию предлагаем masked
  /// вариант (`scheme://host/***`) — безопасно расшарить в чат / саппорт.
  /// Full URL с токеном — отдельная кнопка с предупреждением.
  Future<void> _shareSubscriptionUrl(SubscriptionEntry entry) async {
    final full = entry.url;
    if (full.isEmpty) return;
    final masked = maskSubscriptionUrl(full);
    final choice = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Share subscription URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Masked URL is safe to share — it has no token:'),
            const SizedBox(height: 6),
            SelectableText(masked,
                style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            const Text(
                'Full URL contains your provider token — share only with people who have access to your subscription.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, 'masked'),
            child: const Text('Share masked'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dCtx, 'full'),
            child: const Text('Share full'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    final text = choice == 'full' ? full : masked;
    await Share.share(text, subject: 'LxBox subscription');
  }

  Future<void> _pickPublicTestServer() async {
    CommunityManifest manifest;
    try {
      manifest = await CommunityServersLoader.load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test servers list unavailable')),
      );
      return;
    }
    if (!mounted) return;
    if (manifest.lists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test servers list unavailable')),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Get Public Test Servers'),
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (manifest.attribution != null) ...[
              Row(
                children: [
                  Icon(
                    Icons.volunteer_activism,
                    size: 18,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      manifest.attribution!.text,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (manifest.attribution!.link.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      tooltip: 'View on GitHub',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () =>
                          unawaited(UrlLauncher.open(manifest.attribution!.link)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            ...List.generate(manifest.lists.length, (i) {
              final list = manifest.lists[i];
              return ListTile(
                leading: const Icon(Icons.list_alt),
                title: Text('List ${i + 1}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _inputController.text = list.source;
                },
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(SubscriptionController ctrl) {
    if (ctrl.entries.isEmpty) {
      // Onboarding card (night T5-1): вместо голого "No subscriptions yet"
      // показываем карточку с 3-step start — пользователь сразу видит что
      // делать. ListView+AlwaysScrollable чтобы pull-to-refresh (T3-2)
      // продолжал работать на пустом экране.
      final cs = Theme.of(context).colorScheme;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: cs.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.rocket_launch, color: cs.primary),
                      const SizedBox(width: 10),
                      Text('Getting started',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text('1. Get a subscription URL from your VPN provider, or a direct proxy link (vless://, trojan://, vmess://, ss://…).'),
                  const SizedBox(height: 8),
                  const Text('2. Paste it into the field above, or tap ⋮ → «Paste from clipboard», «Scan QR code».'),
                  const SizedBox(height: 8),
                  const Text('3. Hit «+». L×Box will fetch, parse and configure — and you can connect from the Home tab.'),
                  const SizedBox(height: 18),
                  Text(
                    'No provider yet?',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('Try a public test server — free, limited, good for first-time check:'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: ctrl.busy
                        ? null
                        : () => unawaited(_pickPublicTestServer()),
                    icon: const Icon(Icons.flash_on),
                    label: const Text('Get Public Test Servers'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Tip: pull down to refresh, or tap ⟳ in the top bar after adding.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      // AlwaysScrollable — чтобы pull-to-refresh работал и на коротких
      // списках, не заполняющих экран (night T3-2).
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: ctrl.entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final entry = ctrl.entries[i];
        final enabled = entry.enabled;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 40,
            child: Switch(
              value: enabled,
              onChanged: (_) {
                unawaited(widget.subController.toggleAt(i));
                        },
            ),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: enabled ? null : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (entry.supportUrl.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: GestureDetector(
                    onTap: () => _launchUrl(entry.supportUrl),
                    child: Icon(
                      entry.supportUrl.contains('t.me') ? Icons.telegram : Icons.open_in_new,
                      size: 16,
                      color: entry.supportUrl.contains('t.me')
                          ? const Color(0xFF2AABEE)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: _buildEntrySubtitle(context, entry),
          trailing: entry.url.isEmpty && entry.connections.isNotEmpty
              ? Icon(Icons.dns, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant)
              : null,
          onLongPress: () => _showContextMenu(context, i, entry),
          onTap: () {
            final isDirectServer = entry.url.isEmpty && entry.connections.isNotEmpty;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => isDirectServer
                    ? NodeSettingsScreen(
                        entry: entry,
                        index: i,
                        subController: widget.subController,
                      )
                    : SubscriptionDetailScreen(
                        entry: entry,
                        index: i,
                        controller: widget.subController,
                      ),
              ),
            );
          },
        );
      },
    );
  }

  /// Строка под именем подписки. Для SubscriptionServers показываем:
  /// `{nodes} · 🔄 24h · 🕐 3h ago · (2 fails)`
  /// где fail-часть только если consecutiveFails > 0.
  Widget? _buildEntrySubtitle(BuildContext context, SubscriptionEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final muted = entry.enabled ? scheme.onSurfaceVariant : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    final parts = <Widget>[];
    final textStyle = TextStyle(fontSize: 12, color: muted);

    // UserServer всегда single-node — показываем протокол (VLESS/WG/...).
    // SubscriptionServers — нодcount + ⚙ если есть detour-цепочки.
    final isUser = entry.list is UserServer;
    String statusText;
    if (isUser) {
      final node = entry.list.nodes.isNotEmpty ? entry.list.nodes.first : null;
      statusText = node != null ? '${node.protocol.toUpperCase()} server' : '';
    } else if (entry.status.isNotEmpty) {
      statusText = entry.status;
    } else {
      statusText = entry.nodeCount > 0 ? '${entry.nodeCount} nodes' : '';
    }
    if (statusText.isNotEmpty) {
      parts.add(Text(statusText, style: textStyle));
    }

    if (entry.list is SubscriptionServers) {
      final intervalH = entry.updateIntervalHours;
      if (intervalH > 0) {
        parts.add(Icon(Icons.sync, size: 12, color: muted));
        parts.add(Text(_compactHours(intervalH), style: textStyle));
      }

      final last = entry.lastUpdated;
      if (last != null) {
        parts.add(Icon(Icons.schedule, size: 12, color: muted));
        parts.add(Text(SubscriptionEntry.formatAgo(last), style: textStyle));
      } else if (entry.lastUpdateStatus == UpdateStatus.never) {
        parts.add(Icon(Icons.schedule, size: 12, color: muted));
        parts.add(Text('never', style: textStyle));
      }

      final fails = entry.consecutiveFails;
      if (fails > 0) {
        final failColor = entry.enabled ? scheme.error : muted;
        parts.add(Text(
          '($fails fail${fails == 1 ? '' : 's'})',
          style: TextStyle(fontSize: 12, color: failColor),
        ));
      }
    }

    if (parts.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: parts,
      ),
    );
  }

  static String _compactHours(int hours) {
    if (hours <= 0) return '';
    if (hours < 24) return '${hours}h';
    final d = hours ~/ 24;
    final rem = hours % 24;
    if (rem == 0) return '${d}d';
    return '${d}d${rem}h';
  }
}

class _ClipboardAnalysis {
  _ClipboardAnalysis({required this.type, required this.title, required this.subtitle});
  final String type;
  final String title;
  final String subtitle;
}
