import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/custom_rule.dart';
import '../services/builder/post_steps.dart';
import '../services/builder/rule_set_registry.dart';
import '../services/rule_set_downloader.dart';
import '../widgets/outbound_picker.dart';
import 'app_picker_screen.dart';

/// Редактор `CustomRule` (spec §030).
///
/// Все match-поля заполняются параллельно — sing-box внутри категории
/// (domain-family, port-family) матчит OR, между категориями AND. Правило
/// вида `domain_suffix=[.ru] & port=[443]` = "любой .ru домен И порт 443".
/// Протокол — отдельно, всегда AND (на routing rule level).
///
/// `kind=srs` — remote `.srs` rule_set по URL. Port/protocol всё равно
/// применяются (на routing rule level).
class CustomRuleEditScreen extends StatefulWidget {
  const CustomRuleEditScreen({
    super.key,
    required this.initial,
    required this.outboundOptions,
    required this.existingNames,
  });

  final CustomRule initial;
  final List<OutboundOption> outboundOptions;
  final Set<String> existingNames;

  @override
  State<CustomRuleEditScreen> createState() => _CustomRuleEditScreenState();
}

class _CustomRuleEditScreenState extends State<CustomRuleEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _domainCtrl;
  late final TextEditingController _domainSuffixCtrl;
  late final TextEditingController _domainKeywordCtrl;
  late final TextEditingController _ipCidrCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _portRangeCtrl;
  late final TextEditingController _srsUrlCtrl;

  late bool _enabled;
  late bool _ipIsPrivate;
  late CustomRuleKind _kind;
  late String _target;
  late Set<String> _protocols;
  late List<String> _packages;

  /// Состояние cloud-индикатора рядом с URL. Определяется на open
  /// (isCached) + меняется по клику (_downloadSrs).
  _SrsDownloadState _srsState = _SrsDownloadState.none;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _nameCtrl = TextEditingController(text: r.name);
    _domainCtrl = TextEditingController(text: r.domains.join('\n'));
    _domainSuffixCtrl = TextEditingController(text: r.domainSuffixes.join('\n'));
    _domainKeywordCtrl = TextEditingController(text: r.domainKeywords.join('\n'));
    _ipCidrCtrl = TextEditingController(text: r.ipCidrs.join('\n'));
    _portCtrl = TextEditingController(text: r.ports.join('\n'));
    _portRangeCtrl = TextEditingController(text: r.portRanges.join('\n'));
    _srsUrlCtrl = TextEditingController(text: r.srsUrl);
    _enabled = r.enabled;
    _ipIsPrivate = r.ipIsPrivate;
    _kind = r.kind;
    _target = r.target;
    _protocols = r.protocols.toSet();
    _packages = List.of(r.packages);
    if (_kind == CustomRuleKind.srs) {
      RuleSetDownloader.isCached(r.id).then((cached) {
        if (!mounted) return;
        setState(() => _srsState = cached
            ? _SrsDownloadState.cached
            : _SrsDownloadState.none);
      });
    }
  }

  /// Текущее состояние формы как `CustomRule` — используется для dirty-check
  /// при back без save. Не валидирует name-collision (это делает `_save`).
  CustomRule _snapshot() => widget.initial.copyWith(
        name: _nameCtrl.text.trim(),
        enabled: _enabled,
        kind: _kind,
        domains: _kind == CustomRuleKind.inline
            ? _normalizedDomains(_domainCtrl)
            : const [],
        domainSuffixes: _kind == CustomRuleKind.inline
            ? _normalizedDomains(_domainSuffixCtrl, stripLeadingDot: true)
            : const [],
        domainKeywords:
            _kind == CustomRuleKind.inline ? _normalizedKeywords() : const [],
        ipCidrs:
            _kind == CustomRuleKind.inline ? _normalizedCidrs() : const [],
        ports: _normalizedPorts(),
        portRanges: _normalizedPortRanges(),
        protocols: _protocols.toList()..sort(),
        packages: List.of(_packages),
        ipIsPrivate: _ipIsPrivate,
        srsUrl: _kind == CustomRuleKind.srs ? _srsUrlCtrl.text.trim() : '',
        target: _target,
      );

  bool _isDirty() =>
      jsonEncode(_snapshot().toJson()) !=
      jsonEncode(widget.initial.toJson());

  /// Обработчик back (system + AppBar leading). Если unsaved — confirm.
  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved changes. Leave without saving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  Future<void> _downloadSrs() async {
    final url = _srsUrlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _srsState = _SrsDownloadState.loading);
    final path = await RuleSetDownloader.download(widget.initial.id, url);
    if (!mounted) return;
    setState(() => _srsState =
        path != null ? _SrsDownloadState.cached : _SrsDownloadState.error);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _domainCtrl.dispose();
    _domainSuffixCtrl.dispose();
    _domainKeywordCtrl.dispose();
    _ipCidrCtrl.dispose();
    _portCtrl.dispose();
    _portRangeCtrl.dispose();
    _srsUrlCtrl.dispose();
    super.dispose();
  }

  // ─── Парсинг/нормализация полей ────────────────────────────────────────

  /// Split по `\n` и `,` — оба разделителя поддерживаются, чтобы юзер мог
  /// вставлять из clipboard любой формы.
  List<String> _splitRaw(String text) => text
      .split(RegExp(r'[\n,]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _normalizedDomains(TextEditingController c, {bool stripLeadingDot = false}) {
    return _splitRaw(c.text).map((s) {
      var v = s.toLowerCase();
      if (v.startsWith('http://')) v = v.substring(7);
      if (v.startsWith('https://')) v = v.substring(8);
      if (v.endsWith('/')) v = v.substring(0, v.length - 1);
      if (stripLeadingDot && v.startsWith('.')) v = v.substring(1);
      return v;
    }).where((s) => s.isNotEmpty).toList();
  }

  List<String> _normalizedKeywords() =>
      _splitRaw(_domainKeywordCtrl.text).map((s) => s.toLowerCase()).toList();

  List<String> _normalizedCidrs() => _splitRaw(_ipCidrCtrl.text).map((s) {
        if (!s.contains('/')) return s.contains(':') ? '$s/128' : '$s/32';
        return s;
      }).toList();

  List<String> _normalizedPorts() => _splitRaw(_portCtrl.text);
  List<String> _normalizedPortRanges() => _splitRaw(_portRangeCtrl.text);

  // ─── Валидация per-field ──────────────────────────────────────────────

  bool _isValidDomain(String v) => RegExp(
        r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
      ).hasMatch(v);

  bool _isValidKeyword(String v) => v.isNotEmpty && !v.contains(RegExp(r'\s'));

  bool _isValidCidr(String v) {
    final parts = v.split('/');
    if (parts.length != 2) return false;
    final mask = int.tryParse(parts[1]);
    if (mask == null) return false;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(parts[0])) {
      if (mask < 0 || mask > 32) return false;
      return parts[0].split('.').every((o) {
        final n = int.tryParse(o);
        return n != null && n >= 0 && n <= 255;
      });
    }
    if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(parts[0]) && parts[0].contains(':')) {
      return mask >= 0 && mask <= 128;
    }
    return false;
  }

  bool _isValidPort(String v) {
    final n = int.tryParse(v);
    return n != null && n >= 0 && n <= 65535;
  }

  bool _isValidPortRange(String v) {
    // "8000:9000", ":3000", "4000:"
    final m = RegExp(r'^(\d*):(\d*)$').firstMatch(v);
    if (m == null) return false;
    final lo = m.group(1)!;
    final hi = m.group(2)!;
    if (lo.isEmpty && hi.isEmpty) return false;
    int? loN, hiN;
    if (lo.isNotEmpty) {
      loN = int.tryParse(lo);
      if (loN == null || loN < 0 || loN > 65535) return false;
    }
    if (hi.isNotEmpty) {
      hiN = int.tryParse(hi);
      if (hiN == null || hiN < 0 || hiN > 65535) return false;
    }
    if (loN != null && hiN != null && loN > hiN) return false;
    return true;
  }

  bool _isValidUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }

  int _invalidCount(TextEditingController ctrl, bool Function(String) isValid,
      {String Function(String)? normalize}) {
    var n = 0;
    for (final raw in _splitRaw(ctrl.text)) {
      final v = normalize != null ? normalize(raw) : raw;
      if (!isValid(v)) n++;
    }
    return n;
  }

  // ─── Actions ──────────────────────────────────────────────────────────

  Future<void> _pasteInto(TextEditingController ctrl) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
        );
      }
      return;
    }
    final existing = ctrl.text.trim();
    ctrl.text = existing.isEmpty ? text : '$existing\n$text';
    setState(() {});
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required')),
      );
      return;
    }
    String finalName = name;
    if (widget.existingNames.contains(name)) {
      var i = 2;
      while (widget.existingNames.contains('$name ($i)')) {
        i++;
      }
      finalName = '$name ($i)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Name in use — renamed to "$finalName"')),
      );
    }

    final saved = widget.initial.copyWith(
      name: finalName,
      enabled: _enabled,
      kind: _kind,
      domains: _kind == CustomRuleKind.inline
          ? _normalizedDomains(_domainCtrl)
          : const [],
      domainSuffixes: _kind == CustomRuleKind.inline
          ? _normalizedDomains(_domainSuffixCtrl, stripLeadingDot: true)
          : const [],
      domainKeywords:
          _kind == CustomRuleKind.inline ? _normalizedKeywords() : const [],
      ipCidrs:
          _kind == CustomRuleKind.inline ? _normalizedCidrs() : const [],
      ports: _normalizedPorts(),
      portRanges: _normalizedPortRanges(),
      protocols: _protocols.toList()..sort(),
      packages: List.of(_packages),
      ipIsPrivate: _ipIsPrivate,
      srsUrl: _kind == CustomRuleKind.srs ? _srsUrlCtrl.text.trim() : '',
      target: _target,
    );
    Navigator.pop(context, _CustomRuleEditResult.saved(saved));
  }

  /// Контекстное меню для cloud-иконки URL'а (long-press).
  /// - Refresh SRS = тот же `_downloadSrs` что и tap
  /// - Clear cache = удалить локальный `.srs` файл, не трогая правило.
  ///   После очистки `_enabled` сбрасывается в false — без cache правило
  ///   не может работать, switch в UI тоже заблокируется.
  Future<void> _showCloudMenu(Offset pos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'refresh',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh, size: 20),
            title: Text('Refresh SRS'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'clear',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cloud_off_outlined,
                size: 20, color: Theme.of(context).colorScheme.error),
            title: Text('Clear cached file',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'refresh':
        unawaited(_downloadSrs());
      case 'clear':
        await RuleSetDownloader.delete(widget.initial.id);
        if (!mounted) return;
        setState(() {
          _srsState = _SrsDownloadState.none;
          _enabled = false;
        });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete rule?'),
        content: Text('Remove "${widget.initial.name}" permanently?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, _CustomRuleEditResult.deleted());
    }
  }

  // ─── Widgets ──────────────────────────────────────────────────────────

  Widget _sectionHeader(ThemeData t, String title, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: t.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: t.colorScheme.primary,
              )),
          Text(hint,
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              )),
        ],
      ),
    );
  }

  Widget _itemsField(
    ThemeData t, {
    required String label,
    required TextEditingController controller,
    required int invalid,
    int minLines = 2,
    int maxLines = 5,
    String? hint,
  }) {
    final count = _splitRaw(controller.text).length;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: t.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
              ),
              Text(
                invalid == 0
                    ? (count == 0 ? '' : '$count')
                    : '$count · $invalid invalid',
                style: TextStyle(
                  fontSize: 12,
                  color: invalid > 0
                      ? t.colorScheme.error
                      : t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            onChanged: (_) => setState(() {}),
            minLines: minLines,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.content_paste, size: 14),
                label: const Text('Paste', style: TextStyle(fontSize: 12)),
                onPressed: () => _pasteInto(controller),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.clear, size: 14),
                label: const Text('Clear', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  controller.clear();
                  setState(() {});
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _protocolSection(ThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t, 'PROTOCOL', 'AND with match. L7 sniff.'),
        Wrap(
          spacing: 4,
          runSpacing: -8,
          children: kKnownProtocols.map((p) {
            final checked = _protocols.contains(p);
            return SizedBox(
              width: 160,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: Text(p,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace')),
                value: checked,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _protocols.add(p);
                    } else {
                      _protocols.remove(p);
                    }
                  });
                },
              ),
            );
          }).toList(),
        ),
        if (_protocols.isNotEmpty)
          Text('${_protocols.length} selected',
              style: TextStyle(
                  fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Future<void> _openAppPicker() async {
    final result = await Navigator.push<AppPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(selected: _packages.toSet()),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _packages = result.packages);
  }

  Widget _appsSection(ThemeData t) {
    final label = _packages.isEmpty
        ? 'Select apps…'
        : '${_packages.length} ${_packages.length == 1 ? 'app' : 'apps'} selected — tap to edit';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t, 'APPS', 'AND with match. Route selected packages only.'),
        InkWell(
          onTap: _openAppPicker,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.apps, size: 18, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                        fontSize: 13,
                        color: _packages.isEmpty
                            ? t.colorScheme.onSurfaceVariant
                            : t.colorScheme.primary,
                      )),
                ),
                if (_packages.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear',
                    onPressed: () => setState(() => _packages = []),
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _portSection(ThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t, 'PORT', 'AND with match. Port OR port_range.'),
        _itemsField(
          t,
          label: 'Port (exact)',
          controller: _portCtrl,
          invalid: _invalidCount(_portCtrl, _isValidPort),
          hint: '443\n80',
        ),
        _itemsField(
          t,
          label: 'Port range',
          controller: _portRangeCtrl,
          invalid: _invalidCount(_portRangeCtrl, _isValidPortRange),
          hint: '8000:9000\n:3000',
        ),
      ],
    );
  }

  Widget _matchSection(ThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          t,
          'MATCH',
          'Fields work in parallel (OR — any match wins).',
        ),
        _itemsField(
          t,
          label: 'Domain (exact)',
          controller: _domainCtrl,
          invalid: _invalidCount(_domainCtrl, _isValidDomain,
              normalize: (s) => s.toLowerCase()),
          hint: 'example.com',
        ),
        _itemsField(
          t,
          label: 'Domain suffix',
          controller: _domainSuffixCtrl,
          invalid: _invalidCount(_domainSuffixCtrl, _isValidDomain,
              normalize: (s) {
            var v = s.toLowerCase();
            if (v.startsWith('.')) v = v.substring(1);
            return v;
          }),
          hint: 'google.com\n.ru',
        ),
        _itemsField(
          t,
          label: 'Domain keyword',
          controller: _domainKeywordCtrl,
          invalid: _invalidCount(_domainKeywordCtrl, _isValidKeyword),
          hint: 'tracker\nanalytics',
        ),
        _itemsField(
          t,
          label: 'IP CIDR',
          controller: _ipCidrCtrl,
          invalid: _invalidCount(_ipCidrCtrl, _isValidCidr,
              normalize: (s) {
            if (!s.contains('/')) return s.contains(':') ? '$s/128' : '$s/32';
            return s;
          }),
          hint: '10.0.0.0/8\n2001:db8::/32',
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _ipIsPrivate,
          onChanged: (v) => setState(() => _ipIsPrivate = v ?? false),
          title: const Text('Private IP',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: const Text(
              'Match RFC1918 (10/8, 172.16/12, 192.168/16) + loopback + link-local',
              style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  Widget _srsSection(ThemeData t) {
    final url = _srsUrlCtrl.text.trim();
    final urlValid = url.isNotEmpty && _isValidUrl(url);

    Widget cloud;
    if (_srsState == _SrsDownloadState.loading) {
      cloud = const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    } else {
      final (IconData icon, Color color) = switch (_srsState) {
        _SrsDownloadState.cached => (Icons.cloud_done_outlined, Colors.green),
        _SrsDownloadState.error =>
          (Icons.cloud_off_outlined, t.colorScheme.error),
        _SrsDownloadState.none || _SrsDownloadState.loading =>
          (Icons.cloud_download_outlined, t.colorScheme.onSurfaceVariant),
      };
      // GestureDetector (не IconButton) — чтобы long-press не перехватывался
      // IconButton'ом. Long-press → popup menu Refresh / Delete rule.
      cloud = GestureDetector(
        onTap: urlValid ? _downloadSrs : null,
        onLongPressStart: (d) => _showCloudMenu(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 20),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          t,
          'RULE-SET URL',
          'Manual download only. Tap ☁ to fetch the .srs file locally.',
        ),
        TextField(
          controller: _srsUrlCtrl,
          onChanged: (_) {
            // Пользователь меняет URL — старый cached-файл для этого URL
            // становится условно stale, но ui-state сбрасываем только если
            // был 'error' (чтобы юзер мог опять попробовать после правки).
            setState(() {
              if (_srsState == _SrsDownloadState.error) {
                _srsState = _SrsDownloadState.none;
              }
            });
          },
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: 'https://example.com/rules.srs',
            prefixIcon: IconButton(
              icon: const Icon(Icons.link, size: 18),
              tooltip: 'Copy URL',
              onPressed: () async {
                final text = _srsUrlCtrl.text.trim();
                if (text.isEmpty) return;
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL copied')),
                );
              },
            ),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: cloud,
            ),
          ),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          icon: const Icon(Icons.content_paste, size: 14),
          label: const Text('Paste', style: TextStyle(fontSize: 12)),
          onPressed: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = (data?.text ?? '').trim();
            if (text.isEmpty) return;
            _srsUrlCtrl.text = text;
            setState(() {});
          },
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dirty = _isDirty();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('Edit rule'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBack,
        ),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: Icon(Icons.save,
                color: dirty ? theme.colorScheme.primary : null),
            onPressed: _save,
          ),
        ],
        bottom: const TabBar(
          tabs: [Tab(text: 'Params'), Tab(text: 'View')],
        ),
      ),
      body: TabBarView(
        children: [
          _buildParamsTab(theme),
          _buildJsonTab(theme),
        ],
      ),
        ),
      ),
    );
  }

  Widget _buildParamsTab(ThemeData theme) {
    return ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Name',
                    isDense: true,
                    prefixIcon: Icon(Icons.label_outline, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: _enabled,
                // srs без кэша — нельзя включить, сначала Download.
                onChanged: (_kind == CustomRuleKind.srs &&
                        _srsState != _SrsDownloadState.cached)
                    ? null
                    : (v) => setState(() => _enabled = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutboundPicker(
            value: _target,
            options: widget.outboundOptions,
            onChanged: (v) => setState(() => _target = v),
            dense: false,
            label: 'Action',
          ),
          const SizedBox(height: 16),
          const Divider(),
          _appsSection(theme),
          const SizedBox(height: 8),
          const Divider(),
          Text('Source', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          RadioGroup<CustomRuleKind>(
            groupValue: _kind,
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _kind = v;
                // Переключение на srs без кэша → правило нельзя держать
                // включённым, сбрасываем _enabled.
                if (_kind == CustomRuleKind.srs &&
                    _srsState != _SrsDownloadState.cached) {
                  _enabled = false;
                }
              });
            },
            child: Row(
              children: [
                Expanded(
                  child: RadioListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: CustomRuleKind.inline,
                    title: const Text('Inline'),
                  ),
                ),
                Expanded(
                  child: RadioListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: CustomRuleKind.srs,
                    title: const Text('Remote (.srs)'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          if (_kind == CustomRuleKind.inline) _matchSection(theme),
          if (_kind == CustomRuleKind.srs) _srsSection(theme),
          _portSection(theme),
          _protocolSection(theme),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_outline,
                size: 18, color: theme.colorScheme.error),
            label: Text('Delete rule',
                style: TextStyle(color: theme.colorScheme.error)),
            onPressed: _delete,
          ),
        ],
      );
  }

  Widget _buildJsonTab(ThemeData theme) {
    String json;
    List<String> warnings = const [];
    try {
      final reg = RuleSetRegistry();
      // Всегда подставляем плейсхолдер — чтобы preview отображал структуру
      // даже для не-скачанных srs-правил (юзер видит "что будет" после
      // download'а). Реальный путь живёт в build_config'е runtime'а.
      final srsPaths = <String, String>{};
      if (_kind == CustomRuleKind.srs) {
        srsPaths[widget.initial.id] = _srsState == _SrsDownloadState.cached
            ? '<cached file path>'
            : '<download first>';
      }
      warnings = applyCustomRules(reg, [_snapshot()], srsPaths: srsPaths);
      json = const JsonEncoder.withIndent('  ').convert({
        'rule_set': reg.getRuleSets(),
        'rules': reg.getRules(),
      });
    } catch (e) {
      json = '// error: $e';
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('sing-box config preview',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              TextButton.icon(
                icon: const Icon(Icons.content_copy, size: 14),
                label: const Text('Copy', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: json));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (warnings.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(warnings.join('\n'),
                  style:
                      TextStyle(fontSize: 12, color: theme.colorScheme.error)),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SrsDownloadState { none, loading, cached, error }

/// Результат редактора — либо сохранение, либо удаление.
class _CustomRuleEditResult {
  const _CustomRuleEditResult._({this.saved, this.wasDeleted = false});
  final CustomRule? saved;
  final bool wasDeleted;

  factory _CustomRuleEditResult.saved(CustomRule rule) =>
      _CustomRuleEditResult._(saved: rule);
  factory _CustomRuleEditResult.deleted() =>
      const _CustomRuleEditResult._(wasDeleted: true);
}

/// Публичный wrapper для использования в RoutingScreen.
class CustomRuleEditResult {
  const CustomRuleEditResult._internal(this._inner);
  final _CustomRuleEditResult _inner;

  CustomRule? get saved => _inner.saved;
  bool get wasDeleted => _inner.wasDeleted;
}

Future<CustomRuleEditResult?> openCustomRuleEditor(
  BuildContext context, {
  required CustomRule initial,
  required List<OutboundOption> outboundOptions,
  required Set<String> existingNames,
}) async {
  final result = await Navigator.push<_CustomRuleEditResult>(
    context,
    MaterialPageRoute(
      builder: (_) => CustomRuleEditScreen(
        initial: initial,
        outboundOptions: outboundOptions,
        existingNames: existingNames,
      ),
    ),
  );
  if (result == null) return null;
  return CustomRuleEditResult._internal(result);
}
