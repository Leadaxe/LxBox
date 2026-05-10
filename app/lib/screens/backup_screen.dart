import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import '../services/error_format.dart';
import '../vpn/box_vpn_client.dart';

/// Backup & restore UI — спека [§040](../../docs/spec/features/040 backup
/// restore ui/spec.md).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _service = const BackupService();

  // Export-side toggles. Default ON для всего кроме debug.
  bool _expServerLists = true;
  bool _expRouting = true;
  bool _expAppSettings = true;
  bool _expVpnSettings = true;
  bool _expDebugConfig = false;

  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _ExportCard(
            serverLists: _expServerLists,
            routing: _expRouting,
            appSettings: _expAppSettings,
            vpnSettings: _expVpnSettings,
            debugConfig: _expDebugConfig,
            busy: _busy,
            onChange: (cat, on) => setState(() {
              switch (cat) {
                case BackupCategory.serverLists:
                  _expServerLists = on;
                case BackupCategory.routing:
                  _expRouting = on;
                case BackupCategory.appSettings:
                  _expAppSettings = on;
                case BackupCategory.vpnSettings:
                  _expVpnSettings = on;
                case BackupCategory.debugConfig:
                  _expDebugConfig = on;
              }
            }),
            onExport: _onExport,
          ),
          const SizedBox(height: 8),
          _ImportCard(
            busy: _busy,
            onImport: _onImport,
          ),
        ],
      ),
    );
  }

  Set<BackupCategory> _exportInclude() {
    return {
      if (_expServerLists) BackupCategory.serverLists,
      if (_expRouting) BackupCategory.routing,
      if (_expAppSettings) BackupCategory.appSettings,
      if (_expVpnSettings) BackupCategory.vpnSettings,
      if (_expDebugConfig) BackupCategory.debugConfig,
    };
  }

  Future<void> _onExport() async {
    final include = _exportInclude();
    if (include.isEmpty) {
      _snack('Nothing to export — pick at least one category.');
      return;
    }
    setState(() => _busy = true);
    try {
      final json = await _service.buildExport(include: include);
      final filename = await BackupService.suggestedFilename();

      final tmpDir = await getTemporaryDirectory();
      final path = '${tmpDir.path}/$filename';
      await File(path).writeAsString(json);

      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/json', name: filename)],
        subject: 'LxBox backup',
      );
      _snack('Backup exported (${json.length} bytes)');
    } catch (e) {
      _snack('Export failed: ${formatUserError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onImport() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        return; // user cancelled
      }
      final file = picked.files.single;
      final bytes = file.bytes;
      String? raw;
      if (bytes != null) {
        raw = utf8DecodeOrNull(bytes);
      } else if (file.path != null) {
        raw = await File(file.path!).readAsString();
      }
      if (raw == null) {
        _snack('Could not read file.');
        return;
      }

      final BackupContents contents;
      try {
        contents = await _service.parseImport(raw);
      } on FormatException catch (e) {
        if (!mounted) return;
        _showError('Invalid backup', e.message);
        return;
      }

      if (!mounted) return;
      final result = await _showImportPreview(contents);
      if (result == null) return; // cancelled

      final apply = await _service.applyImport(
        contents,
        merge: result.merge,
        include: result.include,
      );
      if (!mounted) return;
      final summary = StringBuffer('Imported');
      final parts = <String>[];
      if (apply.serverListsApplied > 0) {
        parts.add('${apply.serverListsApplied} server lists');
      }
      if (apply.routingApplied > 0) {
        parts.add('routing (${apply.routingApplied} rules)');
      }
      if (apply.appSettingsApplied > 0) {
        parts.add('${apply.appSettingsApplied} app settings');
      }
      if (apply.debugConfigApplied > 0) {
        parts.add('debug config');
      }
      if (apply.vpnSettingsApplied > 0) {
        parts.add('${apply.vpnSettingsApplied} VPN settings');
      }
      if (parts.isEmpty) {
        summary.write(' nothing (all categories deselected)');
      } else {
        summary.write(': ${parts.join(', ')}');
      }
      if (apply.hasErrors) {
        summary.write(' (${apply.errors.length} errors)');
      }
      // applyImport пишет в SettingsStorage, но controllers (Subscription /
      // Home / Routing screen state) держат in-memory snapshot — UI остаётся
      // stale. Restart-кнопка вызывает quitApp(); юзер сам тапает иконку,
      // app поднимается с fresh storage.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(summary.toString()),
            duration: const Duration(seconds: 6),
            action: parts.isEmpty
                ? null
                : SnackBarAction(
                    label: 'Restart now',
                    onPressed: () =>
                        unawaited(BoxVpnClient().quitApp()),
                  ),
          ),
        );
      }
    } catch (e) {
      _snack('Import failed: ${formatUserError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_ImportDialogResult?> _showImportPreview(BackupContents c) async {
    final available = c.availableCategories();
    var include = Set<BackupCategory>.from(available);
    var merge = true;
    return await showDialog<_ImportDialogResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final servers = c.splitServerLists();
          return AlertDialog(
            title: const Text('Import backup'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (c.createdAt != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Created: ${c.createdAt!.toLocal().toString().split('.')[0]}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (c.sourceAppVersion != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'App version: ${c.sourceAppVersion}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  const Text(
                    'Includes:',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  if (available.contains(BackupCategory.serverLists))
                    _previewCheckbox(
                      ctx,
                      label:
                          '${c.countFor(BackupCategory.serverLists)} server lists '
                          '(${servers.subs} subs, ${servers.custom} custom)',
                      checked: include.contains(BackupCategory.serverLists),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          include.add(BackupCategory.serverLists);
                        } else {
                          include.remove(BackupCategory.serverLists);
                        }
                      }),
                    ),
                  if (available.contains(BackupCategory.routing))
                    _previewCheckbox(
                      ctx,
                      label: 'Routing — '
                          '${c.countFor(BackupCategory.routing)} rules'
                          '${c.routingFinalOutbound != null && c.routingFinalOutbound!.isNotEmpty ? ', final: ${c.routingFinalOutbound}' : ''}',
                      checked: include.contains(BackupCategory.routing),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          include.add(BackupCategory.routing);
                        } else {
                          include.remove(BackupCategory.routing);
                        }
                      }),
                    ),
                  if (available.contains(BackupCategory.appSettings))
                    _previewCheckbox(
                      ctx,
                      label:
                          '${c.countFor(BackupCategory.appSettings)} app settings',
                      checked: include.contains(BackupCategory.appSettings),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          include.add(BackupCategory.appSettings);
                        } else {
                          include.remove(BackupCategory.appSettings);
                        }
                      }),
                    ),
                  if (available.contains(BackupCategory.vpnSettings))
                    _previewCheckbox(
                      ctx,
                      label:
                          '${c.countFor(BackupCategory.vpnSettings)} VPN system toggles',
                      checked: include.contains(BackupCategory.vpnSettings),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          include.add(BackupCategory.vpnSettings);
                        } else {
                          include.remove(BackupCategory.vpnSettings);
                        }
                      }),
                    ),
                  if (available.contains(BackupCategory.debugConfig))
                    _previewCheckbox(
                      ctx,
                      label: 'Debug API config (sensitive — token included)',
                      checked: include.contains(BackupCategory.debugConfig),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          include.add(BackupCategory.debugConfig);
                        } else {
                          include.remove(BackupCategory.debugConfig);
                        }
                      }),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Mode:',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  RadioGroup<bool>(
                    groupValue: merge,
                    onChanged: (v) => set(() => merge = v ?? true),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RadioListTile<bool>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: true,
                          title: Text('Merge with existing (recommended)'),
                          subtitle: Text(
                            'Adds new items, keeps existing.',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        RadioListTile<bool>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: false,
                          title: Text('Replace all (destructive)'),
                          subtitle: Text(
                            'Wipes existing data in selected categories.',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: include.isEmpty
                    ? null
                    : () async {
                        if (!merge) {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (cctx) => AlertDialog(
                              title: const Text('Replace all data?'),
                              content: const Text(
                                'This will overwrite your current data in '
                                'the selected categories. This cannot be '
                                'undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(cctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Theme.of(cctx)
                                        .colorScheme
                                        .errorContainer,
                                    foregroundColor: Theme.of(cctx)
                                        .colorScheme
                                        .onErrorContainer,
                                  ),
                                  onPressed: () => Navigator.pop(cctx, true),
                                  child: const Text('Replace'),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          if (!ctx.mounted) return;
                        }
                        Navigator.pop(
                          ctx,
                          _ImportDialogResult(
                            include: include,
                            merge: merge,
                          ),
                        );
                      },
                child: const Text('Import'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _previewCheckbox(
    BuildContext ctx, {
    required String label,
    required bool checked,
    required ValueChanged<bool?> onChanged,
  }) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: checked,
      onChanged: onChanged,
      title: Text(label),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _showError(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
        ],
      ),
    );
  }
}

