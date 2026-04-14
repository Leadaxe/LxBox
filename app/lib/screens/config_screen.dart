import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/config_parse.dart';
import '../controllers/home_controller.dart';

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
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Future<void> _save() async {
    final ok = await widget.controller.saveConfigRaw(_textController.text);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Config saved')),
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
            title: const Text('Config'),
            actions: [
              IconButton(
                tooltip: 'Copy',
                onPressed: _copy,
                icon: const Icon(Icons.copy_outlined),
              ),
              TextButton(
                onPressed: busy ? null : _save,
                child: const Text('Save'),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'JSON or JSON5 (// and /* */ comments)',
                alignLabelWithHint: true,
              ),
            ),
          ),
        );
      },
    );
  }
}
