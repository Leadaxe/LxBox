import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/builder/post_steps.dart';
import '../services/builder/preset_expand.dart';
import '../services/builder/rule_set_registry.dart';
import '../services/relative_time.dart';
import '../services/rule_set_downloader.dart';
import '../services/settings_storage.dart';
import '../services/url_launcher.dart' as ul;
import '../widgets/outbound_picker.dart';
import '../widgets/wifi_permission_dialog.dart';
import 'app_picker_screen.dart';
import 'app_settings_screen.dart';

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
    this.preset,
  });

  final CustomRule initial;
  final List<OutboundOption> outboundOptions;
  final Set<String> existingNames;

  /// Bundle-пресет (spec §033). Обязателен когда `initial.kind == preset` —
  /// форма рендерит его `vars` для юзер-ввода. Null для preset-правила =
  /// broken-preset (пресет удалён/переименован в шаблоне) — показываем
  /// fallback-экран с Delete.
  final SelectableRule? preset;

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
  late String _outbound;
  late Set<String> _protocols;
  late List<String> _packages;
  // §051 Phase 2 — list of (ssid, bssid?) entries shown as chips. Каждая
  // chip = одна Wi-Fi сеть. На save распадается на `wifiSsids`/`wifiBssids`
  // через _zipWifiEntries(). На load — pair by index если counts равны,
  // иначе ssid-only chips + остаток bssid'ов как chips без ssid (rare edge).
  late List<_WifiEntry> _wifiNetworks;

  /// Значения preset-vars (spec §033). Для kind != preset — пустая мапа,
  /// игнорируется при save.
  late Map<String, String> _varsValues;

  /// Кэш-пути remote rule_set'ов пресета (tag → абсолютный путь), pre-
  /// resolved в initState. Без этого View tab всегда бы ругался «no cached
  /// file» даже для скачанного пресета (task 011).
  Map<String, String> _presetSrsPaths = const {};

  /// Состояние cloud-индикатора рядом с URL. Определяется на open
  /// (isCached) + меняется по клику (_downloadSrs).
  _SrsDownloadState _srsState = _SrsDownloadState.none;

  /// §045: bool var'ы у которых сейчас идёт on-toggle download связанных
  /// rule_set'ов. Нужно чтобы Switch был disabled (показывал spinner)
  /// пока качается, иначе юзер может несколько раз тыкнуть.
  final Set<String> _boolVarDownloading = <String>{};

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
    _outbound = r.outbound;
    _protocols = r.protocols.toSet();
    _packages = List.of(r.packages);
    _wifiNetworks = _unzipWifiEntries(r.wifiSsids, r.wifiBssids);
    _varsValues = Map<String, String>.from(r.varsValues);
    if (_kind == CustomRuleKind.srs) {
      RuleSetDownloader.isCached(r.id).then((cached) {
        if (!mounted) return;
        setState(() => _srsState = cached
            ? _SrsDownloadState.cached
            : _SrsDownloadState.none);
      });
    }
    if (r is CustomRulePreset && widget.preset != null) {
      _resolvePresetSrsPaths(r, widget.preset!);
    }
  }

  /// Async-prefetch cached paths для remote rule_set'ов пресета.
  /// Результат → `_presetSrsPaths` → передаётся в `expandPreset` при
  /// рендере View tab. Без этого JSON preview показывал warnings «no
  /// cached file» даже для скачанного пресета (task 011).
  Future<void> _resolvePresetSrsPaths(
      CustomRulePreset rule, SelectableRule preset) async {
    final paths = <String, String>{};
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      if (tag is! String || tag.isEmpty) continue;
      final p = await RuleSetDownloader.cachedPathForPreset(rule.presetId, tag);
      if (p != null) paths[tag] = p;
    }
    if (!mounted) return;
    setState(() => _presetSrsPaths = paths);
  }

  /// Текущее состояние формы как `CustomRule` — используется для dirty-check
  /// при back без save. Не валидирует name-collision (это делает `_save`).
  ///
  /// Возвращает конкретный subclass в зависимости от `_kind` state:
  /// - `preset` → обновляем `CustomRulePreset` ((re-use presetId из initial)
  /// - `srs` → `CustomRuleSrs`
  /// - `inline` → `CustomRuleInline`
  ///
  /// Переключение между inline↔srs в редакторе создаёт новый экземпляр
  /// соответствующего типа с сохранённым `id` (чтобы кэш SRS не перепутался,
  /// URL и cache сбрасываются при kindChanged в caller'е).
  CustomRule _snapshot() {
    final name = _nameCtrl.text.trim();
    switch (_kind) {
      case CustomRuleKind.preset:
        final initial = widget.initial;
        return CustomRulePreset(
          id: initial.id,
          name: name,
          enabled: _enabled,
          presetId: initial is CustomRulePreset ? initial.presetId : '',
          varsValues: Map<String, String>.from(_varsValues),
        );
      case CustomRuleKind.srs:
        final wifi = _zipWifiEntries(_wifiNetworks);
        return CustomRuleSrs(
          id: widget.initial.id,
          name: name,
          enabled: _enabled,
          srsUrl: _srsUrlCtrl.text.trim(),
          ports: _normalizedPorts(),
          portRanges: _normalizedPortRanges(),
          packages: List.of(_packages),
          protocols: _protocols.toList()..sort(),
          ipIsPrivate: _ipIsPrivate,
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
        );
      case CustomRuleKind.inline:
        final wifi = _zipWifiEntries(_wifiNetworks);
        return CustomRuleInline(
          id: widget.initial.id,
          name: name,
          enabled: _enabled,
          domains: _normalizedDomains(_domainCtrl),
          domainSuffixes:
              _normalizedDomains(_domainSuffixCtrl, stripLeadingDot: true),
          domainKeywords: _normalizedKeywords(),
          ipCidrs: _normalizedCidrs(),
          ports: _normalizedPorts(),
          portRanges: _normalizedPortRanges(),
          packages: List.of(_packages),
          protocols: _protocols.toList()..sort(),
          ipIsPrivate: _ipIsPrivate,
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
        );
    }
  }

  bool _isDirty() =>
      jsonEncode(_snapshot().toJson()) !=
      jsonEncode(widget.initial.toJson());

  /// Обработчик back (system + AppBar leading). Если unsaved — confirm
  /// с тремя опциями: Save (сохраняет + закрывает), Keep editing (dismiss),
  /// Discard (закрывает без сохранения).
  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Unsaved changes'),
          content:
              const Text('You have unsaved changes. Save before leaving?'),
          // §045-followup: все TextButton'ы + короткие надписи →
          // вмещаются в строку. FilledButton + длинная "Keep editing"
          // forced wrap в столбец на типичных phone widths.
          // §045: все TextButton'ы + короткие надписи → влезают в строку
          // на phone width. FilledButton + "Keep editing" forced wrap.
          actionsPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: const Text('Discard'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('Keep'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              style: TextButton.styleFrom(
                foregroundColor: cs.primary,
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (action == 'save') {
      _save(); // сам сделает Navigator.pop при успехе
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null — остаёмся на экране
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

  /// §051 Phase 2 — BSSID `xx:xx:xx:xx:xx:xx` (case-insensitive). Empty
  /// допустимо (chip может быть только с SSID).
  static final RegExp _bssidPattern =
      RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');
  bool _isValidBssid(String v) =>
      v.isEmpty || _bssidPattern.hasMatch(v.trim());

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

  Future<void> _save() async {
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

    // §051 Phase 2 — preflight permission check если у правила есть wifi
    // условия. Без NEARBY_WIFI_DEVICES + ACCESS_BACKGROUND_LOCATION sing-box
    // не сможет прочитать SSID и rule не сматчится. Лучше предупредить
    // СЕЙЧАС чем юзер удивится «правило сохранил а не работает».
    if (_wifiNetworks.isNotEmpty) {
      final missing = <String>[];
      if (!await ul.UrlLauncher.checkBackgroundLocationPermission()) {
        missing.add('android.permission.ACCESS_BACKGROUND_LOCATION');
      }
      if (!await ul.UrlLauncher.checkNearbyWifiPermission()) {
        missing.add('android.permission.NEARBY_WIFI_DEVICES');
      }
      if (missing.isNotEmpty && mounted) {
        await WifiPermissionDialog.show(context, missing: missing);
        // Не блокируем save — юзер мог нажать «Allow Wi-Fi info» и нам
        // надо сохранить правило в любом случае. Permission'ы прорастут
        // при следующем connect (или сразу если runtime grant прошёл).
      }
    }

    if (!mounted) return;
    // _snapshot() строит подкласс по `_kind`, нам остаётся только
    // применить финальный `name` (возможно с auto-suffix'ом).
    final saved = _snapshot().withName(finalName);
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

  /// §051 Phase 2 — chip-based WI-FI NETWORK section.
  ///
  /// Chip = одна сеть `(ssid, bssid?)`. Source-of-truth — `_wifiNetworks`.
  /// Save zip'ит в `wifiSsids`/`wifiBssids` через _zipWifiEntries (см.
  /// CustomRule §051: lists независимы в sing-box, AND-семантика).
  Widget _wifiSection(ThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          t,
          'WI-FI NETWORK',
          'AND with match. Active only on listed Wi-Fi networks.',
        ),
        if (_wifiNetworks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'No Wi-Fi conditions — rule is active on every network.',
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (var i = 0; i < _wifiNetworks.length; i++)
                InputChip(
                  avatar: const Icon(Icons.wifi, size: 16),
                  label: Text(
                    _wifiNetworks[i].bssid.isEmpty
                        ? _wifiNetworks[i].ssid
                        : '${_wifiNetworks[i].ssid}  ·  ${_wifiNetworks[i].bssid}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onDeleted: () =>
                      setState(() => _wifiNetworks.removeAt(i)),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.my_location, size: 16),
              label: const Text('Add current'),
              onPressed: _addCurrentWifi,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.history, size: 16),
              label: const Text('Pick saved'),
              onPressed: _pickSavedWifi,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Manual'),
              onPressed: _manualAddWifi,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: _openWifiPermissionsScreen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Needs Location + Nearby Wi-Fi permissions. Tap to manage.',
                    style: TextStyle(
                      fontSize: 11,
                      color: t.colorScheme.onSurfaceVariant,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// «Add current»: читает текущий SSID/BSSID, дописывает в chips,
  /// upsert'ит в wifi_history. Permission missing → shared dialog.
  Future<void> _addCurrentWifi() async {
    final result = await ul.UrlLauncher.getCurrentWifiInfo();
    if (!mounted) return;
    switch (result) {
      case ul.WifiInfoSuccess(:final ssid, :final bssid):
        // Дедуп: если уже есть chip с тем же ssid+bssid — skip.
        final exists = _wifiNetworks
            .any((e) => e.ssid == ssid && e.bssid == bssid);
        if (!exists) {
          setState(() => _wifiNetworks.add(_WifiEntry(ssid, bssid)));
        }
        await SettingsStorage.addToWifiHistory(ssid, bssid);
      case ul.WifiInfoError(:final reason):
        if (reason == 'permission_missing') {
          await WifiPermissionDialog.show(
            context,
            missing: const [
              'android.permission.ACCESS_BACKGROUND_LOCATION',
              'android.permission.NEARBY_WIFI_DEVICES',
            ],
          );
          return;
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            content: Text(switch (reason) {
              'no_wifi' => 'Not connected to Wi-Fi.',
              'unknown_ssid' =>
                'Cannot read Wi-Fi info — try toggling Wi-Fi off/on.',
              _ => 'Could not read current Wi-Fi ($reason).',
            }),
          ),
        );
    }
  }

  /// «Pick saved»: bottom sheet — networks из других rules + history.
  Future<void> _pickSavedWifi() async {
    // Собираем «used in your rules»: scan через все custom_rules,
    // exclude текущее правило (его сети уже видны в chips).
    final allRules = await SettingsStorage.getCustomRules();
    final fromRules = <_WifiEntry, List<String>>{};
    for (final r in allRules) {
      if (r.id == widget.initial.id) continue;
      final ssids = r.wifiSsids;
      final bssids = r.wifiBssids;
      // Pair by index where possible (same as our zip semantics).
      final n = ssids.length > bssids.length ? ssids.length : bssids.length;
      for (var i = 0; i < n; i++) {
        final ssid = i < ssids.length ? ssids[i] : '';
        final bssid = i < bssids.length ? bssids[i] : '';
        if (ssid.isEmpty) continue;
        final entry = _WifiEntry(ssid, bssid);
        fromRules.putIfAbsent(entry, () => []).add(r.name);
      }
    }
    final history = await SettingsStorage.getWifiHistory();
    if (!mounted) return;

    final selected = <_WifiEntry>{};
    final result = await showModalBottomSheet<List<_WifiEntry>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          bool isSelected(_WifiEntry e) => selected.contains(e);
          void toggle(_WifiEntry e, bool? v) {
            setSheetState(() {
              if (v == true) {
                selected.add(e);
              } else {
                selected.remove(e);
              }
            });
          }

          final entries = <Widget>[];
          if (fromRules.isNotEmpty) {
            entries.add(_pickerSectionHeader(ctx, 'USED IN YOUR RULES'));
            for (final mapEntry in fromRules.entries) {
              final e = mapEntry.key;
              final ruleNames = mapEntry.value.join(', ');
              entries.add(CheckboxListTile(
                dense: true,
                value: isSelected(e),
                onChanged: (v) => toggle(e, v),
                title: Text(
                  e.bssid.isEmpty ? e.ssid : '${e.ssid} · ${e.bssid}',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '→ in: $ruleNames',
                  style: const TextStyle(fontSize: 11),
                ),
              ));
            }
          }
          if (history.isNotEmpty) {
            entries.add(_pickerSectionHeader(ctx, 'HISTORY (last seen)'));
            for (final h in history) {
              final ssid = h['ssid'] ?? '';
              final bssid = h['bssid'] ?? '';
              if (ssid.isEmpty) continue;
              final e = _WifiEntry(ssid, bssid);
              entries.add(CheckboxListTile(
                dense: true,
                value: isSelected(e),
                onChanged: (v) => toggle(e, v),
                title: Text(
                  bssid.isEmpty ? ssid : '$ssid · $bssid',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  _humanLastSeen(h['last_seen'] ?? ''),
                  style: const TextStyle(fontSize: 11),
                ),
                secondary: IconButton(
                  tooltip: 'Remove from history',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () async {
                    await SettingsStorage.removeFromWifiHistory(
                        ssid, bssid);
                    if (!ctx.mounted) return;
                    setSheetState(() {
                      history.removeWhere((x) =>
                          (x['ssid'] ?? '') == ssid &&
                          (x['bssid'] ?? '') == bssid);
                      selected.remove(e);
                    });
                  },
                ),
              ));
            }
          }
          if (entries.isEmpty) {
            entries.add(Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Nothing saved yet. Use "Add current" or "Manual" first.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ));
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Saved networks',
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              Navigator.of(ctx).pop<List<_WifiEntry>>(null),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 0),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: entries,
                    ),
                  ),
                  const Divider(height: 0),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop<List<_WifiEntry>>(null),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.of(ctx).pop(selected.toList()),
                          child: Text('Add ${selected.length}'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    setState(() {
      for (final e in result) {
        if (!_wifiNetworks
            .any((x) => x.ssid == e.ssid && x.bssid == e.bssid)) {
          _wifiNetworks.add(e);
        }
      }
    });
  }

  Widget _pickerSectionHeader(BuildContext ctx, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// «Manual»: dialog с двумя полями (SSID + BSSID optional).
  Future<void> _manualAddWifi() async {
    final ssidCtrl = TextEditingController();
    final bssidCtrl = TextEditingController();
    String? errorText;
    final result = await showDialog<_WifiEntry>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Add Wi-Fi network'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ssidCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'SSID',
                  hintText: 'lexRouter',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bssidCtrl,
                decoration: InputDecoration(
                  labelText: 'BSSID (optional)',
                  hintText: '38:2c:4a:cf:6d:5c',
                  helperText: 'xx:xx:xx:xx:xx:xx',
                  errorText: errorText,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final ssid = ssidCtrl.text.trim();
                final bssid = bssidCtrl.text.trim().toLowerCase();
                if (ssid.isEmpty) {
                  setDlgState(() => errorText = null);
                  return;
                }
                if (bssid.isNotEmpty && !_isValidBssid(bssid)) {
                  setDlgState(() => errorText =
                      'Expected xx:xx:xx:xx:xx:xx');
                  return;
                }
                Navigator.of(ctx).pop(_WifiEntry(ssid, bssid));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (_wifiNetworks
        .any((e) => e.ssid == result.ssid && e.bssid == result.bssid)) {
      return; // дедуп
    }
    setState(() => _wifiNetworks.add(result));
    await SettingsStorage.addToWifiHistory(result.ssid, result.bssid);
  }

  /// Tap на info-notice: переход в `Settings → Background` где можно
  /// grant'нуть Location + Nearby Wi-Fi permissions через row'ы.
  Future<void> _openWifiPermissionsScreen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const AppSettingsScreen(initialTab: 1),
    ));
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
            tooltip: 'Delete rule',
            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            onPressed: _delete,
          ),
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
    if (_kind == CustomRuleKind.preset) return _buildPresetParams(theme);
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
            value: _outbound,
            options: widget.outboundOptions,
            onChanged: (v) => setState(() => _outbound = v),
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
          if (_kind == CustomRuleKind.inline ||
              _kind == CustomRuleKind.srs)
            _wifiSection(theme),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            onPressed: _save,
          ),
        ],
      );
  }

  // ─── preset-kind branch (spec §033) ──────────────────────────────────

  Widget _buildPresetParams(ThemeData theme) {
    final cs = theme.colorScheme;
    final preset = widget.preset;

    if (preset == null) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.warning_amber_outlined,
                      color: cs.error, size: 18),
                  const SizedBox(width: 6),
                  Text('Preset not found',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: cs.error)),
                ]),
                const SizedBox(height: 4),
                Text(
                  'Preset "${widget.initial.presetId}" no longer exists in '
                  'this version of the app. The rule will be skipped when the '
                  'config is generated. Delete it or update to a newer '
                  'version that still has this preset.',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
            label: Text('Delete rule', style: TextStyle(color: cs.error)),
            onPressed: _delete,
          ),
        ],
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.push_pin_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text('Based on preset',
                    style: TextStyle(fontSize: 12, color: cs.primary)),
              ]),
              const SizedBox(height: 4),
              Text(preset.label,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (preset.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(preset.description,
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
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
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
        // PARAMETERS секция показывается только если у preset'а есть vars.
        // Для preset'ов без vars (e.g. Block Ads, BitTorrent direct) — пусто;
        // показывать заголовок без контента — шум.
        if (preset.vars.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('PARAMETERS',
              style: theme.textTheme.titleSmall?.copyWith(
                  color: cs.primary, fontWeight: FontWeight.w600)),
          const Divider(),
          for (final v in preset.vars)
            _buildPresetVarWidget(theme, preset, v),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: const Text('Save'),
          onPressed: _save,
        ),
      ],
    );
  }

  /// §045: handler для bool-var Switch'а. Если var управляет remote
  /// rule_set'ом (через `enabled: "@<v.name>"` convention), на toggle-on
  /// auto-downloads .srs; при fail toggle откатывается + snackbar.
  /// Toggle-off — без downloads.
  Future<void> _onBoolVarToggle(
    SelectableRule preset,
    WizardVar v,
    bool val,
  ) async {
    if (!val) {
      setState(() => _varsValues[v.name] = 'false');
      return;
    }
    // val == true: ищем rule_set'ы управляемые этим var'ом
    final controlled = preset.ruleSets.where((rs) {
      final raw = rs['enabled'];
      return raw is String && raw == '@${v.name}';
    }).toList();

    // Если var ничего не gate'ит — просто меняем state
    if (controlled.isEmpty) {
      setState(() => _varsValues[v.name] = 'true');
      return;
    }

    // Проверяем какие из них remote и не cached
    final initial = widget.initial;
    final presetId =
        initial is CustomRulePreset ? initial.presetId : preset.presetId;
    final missing = <_PendingDownload>[];
    for (final rs in controlled) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      final url = rs['url'];
      if (tag is! String || tag.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      final cached =
          await RuleSetDownloader.cachedPathForPreset(presetId, tag) != null;
      if (!cached) missing.add(_PendingDownload(tag: tag, url: url));
    }
    if (!mounted) return;

    if (missing.isEmpty) {
      setState(() {
        _varsValues[v.name] = 'true';
        _presetSrsPaths = {..._presetSrsPaths};
      });
      return;
    }

    // Качаем все недостающие
    setState(() => _boolVarDownloading.add(v.name));
    final newPaths = <String, String>{};
    var anyFailed = false;
    for (final m in missing) {
      final path =
          await RuleSetDownloader.downloadForPreset(presetId, m.tag, m.url);
      if (path == null) {
        anyFailed = true;
      } else {
        newPaths[m.tag] = path;
      }
    }
    if (!mounted) return;

    setState(() {
      _boolVarDownloading.remove(v.name);
      if (anyFailed) {
        // toggle остаётся off, var не меняется
      } else {
        _varsValues[v.name] = 'true';
        _presetSrsPaths = {..._presetSrsPaths, ...newPaths};
      }
    });

    if (anyFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed to download SRS for "${v.title.isEmpty ? v.name : v.title}". '
                'Check internet and try again.')),
      );
    }
  }

  Widget _buildPresetVarWidget(
      ThemeData theme, SelectableRule preset, WizardVar v) {
    final cs = theme.colorScheme;
    final label = v.title.isNotEmpty ? v.title : v.name;
    final subtitle = v.required
        ? v.tooltip
        : (v.tooltip.isEmpty ? '(optional)' : '${v.tooltip} · (optional)');

    Widget control;
    switch (v.type) {
      case 'outbound':
        final current = _varsValues[v.name] ?? v.defaultValue;
        control = OutboundPicker(
          value: current,
          options: widget.outboundOptions,
          onChanged: (val) => setState(() => _varsValues[v.name] = val),
          dense: false,
        );
      case 'dns_servers':
        // Семантика (spec §033): varsValues содержит ключ → explicit выбор
        // (включая пустую строку = "— default DNS" для optional); ключ
        // отсутствует → применяется `default_value` пресета.
        final hasExplicit = _varsValues.containsKey(v.name);
        final stored = _varsValues[v.name];
        final currentKey = hasExplicit ? (stored ?? '') : v.defaultValue;
        final items = <DropdownMenuItem<String>>[];
        if (!v.required) {
          items.add(const DropdownMenuItem<String>(
            value: '',
            child: Text('— (default DNS)',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ));
        }
        for (final s in preset.dnsServers) {
          final tag = s['tag'] as String?;
          if (tag == null || tag.isEmpty) continue;
          final descr = (s['description'] as String?) ?? tag;
          items.add(DropdownMenuItem<String>(
            value: tag,
            child:
                Text(descr, style: const TextStyle(fontSize: 13)),
          ));
        }
        final effectiveKey = items.any((i) => i.value == currentKey)
            ? currentKey
            : (items.isNotEmpty ? items.first.value! : '');
        control = DropdownButton<String>(
          isExpanded: true,
          isDense: false,
          value: effectiveKey,
          items: items,
          onChanged: (val) {
            if (val == null) return;
            setState(() => _varsValues[v.name] = val);
          },
        );
      case 'enum':
        final hasExplicit = _varsValues.containsKey(v.name);
        final stored = _varsValues[v.name];
        final currentKey = hasExplicit ? (stored ?? '') : v.defaultValue;
        final items = <DropdownMenuItem<String>>[];
        if (!v.required) {
          items.add(const DropdownMenuItem<String>(
            value: '',
            child: Text('— (none)',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ));
        }
        for (final o in v.options) {
          items.add(DropdownMenuItem<String>(
            value: o.value,
            child: Text(o.title, style: const TextStyle(fontSize: 13)),
          ));
        }
        final effectiveKey = items.any((i) => i.value == currentKey)
            ? currentKey
            : (items.isNotEmpty ? items.first.value! : '');
        control = DropdownButton<String>(
          isExpanded: true,
          isDense: false,
          value: effectiveKey,
          items: items,
          onChanged: (val) {
            if (val == null) return;
            setState(() => _varsValues[v.name] = val);
          },
        );
      case 'bool':
        // §045: bool var → Switch; storage хранит "true"/"false" string'ом.
        // Если var управляет remote rule_set'ом (`enabled: "@<v.name>"`):
        // toggle-on auto-downloads .srs; на fail откатываем (mirror
        // RoutingScreen `_enableAfterDownload`).
        final hasExplicit = _varsValues.containsKey(v.name);
        final stored = _varsValues[v.name];
        final raw = hasExplicit ? (stored ?? '') : v.defaultValue;
        final current = raw.toLowerCase() == 'true';
        final downloading = _boolVarDownloading.contains(v.name);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyLarge),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (downloading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch(
                  value: current,
                  onChanged: (val) => _onBoolVarToggle(preset, v, val),
                ),
            ],
          ),
        );
      default:
        control = Text(
          '(unsupported var type: ${v.type})',
          style: TextStyle(fontSize: 12, color: cs.error),
        );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle,
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          control,
        ],
      ),
    );
  }

  Widget _buildJsonTab(ThemeData theme) {
    String json;
    List<String> warnings = const [];
    try {
      if (_kind == CustomRuleKind.preset) {
        final preset = widget.preset;
        if (preset == null) {
          json = '// broken preset: "${widget.initial.presetId}" — no definition in template';
        } else {
          final snap = _snapshot();
          // _snapshot() в preset-ветке возвращает CustomRulePreset — cast безопасен.
          final fragments = expandPreset(
            snap as CustomRulePreset,
            preset,
            srsPaths: _presetSrsPaths,
          );
          warnings = fragments.warnings;
          json = const JsonEncoder.withIndent('  ').convert({
            'dns_options': {
              'servers': fragments.dnsServers,
              if (fragments.dnsRule != null) 'rules': [fragments.dnsRule],
            },
            'route': {
              'rule_set': fragments.ruleSets,
              if (fragments.routingRule != null) 'rules': [fragments.routingRule],
            },
          });
        }
      } else {
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
      }
    } catch (e) {
      json = '// error: $e';
    }
    // Storage shape — raw JSON как лежит в lxbox_settings.json для этого
    // правила (поля initial, не _snapshot()). Полезно когда юзер хочет видеть
    // что реально сохранено — все поля включая wifi_ssids/wifi_bssids которые
    // могут быть только partially exposed в Params tab UI.
    final storageJson = const JsonEncoder.withIndent('  ')
        .convert(widget.initial.toJson());

    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Storage shape ───
          Row(
            children: [
              Expanded(
                child: Text('storage shape (lxbox_settings.json)',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              TextButton.icon(
                icon: const Icon(Icons.content_copy, size: 14),
                label: const Text('Copy', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: storageJson));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: SelectableText(
                storageJson,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ─── Sing-box config preview ───
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

/// §045: tag+url пара для batch download'а в `_onBoolVarToggle`.
class _PendingDownload {
  const _PendingDownload({required this.tag, required this.url});
  final String tag;
  final String url;
}

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
  SelectableRule? preset,
}) async {
  final result = await Navigator.push<_CustomRuleEditResult>(
    context,
    MaterialPageRoute(
      builder: (_) => CustomRuleEditScreen(
        initial: initial,
        outboundOptions: outboundOptions,
        existingNames: existingNames,
        preset: preset,
      ),
    ),
  );
  if (result == null) return null;
  return CustomRuleEditResult._internal(result);
}

/// §051 Phase 2 — chip representation одной Wi-Fi сети в editor'е.
/// `bssid` пустой если юзер не указал — в этом случае sing-box матчит
/// только по SSID (любой BSSID с этим именем).
class _WifiEntry {
  const _WifiEntry(this.ssid, this.bssid);
  final String ssid;
  final String bssid;

  @override
  bool operator ==(Object other) =>
      other is _WifiEntry && other.ssid == ssid && other.bssid == bssid;

  @override
  int get hashCode => Object.hash(ssid, bssid);
}

/// §051 Phase 2 — chip list → (wifiSsids, wifiBssids) для модели.
///
/// Sing-box treats lists independently and AND-ит их (cross-product).
/// Для chips с pure-ssid ничего в bssids не добавляем (sing-box матчит
/// только SSID). Для chips с обоими полями — пишем оба (с тем же индексом
/// если возможно для round-trip pairing).
({List<String> ssids, List<String> bssids}) _zipWifiEntries(
    List<_WifiEntry> entries) {
  final ssids = <String>[];
  final bssids = <String>[];
  for (final e in entries) {
    if (e.ssid.isNotEmpty && !ssids.contains(e.ssid)) ssids.add(e.ssid);
    if (e.bssid.isNotEmpty && !bssids.contains(e.bssid)) bssids.add(e.bssid);
  }
  return (ssids: ssids, bssids: bssids);
}

/// §051 Phase 2 — (wifiSsids, wifiBssids) → chip list для loading.
///
/// Best-effort pairing: если списки одинаковой длины — pair by index.
/// Иначе создаём ssid-only chips для всех ssids и (rare) bssid-only chips
/// для остатка (с empty ssid — отображаем как warning hint).
List<_WifiEntry> _unzipWifiEntries(
    List<String> ssids, List<String> bssids) {
  if (ssids.isEmpty && bssids.isEmpty) return [];
  if (ssids.length == bssids.length) {
    return [
      for (var i = 0; i < ssids.length; i++) _WifiEntry(ssids[i], bssids[i]),
    ];
  }
  // Mismatch (загрузка legacy data или manual edit JSON-storage). Делаем
  // ssid-only chips. BSSID без ssid — теряются в UI, но остаются в JSON.
  return [for (final s in ssids) _WifiEntry(s, '')];
}

/// «5 минут назад» / «Yesterday» / «Mar 15» для wifi_history `last_seen`.
String _humanLastSeen(String iso) {
  if (iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  return relativeTime(DateTime.now(), dt);
}
