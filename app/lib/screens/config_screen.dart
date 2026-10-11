import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/config_parse.dart';
import '../controllers/home_controller.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';
import '../widgets/lx_native_code_editor.dart';
import '../services/file_import.dart';
import '../widgets/safe_bottom.dart';

/// §333 — страховочный порог: выше него редактор открывается read-only.
/// Даже построчному редактору многомегабайтный конфиг на слабом устройстве
/// даётся плохо, а правка такого объёма на телефоне — не сценарий: Share →
/// внешний редактор → Load from file. Порог в символах `configRaw`
/// (конфиг — практически ASCII, так что символы ≈ байты).
const int kConfigEditMaxChars = 1024 * 1024;

bool configTooLargeToEdit(String raw) => raw.length > kConfigEditMaxChars;

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final LxNativeCodeEditorController _textController =
      LxNativeCodeEditorController();
  late final bool _readOnly;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final raw = widget.controller.state.configRaw;
    _readOnly = configTooLargeToEdit(raw);
    unawaited(_initLoad(raw));
  }

  /// §333 — pretty-print в изоляте: json5-парс сотен КБ в main isolate
  /// фризил открытие экрана.
  Future<void> _initLoad(String raw) async {
    final pretty = await prettyJsonForDisplayAsync(raw);
    if (!mounted) return;
    await _textController.setText(pretty);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await _textController.getText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Copied to clipboard"))),
    );
  }

  Future<void> _share() async {
    final text = (await _textController.getText()).trim();
    if (text.isEmpty) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/lxbox_config.json');
      await file.writeAsString(text);
      await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], text: 'LxBox config'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                getLocalText.s("Share failed: %s", formatUserError(e).render()))),
      );
    }
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
    final pretty = await prettyJsonForDisplayAsync(text);
    if (!mounted) return;
    await _textController.setText(pretty);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Pasted from clipboard"))),
    );
  }

  Future<void> _loadFromFile() async {
    try {
      // §372 — на устройстве без файлового менеджера (Android TV) подсказываем
      // буфер/URL вместо технической ошибки пикера.
      final outcome = await pickFileSafely();
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(problem)));
        }
        return;
      }
      final file = outcome.single;
      // §333 — utf8, не fromCharCodes (см. PickedFile.text).
      final text = file.text;
      final pretty = await prettyJsonForDisplayAsync(text.trim());
      if (!mounted) return;
      await _textController.setText(pretty);
    if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Loaded from file"))),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  getLocalText.s("Error: %s", formatUserError(e).render()))),
        );
      }
    }
  }

  Future<void> _save() async {
    final ok = await widget.controller
        .saveConfigRaw(await _textController.getText());
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Config saved. The next rebuild overwrites it; to keep it, lock the config in App Settings → Diagnostics (Debug API on)."))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final busy = widget.controller.state.busy;
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Text(getLocalText.s("Config")),
            actions: [
              TextButton(
                onPressed: (busy || _readOnly) ? null : _save,
                child: Text(getLocalText.s("Save")),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'paste': unawaited(_pasteFromClipboard());
                    case 'file': unawaited(_loadFromFile());
                    case 'copy': unawaited(_copy());
                    case 'share': unawaited(_share());
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'paste',
                      child: Text(getLocalText.s("Paste from clipboard"))),
                  PopupMenuItem(
                      value: 'file',
                      child: Text(getLocalText.s("Load from file"))),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                      value: 'copy',
                      child: Text(getLocalText.s("Copy to clipboard"))),
                  PopupMenuItem(
                      value: 'share', child: Text(getLocalText.s("Share"))),
                ],
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12).withSafeBottom(context),
            child: Column(
              children: [
                if (_readOnly)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      getLocalText.s(
                          "File is too large to edit on device. Share it, edit externally, then load it back."),
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                if (_loading) const LinearProgressIndicator(),
                Expanded(
                  // Прототип: нативный sora-editor вместо LxCodeEditor
                  // (re_editor отдаёт IME одну строку). Copy — в меню AppBar.
                  child: LxNativeCodeEditor(
                    controller: _textController,
                    readOnly: _readOnly,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
