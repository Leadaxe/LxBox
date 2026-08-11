import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/tag_resolver.dart';
import '../controllers/subscription_controller.dart';
import '../services/error_format.dart';
import '../services/settings_storage.dart';
import '../models/channel.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../widgets/detour_target_picker.dart';
import '../widgets/emoji_picker_button.dart';
import '../widgets/node_diagnostics_tab.dart';
import '../services/l10n/locale_controller.dart';

/// Настройки одиночного сервера (UserServer) ИЛИ члена папки (§237). Две
/// вкладки (§090 G2b): **Settings** (Protocol/Server/Tag + эмодзи-пикер +
/// Detour) и **JSON** (редактируемый outbound). Ручная ⚙-detour-пометка
/// убрана — detour теперь структурный (§091/G2a), ⚙ остаётся как обычный
/// эмодзи в палитре.
///
/// §237 — [memberIndex] != null → [entry] это ПАПКА, экран настраивает её
/// члена: нода из `members[memberIndex]`, save JSON → `updateMemberAt`,
/// detour → `setMemberDetour` (личный detour члена; политика папки
/// применяется к нему в builder'е).
class NodeSettingsScreen extends StatefulWidget {
  const NodeSettingsScreen({
    super.key,
    required this.entry,
    required this.index,
    required this.subController,
    this.memberIndex,
  });

  final SubscriptionEntry entry;
  final int index;
  final SubscriptionController subController;

  /// §237 — индекс члена папки; null = одиночный сервер (старое поведение).
  final int? memberIndex;

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
  // Узел = AmneziaWG (WireguardSpec с непустыми AWG-obfuscation полями). У WG и
  // AWG одинаковый protocol == 'wireguard'; различие — поле `awg`. Используется
  // только для подписи схемы «AmneziaWG (wireguard)».
  bool _isAwg = false;

  // §248 — каналы: секция Channels в пикере + рендер сохранённого канального
  // detour как «⚙ <label>».
  List<Channel> _channels = const [];

  /// §392 — разобранный узел для вкладки Diagnostics (probe-ветка собирает
  /// из него временный конфиг).
  NodeSpec? _node;

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

  /// §237 — член папки, если экран открыт для него.
  FolderMember? get _member {
    final mi = widget.memberIndex;
    if (mi == null) return null;
    final list = widget.entry.list;
    if (list is! FolderServers) return null;
    if (mi < 0 || mi >= list.members.length) return null;
    return list.members[mi];
  }

  Future<void> _load() async {
    // v2: одиночный — узел уже распарсен в entry.list.nodes.first;
    // §237 член папки — из members[memberIndex].
    final NodeSpec node;
    final member = _member;
    if (member != null) {
      final n = member.node;
      if (n == null) return; // битый raw — сюда не попадаем (гейт в UI папки)
      node = n;
    } else {
      final nodes = widget.entry.list.nodes;
      if (nodes.isEmpty) return;
      node = nodes.first;
    }

    _node = node; // §392 — источник probe-ветки диагностики

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

    // Detour: одиночный — `entry.detourPolicy.overrideDetour`; §237 член —
    // личный `member.detour` (применяются builder'ом в server_list_build).
    // Раньше писали в JSON node.detour, но parseSingboxEntry это поле не
    // восстанавливает — терялось при save.
    _detour = member != null ? member.detour : widget.entry.overrideDetour;

    // §248 — каналы для подписи «⚙ <label>» сохранённого канального detour
    // (_pickDetour перечитывает свежий список перед показом пикера).
    _channels = await SettingsStorage.getChannels();

    // §239 — кандидаты живут в общем пикере (showDetourTargetPicker):
    // «свободные» одиночки + члены СВОЕЙ папки (для member-режима).

    if (mounted) setState(() {});
  }

  /// §239 — открыть единый пикер цели detour.
  Future<void> _pickDetour() async {
    final list = widget.entry.list;
    final member = _member;
    // §248 — свежий список каналов (мог измениться, пока экран открыт).
    _channels = await SettingsStorage.getChannels();
    if (!mounted) return;
    final target = await showDetourTargetPicker(
      context,
      controller: widget.subController,
      channels: _channels,
      currentFolder:
          (member != null && list is FolderServers) ? list : null,
      selfBareTag: member?.node?.tag ?? '',
      selfDisplayTag: member == null
          ? TagResolver.displayTag(list.tagPrefix, _originalTag)
          : '',
    );
    if (target == null || !mounted) return;
    setState(() => _detour = target.storeValue);
    await _persistDetour(target.storeValue);
  }

  /// §248 — подпись сохранённого detour: тег detour-канала (или его
  /// auto-двойника) → «⚙ <label>»; канал не найден → сырой тег. Интра-омоним
  /// (bare-тег члена СВОЕЙ папки) побеждает канал-тёзку — резолвится в члена
  /// (приоритет bareIndex в FolderDetourPlan), показываем как тег.
  String _detourDisplay(String stored) {
    final list = widget.entry.list;
    if (widget.memberIndex != null && list is FolderServers) {
      for (final m in list.members) {
        if (m.node?.tag == stored) return stored;
      }
    }
    return detourChannelDisplay(stored, _channels);
  }

