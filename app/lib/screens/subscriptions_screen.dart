import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../services/error_format.dart';
import '../services/settings_storage.dart';
import '../services/subscription/auto_updater.dart';
import '../services/url_launcher.dart';
import 'add_server_wizard_screen.dart';
import 'app_settings_screen.dart';
import 'folder_detail_screen.dart';
import 'node_settings_screen.dart';
import 'subscription_detail_screen.dart';
import 'warp_wizard_screen.dart';
import 'subscriptions_screen/clipboard_analysis.dart';
import 'subscriptions_screen/entry_context_menu.dart';
import 'subscriptions_screen/folder_picker.dart';
import 'subscriptions_screen/paste_dialogs.dart';
import 'subscriptions_screen/public_test_servers.dart';
import 'subscriptions_screen/share_subscription_url.dart';
import 'subscriptions_screen/widgets/add_icon_button.dart';
import 'subscriptions_screen/widgets/subscription_entry_tile.dart';
import 'subscriptions_screen/widgets/subscriptions_empty_state.dart';

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

  /// §074 — open Add server wizard (long-press на «+»). Wizard сам зовёт
  /// `addUserServer`/`addFromInput`; после successful add — callback
  /// делает `_regenerateAndSave` тут.
  void _openAddServerWizard() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AddServerWizardScreen(
        subController: widget.subController,
        onAdded: _regenerateAndSave,
      ),
    ));
  }

  /// Открыть App Settings сразу на табе «Subscriptions» (initialTab: 1).
  void _openSubscriptionSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const AppSettingsScreen(initialTab: 1),
    ));
  }

  /// §025 — открыть full-screen визард Cloudflare WARP.
  void _openWarpWizard() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WarpWizardScreen(
        subController: widget.subController,
        onAdded: _regenerateAndSave,
      ),
    ));
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

    final analysis = analyzeClipboard(text);
    if (!mounted) return;

    if (analysis.type == 'unknown') {
      showUnknownFormatDialog(context, text);
      return;
    }

    final confirmed = await showConfirmAddDialog(context, analysis);

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

  Future<void> _scanQrCode() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR scanner coming soon')),
      );
    }
  }

  /// §234 — создать пустую папку серверов.
  Future<void> _createFolder() async {
    final name = await showFolderNameDialog(context);
    if (name == null) return;
    await widget.subController.addFolder(name);
  }

  /// Импорт подписки/конфига из файла. Содержимое (URI-список, JSON-конфиг,
  /// proxy-link) идёт в тот же `addFromInput`, что и paste/manual — парсер
  /// сам определяет формат. file_picker уже используется на других экранах
  /// (config_screen / backup) — паттерн чтения bytes/path идентичный.
  ///
  /// §234 — multi-select: несколько файлов → все серверы в новую папку
  /// (имена нод — из имён файлов). Один файл — прежние пути (§129
  /// file-подписка при >1 ноды / одиночный сервер).
  Future<void> _importFromFile() async {
    try {
      final result =
          await FilePicker.pickFiles(withData: true, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      if (result.files.length > 1) {
        await _importFilesIntoFolder(result.files);
        return;
      }
      final file = result.files.single;
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File is empty')),
          );
        }
        return;
      }
      if (!mounted) return;
      // §129 — если в файле > 1 ноды, создаём ФАЙЛОВУЮ подписку (снапшот в
      // кэше, живёт как обычная подписка). ≤ 1 ноды → старое поведение
      // (addFromInput → одиночный сервер/нода).
      final asFileSub =
          await widget.subController.addFileSubscription(text, file.name);
      if (!asFileSub) {
        if (!mounted) return;
        final countBefore = widget.subController.entries.length;
        await widget.subController.addFromInput(text);
        // §234 — имя из имени файла: свежедобавленный одиночный сервер без
        // имени получает имя файла (displayName показывает name первым).
        final entries = widget.subController.entries;
        if (widget.subController.lastError.isEmpty &&
            entries.length == countBefore + 1) {
          final added = entries.last;
          if (added.list is UserServer && added.name.isEmpty) {
            await widget.subController.renameAt(entries.length - 1,
                SubscriptionController.fileBaseName(file.name));
          }
        }
      }
      if (widget.subController.lastError.isEmpty) {
        await _regenerateAndSave();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.subController.lastError)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${formatUserError(e)}')),
        );
      }
    }
  }

  static Future<String?> _readPickedFile(PlatformFile file) async {
    if (file.bytes != null && file.bytes!.isNotEmpty) {
      return String.fromCharCodes(file.bytes!);
    }
    if (file.path != null) return File(file.path!).readAsString();
    return null;
  }

  /// §234 — несколько выбранных файлов → новая папка со всеми серверами.
  Future<void> _importFilesIntoFolder(List<PlatformFile> files) async {
    final name = await showFolderNameDialog(context,
        title: 'Import ${files.length} files into folder');
    if (name == null || !mounted) return;
    await widget.subController.addFolder(name);
    final folderIndex = widget.subController.entries.length - 1;
    var addedFiles = 0;
    final errors = <String>[];
    for (final file in files) {
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        errors.add('${file.name}: empty file');
        continue;
      }
      final err = await widget.subController.addMembersToFolder(
        folderIndex,
        text,
        nameFallback: SubscriptionController.fileBaseName(file.name),
      );
      if (err.isEmpty) {
        addedFiles++;
      } else {
        errors.add('${file.name}: $err');
      }
    }
    if (!mounted) return;
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errors.join('\n'))),
      );
    }
    if (addedFiles > 0) {
      await _regenerateAndSave();
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
                    // §074: «Add server» — duplicate access к wizard'у
                    // (long-press на «+» — discoverability через accidental,
                    // overflow menu — explicit affordance).
                    if (v == 'wizard') _openAddServerWizard();
                    if (v == 'warp') _openWarpWizard();
                    if (v == 'public') unawaited(_pickPublicTestServer());
                    if (v == 'paste') unawaited(_pasteFromClipboard());
                    if (v == 'qr') unawaited(_scanQrCode());
                    if (v == 'file') unawaited(_importFromFile());
                    if (v == 'folder') unawaited(_createFolder());
                    if (v == 'auto_update') unawaited(_toggleAutoUpdate());
                    if (v == 'sub_settings') _openSubscriptionSettings();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'wizard', child: Text('Add server…')),
                    const PopupMenuItem(value: 'warp', child: Text('Get WARP')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'paste', child: Text('Paste from clipboard')),
                    const PopupMenuItem(value: 'qr', child: Text('Scan QR code')),
                    const PopupMenuItem(value: 'file', child: Text('Import from file…')),
                    const PopupMenuItem(value: 'folder', child: Text('New folder…')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'public', child: Text('Get Public Test Servers')),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem<String>(
                      value: 'auto_update',
                      checked: _autoUpdateEnabled,
                      child: const Text('Auto-update subscriptions'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'sub_settings',
                      child: Text('Subscription settings…'),
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
          // §074: tap = paste-from-clipboard / parse text input (existing).
          // long-press = full-screen Add server wizard (SOCKS5 form / Paste
          // URI / Paste JSON tabs).
          //
          // НЕ IconButton — у того встроенный Tooltip widget (даже без
          // tooltip:, Material InkWell внутри его перехватывает long-press
          // первым в gesture arena). Используем raw InkWell + Material
          // styled под IconButton.filled (primary container + circle).
          // Pattern уже applied для §070 sort button.
          AddIconButton(
            busy: ctrl.busy,
            onTap: () => unawaited(_add()),
            onLongPress: _openAddServerWizard,
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, int index, SubscriptionEntry entry) {
    showEntryContextMenu(
      context,
      index,
      entry,
      subController: widget.subController,
      autoUpdater: widget.autoUpdater,
      onShareUrl: _shareSubscriptionUrl,
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

  Future<void> _shareSubscriptionUrl(SubscriptionEntry entry) =>
      shareSubscriptionUrl(context, entry);

  Future<void> _pickPublicTestServer() async {
    await pickPublicTestServer(
      context,
      onSelectSource: (source) => _inputController.text = source,
    );
  }

  Widget _buildList(SubscriptionController ctrl) {
    if (ctrl.entries.isEmpty) {
      return SubscriptionsEmptyState(
        busy: ctrl.busy,
        onPickPublicTestServer: () => unawaited(_pickPublicTestServer()),
      );
    }
    return ReorderableListView.builder(
      // §098 — drag-reorder подписок (grab-strip слева, как routing rules).
      // AlwaysScrollable — pull-to-refresh на коротких списках. Divider теперь
      // внутри самой строки (у ReorderableListView нет separatorBuilder).
      physics: const AlwaysScrollableScrollPhysics(),
      // Bottom safe-area: последняя подписка не должна прятаться за системной
      // навигацией Android (жесты/кнопки). Паттерн проекта — padding.bottom + 24.
      padding: EdgeInsets.fromLTRB(
          12, 0, 12, MediaQuery.of(context).padding.bottom + 24),
      buildDefaultDragHandles: false,
      itemCount: ctrl.entries.length,
      onReorder: (oldIndex, newIndex) {
        // ReorderableListView сдвигает newIndex на 1 при move вниз.
        if (newIndex > oldIndex) newIndex -= 1;
        unawaited(widget.subController.moveEntry(oldIndex, newIndex));
      },
      itemBuilder: (context, i) {
        final entry = ctrl.entries[i];
        return SubscriptionEntryTile(
          key: ValueKey(entry.id),
          dragIndex: i,
          entry: entry,
          onToggle: () {
            unawaited(widget.subController.toggleAt(i));
          },
          onLaunchUrl: _launchUrl,
          onLongPress: (context) => _showContextMenu(context, i, entry),
          onTap: (context) {
            // §234 — папка открывает свой экран (члены + settings).
            if (entry.list is FolderServers) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FolderDetailScreen(
                    entry: entry,
                    controller: widget.subController,
                  ),
                ),
              );
              return;
            }
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
                        controller: widget.subController,
                      ),
              ),
            );
          },
        );
      },
    );
  }
}
