import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/config_parse.dart';
import '../controllers/home_controller.dart';
import '../services/error_format.dart';
import '../services/l10n/l10n.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: prettyJsonForDisplay(widget.controller.state.configRaw),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _textController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l.configCopiedToClipboard)),
    );
  }

  Future<void> _share() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/lxbox_config.json');
      await file.writeAsString(text);
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(file.path)], text: 'LxBox config');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                context.l.commonShareFailed(formatUserError(e).render(context.l)))),
      );
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.subClipboardEmpty)),
        );
      }
      return;
    }
    _textController.text = prettyJsonForDisplay(text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l.configPastedFromClipboard)),
      );
    }
  }

  Future<void> _loadFromFile() async {
    try {
      final result = await FilePicker.pickFiles(withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      String text;
      if (file.bytes != null && file.bytes!.isNotEmpty) {
        text = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        text = await File(file.path!).readAsString();
      } else {
        return;
      }
      _textController.text = prettyJsonForDisplay(text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.configLoadedFromFile)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  context.l.subErrorSnack(formatUserError(e).render(context.l)))),
        );
      }
    }
  }

  Future<void> _save() async {
    final ok = await widget.controller.saveConfigRaw(_textController.text);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l.configSavedSnack)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final busy = widget.controller.state.busy;
        return Scaffold(
          appBar: AppBar(
            title: Text(context.l.configTitle),
            actions: [
              TextButton(
                onPressed: busy ? null : _save,
                child: Text(context.l.commonSave),
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
                      child: Text(context.l.subMenuPasteFromClipboard)),
                  PopupMenuItem(
                      value: 'file',
                      child: Text(context.l.configMenuLoadFromFile)),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                      value: 'copy',
                      child: Text(context.l.configMenuCopyToClipboard)),
                  PopupMenuItem(
                      value: 'share', child: Text(context.l.commonShare)),
                ],
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: context.l.configEditorHint,
                    alignLabelWithHint: true,
                    contentPadding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: context.l.commonCopy,
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      // §219 — await + mounted перед snackbar (как _copy():40),
                      // иначе гонка Future/context.
                      await Clipboard.setData(
                          ClipboardData(text: _textController.text));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.l.configCopiedSnack)),
                      );
                    },
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
