import 'dart:async';

import 'package:flutter/material.dart';

import '../models/tls_policy.dart';
import '../services/core_duration.dart';
import '../services/l10n/locale_controller.dart';
import '../services/settings_storage.dart';

/// §636 — откуда наследуется поле TLS-политики.
enum TlsLevel { global, folder, subscription }

/// §636 — строки секции TLS (экран узла, вкладка настроек подписки/папки):
/// четыре ручки раздела «TLS Fragmentation», тап → диалог, выбор пишется
/// сразу через [onChanged]. [inherited] — политика уровня выше (у члена
/// папки — папочная) с уровнем [inheritedLevel]; не заданное там поле
/// наследуется из глобальных `vars`.
class TlsPolicyTiles extends StatefulWidget {
  const TlsPolicyTiles({
    super.key,
    required this.policy,
    required this.onChanged,
    this.inherited = TlsPolicy.none,
    this.inheritedLevel = TlsLevel.global,
  });

  final TlsPolicy policy;
  final TlsPolicy inherited;
  final TlsLevel inheritedLevel;
  final ValueChanged<TlsPolicy> onChanged;

  @override
  State<TlsPolicyTiles> createState() => _TlsPolicyTilesState();
}

const _kDefaultDelay = '500ms';

class _TlsPolicyTilesState extends State<TlsPolicyTiles> {
  Map<String, String> _vars = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadVars());
  }

  Future<void> _loadVars() async {
    try {
      final v = await SettingsStorage.getAllVars();
      if (mounted) setState(() => _vars = v);
    } catch (_) {
      // Глобальные значения не прочитались — подпись по умолчаниям шаблона.
    }
  }

  /// Унаследованное значение bool-поля и уровень, с которого оно пришло.
  (bool, TlsLevel) _inheritedBool(bool? fromAbove, String varName) =>
      fromAbove != null
          ? (fromAbove, widget.inheritedLevel)
          : (_vars[varName] == 'true', TlsLevel.global);

  String get _inheritedDelay {
    final above = widget.inherited.fallbackDelay;
    final raw = above ?? _vars['tls_fragment_fallback_delay'] ?? '';
    return parseCoreDurationNanos(raw) == null ? _kDefaultDelay : raw;
  }

  String _defaultLabel((bool, TlsLevel) v) => switch (v) {
        (true, TlsLevel.global) => getLocalText.s("Default (On — global)"),
        (false, TlsLevel.global) => getLocalText.s("Default (Off — global)"),
        (true, TlsLevel.folder) => getLocalText.s("Default (On — folder)"),
        (false, TlsLevel.folder) => getLocalText.s("Default (Off — folder)"),
        (true, TlsLevel.subscription) =>
          getLocalText.s("Default (On — subscription)"),
        (false, TlsLevel.subscription) =>
          getLocalText.s("Default (Off — subscription)"),
      };

  String _inheritedLabel((bool, TlsLevel) v) => switch (v) {
        (true, TlsLevel.global) => getLocalText.s("Inherited: On (global)"),
        (false, TlsLevel.global) => getLocalText.s("Inherited: Off (global)"),
        (true, TlsLevel.folder) => getLocalText.s("Inherited: On (folder)"),
        (false, TlsLevel.folder) => getLocalText.s("Inherited: Off (folder)"),
        (true, TlsLevel.subscription) =>
          getLocalText.s("Inherited: On (subscription)"),
        (false, TlsLevel.subscription) =>
          getLocalText.s("Inherited: Off (subscription)"),
      };

  void _set(String key, Object? value) =>
      widget.onChanged(widget.policy.patched({key: value}));

  Widget _boolTile({
    required String keyName,
    required IconData icon,
    required String title,
    required bool? value,
    required bool? fromAbove,
    required String varName,
  }) {
    final inherited = _inheritedBool(fromAbove, varName);
    return ListTile(
      key: ValueKey('tls-$keyName'),
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(switch (value) {
        null => _defaultLabel(inherited),
        true => getLocalText.s("On"),
        false => getLocalText.s("Off"),
      }),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => unawaited(_pickBool(keyName, title, value, inherited)),
    );
  }

  Future<void> _pickBool(String keyName, String title, bool? current,
      (bool, TlsLevel) inherited) async {
    // 0 — Default, 1 — On, 2 — Off.
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<int>(
            groupValue: switch (current) { null => 0, true => 1, false => 2 },
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<int>(
                  key: ValueKey('tls-$keyName-default'),
                  value: 0,
                  title: Text(getLocalText.s("Default")),
                  subtitle: Text(_inheritedLabel(inherited)),
                ),
                RadioListTile<int>(
                  key: ValueKey('tls-$keyName-on'),
                  value: 1,
                  title: Text(getLocalText.s("On")),
                ),
                RadioListTile<int>(
                  key: ValueKey('tls-$keyName-off'),
                  value: 2,
                  title: Text(getLocalText.s("Off")),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    final next = switch (picked) { 1 => true, 2 => false, _ => null };
    if (next == current) return;
    _set(keyName, next);
  }

  Future<void> _pickDelay() async {
    final result = await showDialog<_DelayChoice>(
      context: context,
      builder: (_) => _DelayDialog(initial: widget.policy.fallbackDelay ?? ''),
    );
    if (result == null) return;
    if (result.value == widget.policy.fallbackDelay) return;
    _set('fallback_delay', result.value);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.policy;
    final up = widget.inherited;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _boolTile(
          keyName: 'fragment',
          icon: Icons.call_split,
          title: getLocalText.s("Split ClientHello into TCP segments"),
          value: p.fragment,
          fromAbove: up.fragment,
          varName: 'tls_fragment',
        ),
        _boolTile(
          keyName: 'record_fragment',
          icon: Icons.layers_outlined,
          title: getLocalText.s("Split handshake into TLS records"),
          value: p.recordFragment,
          fromAbove: up.recordFragment,
          varName: 'tls_record_fragment',
        ),
        ListTile(
          key: const ValueKey('tls-fallback_delay'),
          leading: const Icon(Icons.timer_outlined, size: 20),
          title: Text(getLocalText.s("Fallback delay")),
          subtitle: Text(p.fallbackDelay ??
              getLocalText.s("Default (%s)", _inheritedDelay)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_pickDelay()),
        ),
        _boolTile(
          keyName: 'mixed_case_sni',
          icon: Icons.text_fields,
          title: getLocalText.s("Mixed-case SNI"),
          value: p.mixedCaseSni,
          fromAbove: up.mixedCaseSni,
          varName: 'tls_mixed_case_sni',
        ),
      ],
    );
  }
}