  /// §252 — полная цепочка хопов от цели detour вглубь (её собственный
  /// detour → …), по ходу пакета. Для превью «Phone → … → node → Internet».
  String _detourPath() {
    final list = widget.entry.list;
    return detourPathHops(
      _detour,
      controller: widget.subController,
      channels: _channels,
      folder: (widget.memberIndex != null && list is FolderServers)
          ? list
          : null,
    ).join(' → ');
  }

  /// §237 — единая точка записи detour: член папки → setMemberDetour,
  /// одиночный → overrideDetour + persistSources.
  Future<void> _persistDetour(String value) async {
    final mi = widget.memberIndex;
    if (mi != null) {
      final err =
          await widget.subController.setMemberDetour(widget.index, mi, value);
      if (err != null && mounted) {
        // §239 — отклонено (цикл/self): откатываем локальный выбор.
        setState(() => _detour = _member?.detour ?? '');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.render())));
      }
      return;
    }
    widget.entry.overrideDetour = value;
    await widget.subController.persistSources();
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
      final mi = widget.memberIndex;
      if (mi != null) {
        // §237 — член папки: транзакционная правка raw (битый → откат).
        unawaited(widget.subController
            .updateMemberAt(widget.index, mi, jsonStr)
            .then((err) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(err == null
                    ? getLocalText.s("Saved")
                    : err.render())),
          );
        }));
        return;
      }
      widget.subController.updateConnectionAt(widget.index, [jsonStr]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Saved"))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  getLocalText.s("Invalid JSON: %s", formatUserError(e).render()))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_tagCtrl.text.isNotEmpty
              ? _tagCtrl.text
              : getLocalText.s("Node Settings")),
          actions: [
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: const Icon(Icons.save),
              onPressed: _saveJson,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: getLocalText.s("Settings")),
              // l10n-exempt: format name, locale-invariant
              const Tab(text: 'JSON'),
              Tab(text: getLocalText.s("Diagnostics")),
            ],
          ),
        ),
        body: _originalTag.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildSettingsTab(theme),
                  _buildJsonTab(theme),
                  // §392 — узел распарсен: доступны обе ветки (probe при
                  // выключенном VPN, боевое ядро при включённом).
                  NodeDiagnosticsTab(
                    node: _node,
                    liveTag: TagResolver.displayTag(
                        widget.entry.list.tagPrefix, _originalTag),
                  ),
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
        _sectionHeader(
            getLocalText.s("Info"), getLocalText.s("Protocol and server details"), theme),
        // Лейбл в title, значение в subtitle (во всю ширину, перенос по словам).
        // Раньше длинное значение в `trailing` сжимало title до нуля и «Server»
        // переносился вертикально по буквам (напр. WARP-хост
        // engage.cloudflareclient.com:2408).
        ListTile(
          leading: const Icon(Icons.security, size: 20),
          title: Text(getLocalText.s("Protocol")),
          // §130 — для AWG subtitle = «AmneziaWG (wireguard)» (см. _scheme в _load).
          subtitle: Text(_scheme, style: theme.textTheme.bodyMedium),
        ),
        ListTile(
          leading: const Icon(Icons.dns, size: 20),
          title: Text(getLocalText.s("Server")),
          subtitle: Text(_serverInfo, style: theme.textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _tagCtrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: getLocalText.s("Tag"),
              hintText: getLocalText.s("Display name in node list"),
              isDense: true,
              prefixIcon: const Icon(Icons.label_outline, size: 18),
              // §090 G2b — эмодзи-пикер: тап → палитра → вставка в курсор.
              suffixIcon: EmojiPickerButton(onPick: _insertEmoji),
            ),
          ),
        ),
        // §322 — у узла автовыбора detour'а нет: он не соединение, а правило
        // выбора среди членов. Блок не рисуем вовсе (не «серым»).
        if (_member?.node?.isGroup != true) ...[
        const SizedBox(height: 16),
        _sectionHeader(
            getLocalText.s("Detour"), getLocalText.s("Route through another server first"), theme),
        ListTile(
          leading: const Icon(Icons.alt_route, size: 20),
          title: Text(getLocalText.s("Detour server")),
          // §248 — канальная цель рендерится как «⚙ <label>».
          subtitle: Text(_detour.isEmpty
              ? getLocalText.s("None (direct)")
              : _detourDisplay(_detour)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_pickDetour()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            // §252 — полная цепочка «как пакет пойдёт»: цель → её собственный
            // detour → … (detourPathHops), а не только первый хоп.
            _detour.isEmpty
                ? getLocalText.s("Traffic goes directly to this server.")
                : getLocalText.s("Phone → %1\$s → %2\$s → Internet", _detourPath(), _originalTag),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        ], // §322 — конец гейта detour-блока
      ],
    );
  }

  Widget _buildJsonTab(ThemeData theme) {
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        _sectionHeader(getLocalText.s("Outbound JSON"),
            getLocalText.s("Edit tag, detour, and all server parameters"), theme),
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
                  tooltip: getLocalText.s("Copy JSON"),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _jsonCtrl.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(getLocalText.s("JSON copied"))),
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
