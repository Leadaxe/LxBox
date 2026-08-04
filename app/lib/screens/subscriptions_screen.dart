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
import 'subscriptions_screen/widgets/add_icon_button.dart';
import 'subscriptions_screen/widgets/subscription_entry_tile.dart';
import 'subscriptions_screen/widgets/subscriptions_empty_state.dart';
import '../services/l10n/locale_controller.dart';
import '../services/file_import.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({
    super.key,
    required this.subController,
    required this.homeController,
    required this.autoUpdater,
    this.focusEntryId,
    this.initialInput,
  });

  final SubscriptionController subController;
  final HomeController homeController;
  final AutoUpdater autoUpdater;

  /// §255 — при открытии проскроллить к этому entry и мигнуть его строкой
  /// (навигация из detour-cycle sheet к владельцу ноды-виновника). null = нет.
  final String? focusEntryId;

  /// §357 — предзаполнить поле «URL подписки или proxy-ссылка» (lxbox-кнопка
  /// `add:<uri>` support-ленты). Только prefill: добавление подтверждает сам
  /// юзер кнопкой «+». null = пустое поле.
  final String? initialInput;

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  final _inputController = TextEditingController();
  bool _autoUpdateEnabled = true;

  // §255 — прокрутка к владельцу + вспышка строки (навигация из detour-cycle
  // sheet). Локальная (в этом экране нет HomeState для персистентного кольца) —
  // таймер-вспышка, гаснет сама.
  final _scrollController = ScrollController();
  final _tileKeys = <String, GlobalKey>{};
  String? _highlightedEntryId;
  Timer? _highlightTimer;

  GlobalKey _tileKey(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoUpdateFlag());
    // §357 — prefill поля ввода из lxbox-кнопки `add:<uri>` support-ленты.
    final prefill = widget.initialInput;
    if (prefill != null && prefill.trim().isNotEmpty) {
      _inputController.text = prefill.trim();
    }
    final focus = widget.focusEntryId;
    if (focus != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusEntry(focus, attempt: 0));
    }
  }

  /// §255 — скролл к строке владельца + вспышка. Retry по кадрам: строка за
  /// вьюпортом в lazy-списке не смонтирована (currentContext null); грубо
  /// прыгаем по оценке позиции и повторяем ensureVisible.
  void _focusEntry(String id, {required int attempt}) {
    if (!mounted) return;
    if (attempt == 0) setState(() => _highlightedEntryId = id);
    const maxAttempts = 6;
    final ctx = _tileKeys[id]?.currentContext;
    if (ctx != null) {
      unawaited(Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.3));
    } else if (attempt < maxAttempts && _scrollController.hasClients) {
      final idx = widget.subController.entries.indexWhere((e) => e.id == id);
      if (idx >= 0) {
        final target = (idx * 88.0)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.jumpTo(target);
      }
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusEntry(id, attempt: attempt + 1));
      return;
    }
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _highlightedEntryId = null);
    });
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
    _scrollController.dispose();
    _highlightTimer?.cancel();
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
        title: Text(getLocalText.s("Discard input?")),
        content: Text(getLocalText.s("You have unsaved text in the input field. Leave and discard it?")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Stay")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Discard")),
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
    if (widget.subController.lastError == null) {
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
      SnackBar(content: Text(getLocalText.plural("Config regenerated: %d nodes", n)),
          duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Clipboard is empty"))),
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
    final addErr = widget.subController.lastError;
    if (addErr == null) {
      await _regenerateAndSave();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(addErr.render())),
      );
    }
  }

  Future<void> _scanQrCode() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("QR scanner coming soon"))),
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
      // §372 — Android TV без файлового менеджера: подсказка вместо тупика.
      final outcome = await pickFileSafely(allowMultiple: true);
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(problem)));
        }
        return;
      }
      if (outcome.files.length > 1) {
        await _importFilesIntoFolder(outcome.files);
        return;
      }
      final file = outcome.single;
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(getLocalText.s("File is empty"))),
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
        // §243 — имя файла уходит nameHint'ом: для WG/AWG `.conf` оно
        // становится tag'ом узла (фрагмент синтетического URI). Прежний
        // §234-renameAt в entry.name убран — displayName одиночного сервера
        // name игнорирует, правда живёт в tag'е.
        await widget.subController.addFromInput(text,
            nameHint: SubscriptionController.fileBaseName(file.name));
      }
      final importErr = widget.subController.lastError;
      if (importErr == null) {
        await _regenerateAndSave();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(importErr.render())),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(getLocalText.s(
                  "Error: %s", formatUserError(e).render()))),
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
        title: getLocalText.plural("Import %d files into folder", files.length));
    if (name == null || !mounted) return;
    await widget.subController.addFolder(name);
    final folderIndex = widget.subController.entries.length - 1;
    var addedFiles = 0;
    final errors = <String>[];
    for (final file in files) {
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        errors.add(getLocalText.s("%s: empty file", file.name));
        continue;
      }
      final err = await widget.subController.addMembersToFolder(
        folderIndex,
        text,
        nameFallback: SubscriptionController.fileBaseName(file.name),
      );
      if (err == null) {
        addedFiles++;
      } else {
        errors.add('${file.name}: ${err.render()}');
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
              getLocalText.plural("Config generated: %d nodes", widget.subController.entries
                  .fold<int>(0, (s, e) => s + e.nodeCount)),
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
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(getLocalText.s("Servers")),
                  Text(getLocalText.s("Subscriptions & proxy"),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.normal)),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: getLocalText.s("Update all & generate"),
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
                    PopupMenuItem(value: 'wizard', child: Text(getLocalText.s("Add server…"))),
                    PopupMenuItem(value: 'warp', child: Text(getLocalText.s("Get WARP"))),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'paste', child: Text(getLocalText.s("Paste from clipboard"))),
                    PopupMenuItem(value: 'qr', child: Text(getLocalText.s("Scan QR code"))),
                    PopupMenuItem(value: 'file', child: Text(getLocalText.s("Import from file…"))),
                    PopupMenuItem(value: 'folder', child: Text(getLocalText.s("New folder…"))),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'public', child: Text(getLocalText.s("Get Public Test Servers"))),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem<String>(
                      value: 'auto_update',
                      checked: _autoUpdateEnabled,
                      child: Text(getLocalText.s("Auto-update subscriptions")),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'sub_settings',
                      child: Text(getLocalText.s("Subscription settings…")),
                    ),
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                _buildInputBar(ctrl),
                if (ctrl.lastError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      ctrl.lastError!.render(),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (ctrl.progressMessage != null)
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
                        Expanded(child: Text(ctrl.progressMessage!.render())),
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
              decoration: InputDecoration(
                hintText: getLocalText.s("Subscription URL or proxy link"),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    );
  }

  Future<void> _launchUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Copied: %s", url))),
      );
    }
  }

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
      scrollController: _scrollController,
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
        final highlighted = _highlightedEntryId == entry.id;
        final cs = Theme.of(context).colorScheme;
        // §255 — reorder-key остаётся top-level (KeyedSubtree); GlobalKey для
        // ensureVisible + вспышка — на внутреннем Container.
        return KeyedSubtree(
          key: ValueKey(entry.id),
          child: AnimatedContainer(
            key: _tileKey(entry.id),
            duration: const Duration(milliseconds: 200),
            decoration: highlighted
                ? BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.5),
                    border: Border(
                        left: BorderSide(color: cs.primary, width: 3)),
                  )
                : null,
            child: SubscriptionEntryTile(
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
            ),
          ),
        );
      },
    );
  }
}
