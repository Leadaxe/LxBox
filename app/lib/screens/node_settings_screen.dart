import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/tag_resolver.dart';
import '../controllers/subscription_controller.dart';
import '../services/error_format.dart';
import '../services/settings_storage.dart';
import '../models/direction.dart';
import '../models/node_link.dart';
import '../models/node_sections.dart';
import '../models/node_spec.dart';
import '../models/node_warning.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../widgets/detour_target_picker.dart';
import '../widgets/emoji_picker_button.dart';
import '../widgets/node_diagnostics_tab.dart';
import '../services/l10n/locale_controller.dart';
import 'node_settings/node_document.dart';
import 'subscription_detail_screen/widgets/node_warning_row.dart';

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
  NodeLink _detour = NodeLink.none;
  // Узел = AmneziaWG (WireguardSpec с непустыми AWG-obfuscation полями). У WG и
  // AWG одинаковый protocol == 'wireguard'; различие — поле `awg`. Используется
  // только для подписи схемы «AmneziaWG (wireguard)».
  bool _isAwg = false;

  // §248 — Направления: секция Directions в пикере + рендер сохранённого Направления
  // detour как «⚙ <label>».
  List<Direction> _directions = const [];

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
    // §435 — у безадресного узла нет «server:port»: Tailscale входит в
    // tailnet сам (tsnet), группа §322 — правило выбора. «:0» не показываем.
    _serverInfo = node is TailscaleSpec
        ? getLocalText.s("No address (Tailscale)")
        : node.isAddressless
            ? getLocalText.s("No address")
            : '${node.server}:${node.port}';
    _jsonCtrl.text = const JsonEncoder.withIndent('  ')
        .convert(node.emit(TemplateVars.empty).map);
    _tagCtrl.text = _originalTag;

    // Detour: одиночный — `entry.detourPolicy.overrideDetour`; §237 член —
    // личный `member.detour` (применяются builder'ом в server_list_build).
    // Раньше писали в JSON node.detour, но parseSingboxEntry это поле не
    // восстанавливает — терялось при save.
    _detour = member != null ? member.detour : widget.entry.overrideDetour;

    // §248 — Направления для подписи «⚙ <label>» сохранённого Направления detour
    // (_pickDetour перечитывает свежий список перед показом пикера).
    _directions = await SettingsStorage.getDirections();

    // §239 — кандидаты живут в общем пикере (showDetourTargetPicker):
    // «свободные» одиночки + члены СВОЕЙ папки (для member-режима).

    if (mounted) setState(() {});
  }

  /// §239 — открыть единый пикер цели detour.
  Future<void> _pickDetour() async {
    final list = widget.entry.list;
    final member = _member;
    // §248 — свежий список Направлений (мог измениться, пока экран открыт).
    _directions = await SettingsStorage.getDirections();
    if (!mounted) return;
    final target = await showDetourTargetPicker(
      context,
      controller: widget.subController,
      directions: _directions,
      currentFolder:
          (member != null && list is FolderServers) ? list : null,
      selfBareTag: member?.node?.tag ?? '',
      selfDisplayTag: member == null
          ? TagResolver.displayTag(list.tagPrefix, _originalTag)
          : '',
    );
    if (target == null || !mounted) return;
    setState(() => _detour = target.link);
    await _persistDetour(target.link);
  }

  /// §248 — подпись сохранённого detour: Направление → «⚙ <label>»; член
  /// СВОЕЙ папки (пара с `id` папки) — его тег; прочий узел — финальная форма
  /// тега (§439, [detourLinkDisplay]).
  String _detourDisplay(NodeLink stored) {
    final list = widget.entry.list;
    return detourLinkDisplay(
      stored,
      directions: _directions,
      controller: widget.subController,
      folder: (widget.memberIndex != null && list is FolderServers)
          ? list
          : null,
    );
  }

  /// §252 — полная цепочка хопов от цели detour вглубь (её собственный
  /// detour → …), по ходу пакета. Для превью «Phone → … → node → Internet».
  String _detourPath() {
    final list = widget.entry.list;
    return detourPathHops(
      _detour,
      controller: widget.subController,
      directions: _directions,
      folder: (widget.memberIndex != null && list is FolderServers)
          ? list
          : null,
    ).join(' → ');
  }

  /// §237 — единая точка записи detour: член папки → setMemberDetour,
  /// одиночный → overrideDetour + persistSources.
  Future<void> _persistDetour(NodeLink value) async {
    final mi = widget.memberIndex;
    if (mi != null) {
      final err =
          await widget.subController.setMemberDetour(widget.index, mi, value);
      if (err != null && mounted) {
        // §239 — отклонено (цикл/self): откатываем локальный выбор.
        setState(() => _detour = _member?.detour ?? NodeLink.none);
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

  /// §435 — секции узла, как хранит контейнер (одиночный — `UserServer`,
  /// член — `FolderMember`). Читается при каждом build: контроллер подменяет
  /// `entry.list` на месте.
  NodeSections? get _sections {
    final member = _member;
    if (member != null) return member.sections;
    final list = widget.entry.list;
    return list is UserServer ? list.sections : null;
  }

  Future<void> _saveJson() async {
    // §435 — три вида входа (голое тело / документ с `sections` / sing-box-
    // документ с `dns`+`route`); тег из поля Tag уходит в тело узла, а не в
    // корень документа. Оба вида секций разом — отказ ещё до контроллера.
    final prep = prepareNodeDocumentForSave(_jsonCtrl.text, _tagCtrl.text);
    if (prep is NodeDocumentRejected) {
      _snack(prep.message);
      return;
    }
    final jsonStr = (prep as NodeDocumentReady).text;
    try {
      final mi = widget.memberIndex;
      if (mi != null) {
        // §237 — член папки: транзакционная правка raw (битый → откат).
        final err =
            await widget.subController.updateMemberAt(widget.index, mi, jsonStr);
        if (!mounted) return;
        if (err != null) {
          _snack(err.render());
          return;
        }
      } else {
        await widget.subController.updateConnectionAt(widget.index, [jsonStr]);
        if (!mounted) return;
      }
      // Перечитать узел: JSON-вкладка показывает тело (документ ушёл в
      // rawBody, связка — в контейнер), блок Sections и предупреждения —
      // свежие.
      await _load();
      if (!mounted) return;
      _snack(_savedMessage());
    } catch (e) {
      if (mounted) {
        _snack(getLocalText.s("Invalid JSON: %s", formatUserError(e).render()));
      }
    }
  }

  /// §435 — «Saved», а отброшенные при разборе документа записи секций —
  /// одной строкой следом (NODE_SECTIONS.md §7; подробности — в строке
  /// предупреждений вкладки Settings).
  String _savedMessage() {
    final dropped = _node?.warnings
            .whereType<SectionsRecordDroppedWarning>()
            .length ??
        0;
    if (dropped == 0) return getLocalText.s("Saved");
    return getLocalText.plural("Saved · %d section records dropped", dropped);
  }

  /// §435 — снять секции узла целиком (кнопка «Clear sections»).
  Future<void> _clearSections() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Clear sections?")),
        content: Text(getLocalText.s(
            "The node's rules and DNS records will be removed. The node itself stays.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Clear")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final mi = widget.memberIndex;
    if (mi != null) {
      final err =
          await widget.subController.setMemberSections(widget.index, mi, null);
      if (!mounted) return;
      if (err != null) {
        _snack(err.render());
        return;
      }
    } else {
      await widget.subController.setUserServerSections(widget.index, null);
      if (!mounted) return;
    }
    setState(() {});
    _snack(getLocalText.s("Sections cleared"));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
              onPressed: () => unawaited(_saveJson()),
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
        // §435 — предупреждения разбора узла (в т. ч. отброшенные записи
        // секций и конфликт `sections`/`dns`+`route` из документа); раньше
        // редактор их не показывал вовсе.
        if (_node?.warnings.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: NodeWarningRow(_node!.warnings),
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
          // §248 — Направление-цель рендерится как «⚙ <label>».
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
        const SizedBox(height: 16),
        ..._buildSectionsBlock(theme),
      ],
    );
  }

  /// §435 — блок «Sections» (NODE_SECTIONS.md §7): счётчик записей,
  /// раскрывающийся read-only JSON в форме хранения (§2 ONE_NAMESPACE, с
  /// плейсхолдерами как есть) и «Clear sections». Без секций — подсказка,
  /// как их приложить через JSON-вкладку.
  List<Widget> _buildSectionsBlock(ThemeData theme) {
    final sections = _sections;
    final muted = theme.colorScheme.onSurfaceVariant;
    return [
      _sectionHeader(getLocalText.s("Sections"),
          getLocalText.s("Rules and DNS records this node carries"), theme),
      if (sections == null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            getLocalText.s(
                "Paste a sing-box config with dns/route or a document with \"sections\" on the JSON tab to attach the node's rules."),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        )
      else ...[
        ListTile(
          leading: const Icon(Icons.account_tree_outlined, size: 20),
          title: Text(_sectionsSummary(sections)),
          subtitle: Text(
            getLocalText.s("Shown in Routing and DNS with the node's tag"),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        ExpansionTile(
          leading: const Icon(Icons.data_object, size: 20),
          title: Text(getLocalText.s("Stored JSON")),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(sections.toJson()),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(getLocalText.s("Clear sections")),
              onPressed: () => unawaited(_clearSections()),
            ),
          ),
        ),
      ],
    ];
  }

  /// «2 rules · 1 DNS servers · 1 DNS rules» — три счётчика через plural.
  String _sectionsSummary(NodeSections s) => [
        getLocalText.plural("%d rules", s.rules.length),
        getLocalText.plural("%d DNS servers", s.dnsServers.length),
        getLocalText.plural("%d DNS rules", s.dnsRules.length),
      ].join(' · ');

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
