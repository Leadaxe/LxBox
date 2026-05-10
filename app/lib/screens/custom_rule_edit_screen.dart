import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/builder/post_steps.dart';
import '../services/builder/preset_expand.dart';
import '../services/builder/rule_set_registry.dart';
import '../services/rule_set_downloader.dart';
import '../services/settings_storage.dart';
import '../services/url_launcher.dart' as ul;
import '../widgets/outbound_picker.dart';
import '../widgets/wifi_entry.dart';
import '../widgets/wifi_manual_add_dialog.dart';
import '../widgets/wifi_permission_dialog.dart';
import '../widgets/wifi_saved_picker_sheet.dart';
import 'app_picker_screen.dart';
import 'app_settings_screen.dart';
import 'custom_rule_edit/normalizers.dart' as norm;
import 'custom_rule_edit/sections/apps_section.dart';
import 'custom_rule_edit/sections/match_section.dart';
import 'custom_rule_edit/sections/port_section.dart';
import 'custom_rule_edit/sections/protocol_section.dart';
import 'custom_rule_edit/sections/srs_section.dart';
import 'custom_rule_edit/sections/wifi_section.dart';

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
  late List<WifiEntry> _wifiNetworks;

  /// Значения preset-vars (spec §033). Для kind != preset — пустая мапа,
  /// игнорируется при save.
  late Map<String, String> _varsValues;

  /// Кэш-пути remote rule_set'ов пресета (tag → абсолютный путь), pre-
  /// resolved в initState. Без этого View tab всегда бы ругался «no cached
  /// file» даже для скачанного пресета (task 011).
  Map<String, String> _presetSrsPaths = const {};

  /// Состояние cloud-индикатора рядом с URL. Определяется на open
  /// (isCached) + меняется по клику (_downloadSrs).
  SrsDownloadState _srsState = SrsDownloadState.none;

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
            ? SrsDownloadState.cached
            : SrsDownloadState.none);
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
          ports: norm.normalizedPorts(_portCtrl.text),
          portRanges: norm.normalizedPortRanges(_portRangeCtrl.text),
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
          domains: norm.normalizedDomains(_domainCtrl.text),
          domainSuffixes:
              norm.normalizedDomains(_domainSuffixCtrl.text, stripLeadingDot: true),
          domainKeywords: norm.normalizedKeywords(_domainKeywordCtrl.text),
          ipCidrs: norm.normalizedCidrs(_ipCidrCtrl.text),
          ports: norm.normalizedPorts(_portCtrl.text),
          portRanges: norm.normalizedPortRanges(_portRangeCtrl.text),
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
    setState(() => _srsState = SrsDownloadState.loading);
    final path = await RuleSetDownloader.download(widget.initial.id, url);
    if (!mounted) return;
    setState(() => _srsState =
        path != null ? SrsDownloadState.cached : SrsDownloadState.error);
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
          _srsState = SrsDownloadState.none;
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
  Future<void> _addCurrentWifi() async {
    final result = await ul.UrlLauncher.getCurrentWifiInfo();
    if (!mounted) return;
    switch (result) {
      case ul.WifiInfoSuccess(:final ssid, :final bssid):
        // Дедуп: если уже есть chip с тем же ssid+bssid — skip.
        final exists = _wifiNetworks
            .any((e) => e.ssid == ssid && e.bssid == bssid);
        if (!exists) {
          setState(() => _wifiNetworks.add(WifiEntry(ssid, bssid)));
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
    // §053 Stage 1 — delegate to `showWifiSavedPickerSheet`. Picker
    // sam грузит данные (other-rules + history + auto-record flag) и
    // показывает modal. Возвращает выбранные entries либо null.
    final result = await showWifiSavedPickerSheet(
      context,
      excludeRuleId: widget.initial.id,
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


  /// «Manual»: dialog с двумя полями (SSID + BSSID optional).
  /// §053 Stage 1 — delegate to extracted `showWifiManualAddDialog`.
  Future<void> _manualAddWifi() async {
    final result = await showWifiManualAddDialog(context);
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
                        _srsState != SrsDownloadState.cached)
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
          AppsSection(
            packages: _packages,
            onTap: _openAppPicker,
            onClear: () => setState(() => _packages = []),
          ),
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
                    _srsState != SrsDownloadState.cached) {
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
          if (_kind == CustomRuleKind.inline)
            MatchSection(
              domainCtrl: _domainCtrl,
              domainSuffixCtrl: _domainSuffixCtrl,
              domainKeywordCtrl: _domainKeywordCtrl,
              ipCidrCtrl: _ipCidrCtrl,
              ipIsPrivate: _ipIsPrivate,
              onIpIsPrivateChanged: (v) =>
                  setState(() => _ipIsPrivate = v),
            ),
          if (_kind == CustomRuleKind.srs)
            SrsSection(
              urlCtrl: _srsUrlCtrl,
              state: _srsState,
              onDownload: _downloadSrs,
              onShowCloudMenu: _showCloudMenu,
              onUrlChanged: () {
                if (_srsState == SrsDownloadState.error) {
                  setState(() => _srsState = SrsDownloadState.none);
                }
              },
            ),
          PortSection(
            portCtrl: _portCtrl,
            portRangeCtrl: _portRangeCtrl,
          ),
          ProtocolSection(
            selected: _protocols,
            onToggle: (p, checked) => setState(() {
              if (checked) {
                _protocols.add(p);
              } else {
                _protocols.remove(p);
              }
            }),
          ),
          if (_kind == CustomRuleKind.inline ||
              _kind == CustomRuleKind.srs)
            WifiSection(
              networks: _wifiNetworks,
              onRemoveAt: (i) =>
                  setState(() => _wifiNetworks.removeAt(i)),
              onAddCurrent: _addCurrentWifi,
              onPickSaved: _pickSavedWifi,
              onManual: _manualAddWifi,
              onTapPermissionsHint: _openWifiPermissionsScreen,
            ),
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
          srsPaths[widget.initial.id] = _srsState == SrsDownloadState.cached
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

/// §051 Phase 2 — chip list → (wifiSsids, wifiBssids) для модели.
///
/// Sing-box treats lists independently and AND-ит их (cross-product).
/// Для chips с pure-ssid ничего в bssids не добавляем (sing-box матчит
/// только SSID). Для chips с обоими полями — пишем оба.
///
/// ⚠ **Cross-product trap (low-impact, documented risk)**: при 2+ chips
/// с разными `(ssid, bssid)` парами, sing-box rule `wifi_ssid:[A,B] AND
/// wifi_bssid:[X,Y]` теоретически matches «A на BSSID Y» (не задумано).
/// На практике риск мал — BSSID = globally unique MAC, коллизии
/// "правильный SSID + чужой BSSID" нереалистичны. Для exact pair semantic
/// builder должен бы эмитить N отдельных rules — deferred до реального
/// use-case. См. §051 spec «Known risks».
({List<String> ssids, List<String> bssids}) _zipWifiEntries(
    List<WifiEntry> entries) {
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
List<WifiEntry> _unzipWifiEntries(
    List<String> ssids, List<String> bssids) {
  if (ssids.isEmpty && bssids.isEmpty) return [];
  if (ssids.length == bssids.length) {
    return [
      for (var i = 0; i < ssids.length; i++) WifiEntry(ssids[i], bssids[i]),
    ];
  }
  // Mismatch (загрузка legacy data или manual edit JSON-storage). Делаем
  // ssid-only chips. BSSID без ssid — теряются в UI, но остаются в JSON.
  return [for (final s in ssids) WifiEntry(s, '')];
}
