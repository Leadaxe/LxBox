import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_log.dart';
import '../services/tag_resolver.dart';
import '../controllers/subscription_controller.dart';
import '../services/error_format.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../widgets/emoji_picker_button.dart';

/// Настройки одиночного сервера (UserServer). Две вкладки (§090 G2b):
/// **Settings** (Protocol/Server/Tag + эмодзи-пикер + Detour) и **JSON**
/// (редактируемый outbound). Ручная ⚙-detour-пометка убрана — detour теперь
/// структурный (§091/G2a), ⚙ остаётся как обычный эмодзи в палитре.
class NodeSettingsScreen extends StatefulWidget {
  const NodeSettingsScreen({
    super.key,
    required this.entry,
    required this.index,
    required this.subController,
  });

  final SubscriptionEntry entry;
  final int index;
  final SubscriptionController subController;

  @override
  State<NodeSettingsScreen> createState() => _NodeSettingsScreenState();
}

class _NodeSettingsScreenState extends State<NodeSettingsScreen> {
  late TextEditingController _tagCtrl;
  late TextEditingController _jsonCtrl;
  String _originalTag = '';
  String _scheme = '';
  String _serverInfo = '';
  String _detour = '';
  List<String> _availableNodes = [];
  // §130 — узел = AmneziaWG (WireguardSpec с непустыми AWG-obfuscation полями).
  // У WG и AWG одинаковый protocol == 'wireguard'; различие — поле `awg`.
  // AWG с detour на wireguard вешает ядро на Android (#2) → фильтруем detour.
  bool _isAwg = false;

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController();
    _jsonCtrl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // v2: узел уже распарсен в entry.list.nodes.first.
    final nodes = widget.entry.list.nodes;
    if (nodes.isEmpty) return;
    final node = nodes.first;

    // §130 — AWG-детект: WireguardSpec с непустыми obfuscation-полями.
    _isAwg = node is WireguardSpec && node.awg != null;

    _originalTag = node.tag;
    // §130 — protocol у WG и AWG одинаков ('wireguard'); для AWG уточняем
    // подпись «AmneziaWG (wireguard)», чтобы юзер видел, что это AWG-разновидность.
    _scheme = _isAwg ? 'AmneziaWG (wireguard)' : node.protocol;
    _serverInfo = '${node.server}:${node.port}';
    _jsonCtrl.text = const JsonEncoder.withIndent('  ')
        .convert(node.emit(TemplateVars.empty).map);
    _tagCtrl.text = _originalTag;

    // Detour хранится в `entry.detourPolicy.overrideDetour` (применяется
    // builder'ом в server_list_build). Раньше писали в JSON node.detour,
    // но parseSingboxEntry это поле не восстанавливает — терялось при save.
    _detour = widget.entry.overrideDetour;

    // Доступные detour-теги: все узлы всех `UserServer` кроме себя.
    //
    // §080: строим **display-form** (`'$tagPrefix $base'`) — как
    // `server_list_build._withPrefix`. Значение сохраняется в
    // `entry.overrideDetour` и подставляется builder'ом прямо в
    // `main.map['detour']` без prefix-трансформации, поэтому bare `n.tag`
    // ссылался бы на несуществующий outbound при непустом `tag_prefix`.
    // Self-exclude тоже по display-form (текущая нода со своим prefix'ом).
    // NB: совпадает с эмитированным tag'ом только ДО `allocateTag` de-dup
    // (collision-suffix `-N` здесь не учитывается — редкий edge, §080).
    final selfDisplay =
        TagResolver.displayTag(widget.entry.list.tagPrefix, _originalTag);
    final tags = <String>[];
    for (final e in widget.subController.entries) {
      final list = e.list;
      if (list is! UserServer) continue;
      // §080: disabled UserServer не эмитит outbounds → skip (dangling).
      if (!list.enabled) continue;
      final prefix = list.tagPrefix;
      for (final n in list.nodes) {
        if (n.tag.isEmpty) continue;
        // §130 — AWG-узел не может detour-ить в wireguard (вешает ядро #2):
        // исключаем всех wireguard-кандидатов (плоский WG + AWG).
        if (_isAwg && n is WireguardSpec) continue;
        final display = TagResolver.displayTag(prefix, n.tag);
        if (display != selfDisplay) tags.add(display);
      }
    }
    _availableNodes = tags;

    // §130 — если у AWG-узла уже сохранён detour на wireguard-цель (старый
    // сломанный конфиг), её больше нет в отфильтрованном списке → сбрасываем
    // на None и СРАЗУ персистим (иначе юзер откроет/закроет не трогая dropdown
    // и битый detour останется в lxbox_settings.json).
    if (_isAwg && _detour.isNotEmpty && !_availableNodes.contains(_detour)) {
      final removed = _detour;
      _detour = '';
      widget.entry.overrideDetour = '';
      unawaited(widget.subController.persistSources());
      _logResetDetour(removed);
    }