/// Итог диалога паузы: `null` в [value] — «наследовать».
class _DelayChoice {
  const _DelayChoice(this.value);
  final String? value;
}

class _DelayDialog extends StatefulWidget {
  const _DelayDialog({required this.initial});
  final String initial;

  @override
  State<_DelayDialog> createState() => _DelayDialogState();
}

class _DelayDialogState extends State<_DelayDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    // Та же проверка, что в сборке (§606): ядро такую строку разберёт.
    if (parseCoreDurationNanos(v) == null) {
      setState(() =>
          _error = getLocalText.s("Enter a duration like 500ms or 1s"));
      return;
    }
    Navigator.pop(context, _DelayChoice(v));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(getLocalText.s("Fallback delay")),
        content: TextField(
          key: const ValueKey('tls-fallback_delay-field'),
          controller: _ctrl,
          autofocus: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: _kDefaultDelay,
            errorText: _error,
            isDense: true,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
            key: const ValueKey('tls-fallback_delay-default'),
            onPressed: () => Navigator.pop(context, const _DelayChoice(null)),
            child: Text(getLocalText.s("Use default")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(getLocalText.s("Cancel")),
          ),
          TextButton(
            onPressed: _submit,
            child: Text(getLocalText.s("OK")),
          ),
        ],
      );
}