class _ImportDialogResult {
  const _ImportDialogResult({required this.include, required this.merge});
  final Set<BackupCategory> include;
  final bool merge;
}

class _ExportCard extends StatelessWidget {
  const _ExportCard({
    required this.serverLists,
    required this.routing,
    required this.appSettings,
    required this.vpnSettings,
    required this.debugConfig,
    required this.busy,
    required this.onChange,
    required this.onExport,
  });

  final bool serverLists;
  final bool routing;
  final bool appSettings;
  final bool vpnSettings;
  final bool debugConfig;
  final bool busy;
  final void Function(BackupCategory cat, bool on) onChange;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.upload_outlined),
                const SizedBox(width: 8),
                Text('Export', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Save your subscriptions, routing setup and preferences as a JSON file.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Server lists'),
              subtitle: const Text(
                'Subscriptions and custom servers',
                style: TextStyle(fontSize: 11),
              ),
              value: serverLists,
              onChanged: (v) =>
                  onChange(BackupCategory.serverLists, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Routing'),
              subtitle: const Text(
                'Custom rules, tun apps, DNS options, final outbound',
                style: TextStyle(fontSize: 11),
              ),
              value: routing,
              onChanged: (v) => onChange(BackupCategory.routing, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('App settings'),
              subtitle: const Text(
                'Preferences, ping options, auto-update, wifi history',
                style: TextStyle(fontSize: 11),
              ),
              value: appSettings,
              onChanged: (v) =>
                  onChange(BackupCategory.appSettings, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('VPN system toggles'),
              subtitle: const Text(
                'auto-start, keep on exit, background mode, allow bypass',
                style: TextStyle(fontSize: 11),
              ),
              value: vpnSettings,
              onChanged: (v) =>
                  onChange(BackupCategory.vpnSettings, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Debug API config',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Includes the access token. Sensitive — leave OFF unless you know why.',
                style: TextStyle(fontSize: 11),
              ),
              value: debugConfig,
              onChanged: (v) =>
                  onChange(BackupCategory.debugConfig, v ?? false),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onExport,
                icon: const Icon(Icons.share),
                label: const Text('Export...'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.busy, required this.onImport});
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.download_outlined),
                const SizedBox(width: 8),
                Text('Import', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Restore from a backup JSON file. Preview shown before applying.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: busy ? null : onImport,
                icon: const Icon(Icons.folder_open),
                label: const Text('Pick file...'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Безопасный UTF-8 decode — на invalid bytes возвращает null вместо throw.
String? utf8DecodeOrNull(List<int> bytes) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } catch (_) {
    return null;
  }
}