    if (mounted) setState(() {});
  }

  /// §130 — лог сброса невалидного AWG→WireGuard detour при открытии редактора.
  void _logResetDetour(String removed) {
    AppLog.I.info(
        '§130: AWG-узел "$_originalTag" — сброшен невалидный detour "$removed" '
        '(AWG не может идти через WireGuard, вешает ядро на Android)');
  }

  /// §090 G2b — вставка эмодзи из пикера в позицию курсора поля Tag.
  void _insertEmoji(String emoji) {
    final text = _tagCtrl.text;
    final sel = _tagCtrl.selection;
    final start =
        (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    final end = (sel.end >= 0 && sel.end <= text.length) ? sel.end : start;
    const space = ' ';
    final insert = '$emoji$space';
    final newText = text.replaceRange(start, end, insert);
    _tagCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
  }

  void _saveJson() {
    try {
      final parsed = jsonDecode(_jsonCtrl.text);
      final map = parsed is List ? parsed.first : parsed;
      // Подмешиваем edited tag из отдельного поля (юзер мог менять
      // только tag и забыть про JSON-редактор).
      if (map is Map<String, dynamic>) {
        final newTag = _tagCtrl.text.trim();
        if (newTag.isNotEmpty) map['tag'] = newTag;
      }
      final jsonStr = jsonEncode(map);
      widget.subController.updateConnectionAt(widget.index, [jsonStr]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid JSON: ${formatUserError(e)}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title:
              Text(_tagCtrl.text.isNotEmpty ? _tagCtrl.text : 'Node Settings'),
          actions: [
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.save),
              onPressed: _saveJson,
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Settings'), Tab(text: 'JSON')],
          ),
        ),
        body: _originalTag.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildSettingsTab(theme),
                  _buildJsonTab(theme),
                ],
              ),
      ),
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        _sectionHeader('Info', 'Protocol and server details', theme),
        // Лейбл в title, значение в subtitle (во всю ширину, перенос по словам).
        // Раньше длинное значение в `trailing` сжимало title до нуля и «Server»
        // переносился вертикально по буквам (напр. WARP-хост
        // engage.cloudflareclient.com:2408).
        ListTile(
          leading: const Icon(Icons.security, size: 20),
          title: const Text('Protocol'),
          // §130 — для AWG subtitle = «AmneziaWG (wireguard)» (см. _scheme в _load).
          subtitle: Text(_scheme, style: theme.textTheme.bodyMedium),
        ),
        ListTile(
          leading: const Icon(Icons.dns, size: 20),
          title: const Text('Server'),
          subtitle: Text(_serverInfo, style: theme.textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _tagCtrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Tag',
              hintText: 'Display name in node list',
              isDense: true,
              prefixIcon: const Icon(Icons.label_outline, size: 18),
              // §090 G2b — эмодзи-пикер: тап → палитра → вставка в курсор.
              suffixIcon: EmojiPickerButton(onPick: _insertEmoji),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _sectionHeader('Detour', 'Route through another server first', theme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: DropdownButtonFormField<String>(
            initialValue: _detour.isEmpty
                ? ''
                : (_availableNodes.contains(_detour) ? _detour : ''),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Detour server',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('None (direct)')),
              ..._availableNodes.map((tag) => DropdownMenuItem(
                  value: tag,
                  child: Text(tag, overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) {
              setState(() => _detour = v ?? '');
              // Persist через ServerList.detourPolicy.overrideDetour — builder
              // подхватит и перезапишет main.map['detour']. Не трогаем JSON
              // ноды, иначе после save через parseSingboxEntry поле теряется.
              widget.entry.overrideDetour = _detour;
              unawaited(widget.subController.persistSources());
            },
          ),
        ),
        // §130 — для AWG-узла WireGuard-цели исключены из списка (AWG поверх
        // WireGuard вешает ядро на Android). Поясняем, почему их нет.
        if (_isAwg)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'AmneziaWG-узлы не могут идти через WireGuard — такие цели '
                    'скрыты. Используйте non-wireguard detour (например, vless).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            _detour.isEmpty
                ? 'Traffic goes directly to this server.'
                : 'Phone → $_detour → $_originalTag → Internet',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildJsonTab(ThemeData theme) {
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        _sectionHeader(
            'Outbound JSON', 'Edit tag, detour, and all server parameters', theme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Stack(
            children: [
              TextField(
                controller: _jsonCtrl,
                maxLines: null,
                minLines: 12,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.fromLTRB(12, 12, 40, 12),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy JSON',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _jsonCtrl.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('JSON copied')),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, String description, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
