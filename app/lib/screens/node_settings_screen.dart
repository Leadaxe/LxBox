import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/tag_resolver.dart';
import '../controllers/subscription_controller.dart';
import '../models/codec/source_record.dart';
import '../vpn/box_vpn_client.dart';
import '../services/error_format.dart';
import '../services/preset_nodes_view.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../services/ui_helpers.dart';
import '../models/direction.dart';
import '../models/node_link.dart';
import '../models/node_spec.dart';
import '../models/node_warning.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../models/tls_policy.dart';
import '../widgets/detour_target_picker.dart';
import '../widgets/emoji_picker_button.dart';
import '../widgets/lx_code_editor.dart';
import '../widgets/node_diagnostics_tab.dart';
import '../widgets/openconnect_form.dart';
import '../services/contract/form_source_sync.dart';
import '../widgets/tailscale_network_tab.dart';
import '../services/tailscale_network.dart';
import '../services/l10n/locale_controller.dart';
import '../services/warp/warp_endpoint_picker.dart';
import '../services/wireguard/masquerade_source.dart';
import '../services/wireguard/wg_ini_export.dart';
import '../widgets/masquerade_fields.dart';
import '../widgets/tls_policy_tiles.dart';
import '../widgets/auto_group_form.dart';
import 'node_settings/auto_group_source.dart';
import 'node_settings/node_document.dart';
import 'subscriptions_screen/entry_warnings.dart';

/// Настройки одиночного сервера (UserServer) ИЛИ члена папки (§237).
/// Вкладки: **Settings** (Protocol/Server/Tag + эмодзи-пикер + Detour),
/// **Source** (§455 — `origin.raw` записи как есть, единственное место
/// правки; Save в AppBar сохраняет его), **JSON** (только чтение: то, что
/// уйдёт в ядро; кнопка Edit после предупреждения заменяет источник этим
/// JSON и уводит в Source), у WireGuard/AmneziaWG — **INI** (§686 п. 9: узел
/// в виде `.conf`, Edit INI заменяет им источник) и **Diagnostics** (§392). Ручная ⚙-detour-пометка
/// убрана — detour структурный (§091/G2a), ⚙ остаётся как обычный эмодзи.
///
/// §455 — узел, чей источник JSON (`origin.kind: json`), уходит в конфиг
/// дословно (`verbatim_body.dart`); гейты модели на нём не работают, ворота
/// — `CheckConfig` ядра при Save.
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
    this.initialTab = 0,
  });

  final SubscriptionEntry entry;
  final int index;
  final SubscriptionController subController;

  /// §237 — индекс члена папки; null = одиночный сервер (старое поведение).
  final int? memberIndex;

  /// §498/§501 — начальная вкладка (страховка открывает Diagnostics = 3).
  final int initialTab;

  /// Индекс вкладки Diagnostics: Settings, Source, JSON, Diagnostics. У узла
  /// Tailscale перед Diagnostics стоит Network (§581), у WireGuard/AmneziaWG
  /// — INI (§686 п. 9): экран сдвигает индекс сам.
  static const diagnosticsTabIndex = 3;

  @override
  State<NodeSettingsScreen> createState() => _NodeSettingsScreenState();
}

class _NodeSettingsScreenState extends State<NodeSettingsScreen>
    with SingleTickerProviderStateMixin {
  late TextEditingController _tagCtrl;
  late TextEditingController _jsonCtrl;

  /// §455 — источник записи (`origin.raw`), редактируется на вкладке Source.
  late TextEditingController _sourceCtrl;

  /// §455 — вид источника: `uri` | `wg_ini` | `json` (`originKindOf`).
  String _originKind = 'uri';
  late TabController _tabs;
  static const _kSourceTab = 1;
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

  /// §654 B2 — последнее тело формы OpenConnect, разобранное из Source: пока
  /// текст не объект, форма показывает его неактивной.
  Map<String, dynamic>? _ocLastBody;

  /// Разбор + хранимый вердикт (`core_rejected` и др.) для секции
  /// Notifications во вкладке Diagnostics.
  List<NodeWarning> _notifications = const [];

  /// §578/§643/§656 — переключатель `Skip Tailscale presets` виден: узел
  /// `tailscale`, в шаблоне есть пресет с обходом узлов, чей `#filter`
  /// принимает этот узел (см. [skipTailscalePresetsToggleVisible]).
  bool _skipPresetsVisible = false;

  /// §656 — блок `Incoming connections from this tunnel` виден (см.
  /// [tunnelIngressTogglesVisible]).
  bool _tunnelIngressVisible = false;

  /// §581 — узел Tailscale: есть вкладка Network.
  bool _isTailscale = false;

  /// §686 п. 9 — узел WireGuard/AmneziaWG: есть вкладка INI.
  bool _isWireguard = false;

  /// §686 п. 9 — `.conf` вкладки INI: обратный ход таблицы `conf` реестра
  /// по телу вкладки JSON; `lost` — ключи тела, которых в `.conf` нет.
  IniEmitResult? _ini;

  /// §623 — пул доменов маскировки (тот же, что у визарда WARP) для поля
  /// домена секции Masquerade узла WireGuard/AmneziaWG.
  WarpEndpointPicker? _picker;

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController();
    _jsonCtrl = TextEditingController();
    _sourceCtrl = TextEditingController();
    // §581 — у узла Tailscale вкладка Network перед Diagnostics.
    final first = _member?.node ??
        (widget.entry.list.nodes.isEmpty ? null : widget.entry.list.nodes.first);
    _isTailscale = first is TailscaleSpec;
    // §686 п. 9 — у WireGuard/AmneziaWG вкладка INI после JSON.
    _isWireguard = first is WireguardSpec;
    final count = 4 + (_isTailscale ? 1 : 0) + (_isWireguard ? 1 : 0);
    var initial = widget.initialTab.clamp(0, 3);
    if (initial == NodeSettingsScreen.diagnosticsTabIndex) {
      initial = count - 1;
    }
    _tabs = TabController(length: count, vsync: this, initialIndex: initial);
    unawaited(_load());
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _jsonCtrl.dispose();
    _sourceCtrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// §455 — текст источника записи: raw члена папки или `rawBody` одиночного.
  String get _containerRaw {
    final member = _member;
    // §686 — у auto-узла текста нет: источник — его запись `kind: auto`.
    if (member != null) {
      final group = _autoGroup;
      if (group != null) {
        return autoGroupSourceText(member, group, _folderId);
      }
      return member.raw;
    }
    final list = widget.entry.list;
    return list is UserServer ? list.rawBody : '';
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

  /// §686 — группа auto-узла папки (член `kind: auto`); `null` — иной узел.
  /// Решает тип узла, а не экран, откуда открыли карточку.
  AutoSelectSpec? get _autoGroup {
    final n = _member?.node;
    return n is AutoSelectSpec ? n : null;
  }

  String get _folderId {
    final list = widget.entry.list;
    return list is FolderServers ? list.id : '';
  }

  /// §686 — последняя группа, разобранная из Source: пока текст не объект,
  /// форма показывает её неактивной.
  AutoSelectSpec? _autoLastGroup;

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
    final emittedTag =
        TagResolver.displayTag(widget.entry.list.tagPrefix, node.tag);
    _notifications = warningsForConfigTag(
      emittedTag,
      widget.subController.entries,
      emittedTagMap: widget.subController.lastEmittedTagMap,
      buildWarningsByTag: widget.subController.lastBuildWarningsByTag,
    );

    // §130 — AWG-детект: WireguardSpec с непустыми obfuscation-полями.
    _isAwg = node is WireguardSpec && node.awg != null;

    _originalTag = node.tag;
    // §130 — protocol у WG и AWG одинаков ('wireguard'); для AWG уточняем
    // подпись «AmneziaWG (wireguard)», чтобы юзер видел, что это AWG-разновидность.
    _scheme = _isAwg
        ? 'AmneziaWG (wireguard)' // l10n-exempt: protocol name
        : node.protocol;
    // §435 — у безадресного узла нет «server:port»: Tailscale входит в
    // tailnet сам (tsnet), группа §322 — правило выбора. «:0» не показываем.
    _serverInfo = node is TailscaleSpec
        ? getLocalText.s("No address (Tailscale)")
        : node.isAddressless
            ? getLocalText.s("No address")
            : '${node.server}:${node.port}';
    // §455 — источник как есть; предпросмотр JSON — то, что уйдёт в ядро:
    // у sing-box-источника это его объект (дословно), иначе emit() модели.
    // Д-1 — гейт тот же, что у сборки (`verbatimBodyOf`): у Xray-объекта
    // вкладка обязана показывать sing-box-тело модели, ведь именно оно и
    // уйдёт в ядро.
    final raw = _containerRaw;
    _sourceCtrl.text = raw;
    _originKind = originKindOf(raw);
    final Object? preview = node is AutoSelectSpec && member != null
        ? autoGroupJsonPreview(node) // §686
        : sourceIsSingbox(raw) && node.rawSource.trimLeft().startsWith('{')
            ? jsonDecode(node.rawSource)
            : node.emit(TemplateVars.empty).map;
    _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(preview);
    // §686 п. 9 — `.conf` из того же тела, что показывает вкладка JSON: у
    // тела sing-box JSON ключи вне таблицы переноса уходят в «Not in INI».
    _ini = node is WireguardSpec && preview is Map
        ? wireguardIniOf(Map<String, dynamic>.from(preview))
        : null;
    _autoLastGroup = null;
    _tagCtrl.text = _originalTag;

    // Detour: одиночный — `entry.detourPolicy.overrideDetour`; §237 член —
    // личный `member.detour` (применяются builder'ом в server_list_build).
    // Раньше писали в JSON node.detour, но parseSingboxEntry это поле не
    // восстанавливает — терялось при save.
    _detour = member != null ? member.detour : widget.entry.overrideDetour;

    // §248 — Направления для подписи «⚙ <label>» сохранённого Направления detour
    // (_pickDetour перечитывает свежий список перед показом пикера).
    _directions = await SettingsStorage.getDirections();

    // §656 — блок входящих из туннеля: своя запись и тип endpoint'а.
    final nodeBody = node.emit(TemplateVars.empty).map;
    _tunnelIngressVisible = tunnelIngressTogglesVisible(
      list: widget.entry.list,
      isMember: member != null,
      nodeBody: nodeBody,
    );

    // §578/§643/§656 — видимость `Skip Tailscale presets`: узел `tailscale`
    // и пресеты с обходом узлов из шаблона, чей `#filter` принимает узел.
    try {
      final template = await TemplateLoader.load();
      _skipPresetsVisible = skipTailscalePresetsToggleVisible(
        list: widget.entry.list,
        isMember: member != null,
        nodeTag: node.tag,
        nodeBody: nodeBody,
        presets: template.selectableRules,
      );
    } catch (_) {
      _skipPresetsVisible = false; // шаблон не загрузился — без переключателя
    }

    // §239 — кандидаты живут в общем пикере (showDetourTargetPicker):
    // «свободные» одиночки + члены СВОЕЙ папки (для member-режима).

    // §623 — пул доменов маскировки; не загрузился — поле без подсказок.
    if (node is WireguardSpec && _picker == null) {
      try {
        _picker = await WarpEndpointPicker.load();
      } catch (_) {
        _picker = null;
      }
    }

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

  /// §455 — Save вкладки Source: текст источника уходит в запись как есть.
  /// JSON — тег из поля Tag в тело (§435, `prepareNodeDocumentForSave`) и
  /// ворота ядра (`CheckConfig`): такой узел идёт в конфиг дословно, гейты
  /// модели его не проверяют. Ссылка — тег во фрагмент. INI — как есть.
  /// true — записано (§626: Save диалога Unsaved changes закрывает экран
  /// только при успехе).
  Future<bool> _saveSource() async {
    final text = _sourceCtrl.text.trim();
    if (text.isEmpty) {
      _snack(getLocalText.s("Source is empty"));
      return false;
    }
    final String toStore;
    var droppedExtras = false;
    var commentsRemoved = false;
    if (isJsonSourceText(text)) {
      // §435 — голое тело или документ; тег из поля Tag уходит в тело узла.
      // §575 — `dns`/`route`/`sections` документа не сохраняются.
      final prep = prepareNodeDocumentForSave(text, _tagCtrl.text);
      if (prep is NodeDocumentRejected) {
        _snack(prep.message);
        return false;
      }
      final ready = prep as NodeDocumentReady;
      toStore = ready.text;
      droppedExtras = ready.droppedExtras;
      commentsRemoved = ready.commentsRemoved;
      final payload = checkPayloadFor(toStore);
      if (payload != null) {
        final check = await BoxVpnClient.I.checkConfig(payload);
        if (!mounted) return false;
        // null — мост недоступен (юнит-тест, старый native): проверять нечем,
        // сохранение не блокируем.
        if (check != null && !check.ok) {
          _snack(getLocalText.s("The core rejected the node: %s", check.error));
          return false;
        }
      }
    } else if (!text.contains('\n') && text.contains('://')) {
      toStore = SubscriptionController.rawWithName(text, _tagCtrl.text.trim());
    } else {
      // §456 — INI: текст как есть, имя — полем записи (`nameHint`).
      return _store(text,
          nameHint: _tagCtrl.text.trim(),
          savedMessage: () => getLocalText.s("Saved"));
    }
    return _store(toStore,
        savedMessage: () => droppedExtras
            ? getLocalText.s(
                "Only the node is saved. The rest of the input is not kept.")
            : commentsRemoved
                ? getLocalText.s("Comments were removed.")
                : getLocalText.s("Saved"));
  }

  /// §686 — Save вкладки Source auto-узла: запись разбирается строго и
  /// пишется тем же путём, что Save редактора группы (`updateAutoMemberAt`).
  /// Отказ — сообщение, запись и текст в редакторе не меняются.
  Future<bool> _saveAutoSource() async {
    final group = _autoGroup;
    final mi = widget.memberIndex;
    if (group == null || mi == null) return false;
    final parsed = parseAutoGroupSource(_sourceCtrl.text, _folderId, group);
    if (parsed is AutoGroupSourceRejected) {
      _snack(parsed.message);
      return false;
    }
    final ready = parsed as AutoGroupSourceReady;
    final err = await widget.subController.updateAutoMemberAt(
        widget.index, mi, ready.group,
        enabled: ready.enabled);
    if (!mounted) return err == null;
    if (err != null) {
      _snack(err.render());
      return false;
    }
    await _load();
    if (!mounted) return true;
    _snack(getLocalText.s("Saved"));
    return true;
  }

  /// §581 — Save choice вкладки Network: `exit_node` = [value] (`null` —
  /// поле убирается) в теле узла, дальше тем же путём, что Save вкладки
  /// Source (тег из поля Tag, проверка ядром, запись, пересборка).
  Future<void> _saveExitNode(String? value) => _saveTailscaleFields({
        'exit_node': value == null || value.isEmpty ? null : value,
      });

  /// §613 — поля тела узла с вкладки Network (Save choice, переключатели
  /// Settings): `null` убирает поле; запись — как Save вкладки Source.
  Future<void> _saveTailscaleFields(Map<String, Object?> fields) async {
    final raw = _containerRaw.trim();
    final base = raw.startsWith('{') ? raw : _jsonCtrl.text;
    final String text;
    try {
      text = withBodyFields(base, fields);
    } on FormatException catch (e) {
      _snack(getLocalText.s("Invalid JSON: %s", e.message));
      return;
    }
    _sourceCtrl.text = text;
    await _saveSource();
  }

  /// §623 — выбор в секции Masquerade пишется сразу (как detour): ключи
  /// `ip`/`id`/`ib` в текст сохранённого источника (вид источника
  /// сохраняется, в отличие от Tailscale), дальше — как Save вкладки Source.
  /// Отказ (ядро, разбор) — Source возвращается к сохранённому тексту, строки
  /// секции остаются прежними.
  Future<void> _saveMasquerade(Masquerade m) async {
    final before = _containerRaw;
    _sourceCtrl.text = withMasquerade(before, m);
    await _saveSource();
    if (mounted && _containerRaw == before) _sourceCtrl.text = before;
  }

  /// §623 — секция Masquerade узла WireGuard/AmneziaWG. Явный `i1`
  /// приоритетнее: тогда секция недоступна; так же — у упакованной ссылки и
  /// у источника, в который писать не умеем.
  Widget _buildMasqueradeSection(WireguardSpec node) {
    final fields = node.awg?.fields;
    final raw = _containerRaw;
    final String? reason;
    if (fields?['i1'] != null) {
      final ignored = masqueradeKeysPresent(raw);
      reason = [
        getLocalText.s(
            "Masquerade is off: the node sets I1 explicitly, and I1 takes priority. Without I1 in Source this section becomes available."),
        if (ignored) getLocalText.s("The masquerade keys in Source are ignored."),
      ].join(' ');
    } else {
      reason = switch (masqueradeWritability(raw)) {
        MasqueradeWritability.writable => null,
        MasqueradeWritability.packedLink => getLocalText.s(
            "This source is a packed link. Masquerade can be changed after Edit JSON turns the node into JSON."),
        MasqueradeWritability.unsupportedFormat =>
          getLocalText.s("Masquerade is not supported for this source format."),
      };
    }
    final picker = _picker;
    return ListenableBuilder(
      listenable: _sourceCtrl,
      builder: (context, _) => MasqueradeSection(
        value: Masquerade.fromFields(fields),
        unavailableReason: reason,
        sipBlocked: fields?['i2'] != null,
        sourceDirty: _sourceCtrl.text != raw,
        onSourceDirty: () =>
            _snack(getLocalText.s("Source has unsaved changes.")),
        domainPool: picker?.sniPool ?? const [],
        randomDomain: picker?.randomSni,
        onChanged: _saveMasquerade,
      ),
    );
  }

  /// Записать [raw] источником узла (одиночный — `updateConnectionAt`, член
  /// папки — `updateMemberAt`) и перечитать экран.
  /// true — записано.
  Future<bool> _store(String raw,
      {String? nameHint, required String Function() savedMessage}) async {
    try {
      final mi = widget.memberIndex;
      // §237 — член папки: транзакционная правка raw (битый → откат).
      // §603 — одиночный сервер так же: битый источник не пишется.
      final err = mi != null
          ? await widget.subController
              .updateMemberAt(widget.index, mi, raw, nameHint: nameHint)
          : await widget.subController
              .updateConnectionAt(widget.index, [raw], nameHint: nameHint);
      if (!mounted) return err == null;
      if (err != null) {
        _snack(err.render());
        return false;
      }
      // Перечитать узел: Source показывает записанный текст, JSON — тело,
      // предупреждения — свежие.
      await _load();
      if (!mounted) return true;
      _snack(savedMessage());
      return true;
    } catch (e) {
      if (mounted) {
        _snack(getLocalText.s("Invalid JSON: %s", formatUserError(e).render()));
      }
      return false;
    }
  }

  /// §455 — кнопка Edit на вкладке JSON. У JSON-источника менять нечего —
  /// просто переход в Source. У ссылки/INI — предупреждение, затем источник
  /// заменяется предпросмотром (emit модели с тегом — валиден по построению,
  /// ворота ядра не нужны) и экран уводит в Source.
  Future<void> _editJson() async {
    if (_originKind == 'json') {
      _tabs.animateTo(_kSourceTab);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Edit JSON?")),
        content: Text(getLocalText.s(
            "The source will be replaced by this JSON and the node will go to the core as is. The app stops checking such a node: only the core validates it on save, and a mistake can leave it unable to connect. There is no way back to a link. Edit the source instead when you can.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Continue")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _store(_jsonCtrl.text,
        savedMessage: () => getLocalText.s("Source replaced with JSON"));
    if (!mounted) return;
    _tabs.animateTo(_kSourceTab);
  }

  /// §686 п. 9 — кнопка Edit INI на вкладке INI. У INI-источника менять
  /// нечего — переход в Source. Иначе предупреждение (с ключами, которых в
  /// `.conf` нет), источник заменяется текстом вкладки и экран уводит в
  /// Source. Тег и Detour — поля записи, замена их не трогает.
  Future<void> _editIni() async {
    if (_originKind == 'wg_ini') {
      _tabs.animateTo(_kSourceTab);
      return;
    }
    final ini = _ini;
    if (ini == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Edit INI?")),
        content: Text([
          getLocalText.s(
              "The source will be replaced by this INI. The tag and Detour stay as they are."),
          if (ini.lost.isNotEmpty)
            getLocalText.s("Not in INI: %s", ini.lost.join(', ')),
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Continue")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final stored = await _store(ini.text,
        nameHint: _originalTag,
        savedMessage: () => getLocalText.s("Source replaced with INI"));
    if (!stored || !mounted) return;
    _tabs.animateTo(_kSourceTab);
  }

  /// §686 п. 9 — Share `.conf`: файл во временном каталоге, имя от тега.
  Future<void> _shareIni() async {
    final ini = _ini;
    if (ini == null) return;
    final name = wireguardIniFileName(_originalTag);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$name';
      await File(path).writeAsString(ini.text);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'text/plain', name: name)],
      ));
    } catch (e) {
      _snack(formatUserError(e).render());
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  bool _saving = false;

  /// §626 — несохранённые правки: поле Tag (Settings) и текст Source
  /// отличаются от записанного. Detour, Masquerade, Skip Tailscale presets,
  /// переключатели входящих и поля вкладки Network пишутся сразу и правкой
  /// не считаются.
  bool get _dirty =>
      _originalTag.isNotEmpty &&
      (_tagCtrl.text != _originalTag || _sourceCtrl.text != _containerRaw);

  /// Save в AppBar и в диалоге Unsaved changes.
  Future<bool> _save() async {
    if (_saving) return false;
    _saving = true;
    try {
      return await (_autoGroup != null ? _saveAutoSource() : _saveSource());
    } finally {
      _saving = false;
    }
  }

  /// §626 — Back (системный, жест, стрелка AppBar): при правках общий
  /// диалог Discard / Keep / Save (§219). Загрузка и запись — без диалога.
  Future<void> _handleBack() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      if (await _save() && mounted) Navigator.pop(context);
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null (dismiss) — остаёмся.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_tagCtrl.text.isNotEmpty
              ? _tagCtrl.text
              : getLocalText.s("Node Settings")),
          actions: [
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: const Icon(Icons.save),
              onPressed: () => unawaited(_save()),
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: getLocalText.s("Settings")),
              Tab(text: getLocalText.s("Source")),
              // l10n-exempt: format name, locale-invariant
              const Tab(text: 'JSON'),
              // l10n-exempt: format name, locale-invariant
              if (_isWireguard) const Tab(text: 'INI'),
              if (_isTailscale) Tab(text: getLocalText.s("Network")),
              NodeDiagnosticsTabLabel(warnings: _notifications),
            ],
          ),
        ),
        body: _originalTag.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tabs,
                children: [
                  _buildSettingsTab(theme),
                  _buildSourceTab(theme),
                  _buildJsonTab(theme),
                  if (_isWireguard) _buildIniTab(theme),
                  if (_isTailscale)
                    TailscaleNetworkTab(
                      liveTag: TagResolver.displayTag(
                          widget.entry.list.tagPrefix, _originalTag),
                      body: _node is TailscaleSpec
                          ? (_node as TailscaleSpec).body
                          : const {},
                      onSaveExitNode: _saveExitNode,
                      onSaveFields: _saveTailscaleFields,
                    ),
                  // §392/§501 — диагностика + уведомления узла.
                  NodeDiagnosticsTab(
                    node: _node,
                    liveTag: TagResolver.displayTag(
                        widget.entry.list.tagPrefix, _originalTag),
                    warnings: _notifications,
                    scrollToNotifications: widget.initialTab ==
                        NodeSettingsScreen.diagnosticsTabIndex,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    if (_autoGroup != null) return _buildAutoGroupSettingsTab(theme);
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
        if (_node case final WireguardSpec wg) ...[
          const SizedBox(height: 16),
          _sectionHeader(getLocalText.s("Masquerade"),
              getLocalText.s(
                "AmneziaWG 1.5 parameters: decoy packets before the WireGuard handshake."),
              theme),
          _buildMasqueradeSection(wg),
        ],
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
        // §636 — TLS: узловое переопределение ручек «TLS Fragmentation».
        const SizedBox(height: 16),
        ..._buildTlsSection(theme),
        ], // §322 — конец гейта detour-блока
        const SizedBox(height: 16),
        ..._buildSkipPresetsBlock(theme),
        ..._buildTunnelIngressBlock(theme),
      ],
    );
  }

  /// §636 — узловая TLS-политика: член папки — `FolderMember.tls`, одиночный
  /// сервер — `UserServer.tls`. Читается при каждом build.
  TlsPolicy get _tls {
    final member = _member;
    if (member != null) return member.tls;
    return widget.entry.tls;
  }

  /// §636 — узел идёт через detour (личный или папочный): флаги TLS ему не
  /// пишутся (только first-hop), секция об этом говорит.
  bool get _underDetour {
    if (_detour.isNotEmpty) return true;
    final list = widget.entry.list;
    if (_member == null || list is! FolderServers) return false;
    final p = list.detourPolicy;
    return p.useDetourServers && p.overrideDetour.isNotEmpty;
  }

  List<Widget> _buildTlsSection(ThemeData theme) {
    final list = widget.entry.list;
    final folder = _member != null && list is FolderServers ? list : null;
    return [
      _sectionHeader(getLocalText.s("TLS"),
          getLocalText.s("Override the global TLS settings for this server."),
          theme),
      if (_underDetour)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            getLocalText.s("Not applied: traffic goes through a detour first."),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      TlsPolicyTiles(
        policy: _tls,
        inherited: folder?.tls ?? TlsPolicy.none,
        inheritedLevel: folder != null ? TlsLevel.folder : TlsLevel.global,
        // §665 — под detour уже «Not applied: …».
        inheritNotice: !_underDetour,
        onChanged: (v) => unawaited(_persistTls(v)),
      ),
    ];
  }

  /// §636 — запись сразу, как у detour: член папки → setMemberTls,
  /// одиночный → `entry.tls` + persistSources.
  Future<void> _persistTls(TlsPolicy value) async {
    final mi = widget.memberIndex;
    if (mi != null) {
      // Синхронная часть заменяет член до записи на диск — экран
      // перерисовывается сразу, не дожидаясь IO.
      final pending = widget.subController.setMemberTls(widget.index, mi, value);
      setState(() {});
      final err = await pending;
      if (err != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.render())));
        setState(() {});
      }
      return;
    }
    setState(() => widget.entry.tls = value);
    await widget.subController.persistSources();
  }

  /// §578/§656 — поле записи узла [flag], как хранит контейнер (одиночный —
  /// `UserServer`, член — `FolderMember`). Читается при каждом build.
  bool _recordFlag(NodeRecordFlag flag) {
    final member = _member;
    if (member != null) return flag.ofMember(member);
    final list = widget.entry.list;
    return list is UserServer && flag.ofServer(list);
  }

  /// §578/§656 — переключатель `Skip Tailscale presets`: узел не
  /// обслуживается пресетом `tailscale`
  /// (`#not @node.skip_tailscale_presets` в `#filter`).
  List<Widget> _buildSkipPresetsBlock(ThemeData theme) {
    if (!_skipPresetsVisible) return const [];
    return [
      SwitchListTile(
        key: const ValueKey('node-skip-presets'),
        secondary: const Icon(Icons.rule_folder_outlined, size: 20),
        title: Text(getLocalText.s("Skip Tailscale presets")),
        subtitle: Text(getLocalText
            .s("Presets will not add routing or DNS rules for this node.")),
        value: _recordFlag(NodeRecordFlag.skipTailscalePresets),
        onChanged: (v) => unawaited(
            _setRecordFlag(NodeRecordFlag.skipTailscalePresets, v)),
      ),
      const SizedBox(height: 16),
    ];
  }

  /// §656 (контракт 1.1.126) — входящие из туннеля: три поля записи узла,
  /// которые читает пресет `tunnel-ingress`. Без них пиры с той стороны
  /// туннеля получают reject.
  List<Widget> _buildTunnelIngressBlock(ThemeData theme) {
    if (!_tunnelIngressVisible) return const [];
    Widget flag(String key, IconData icon, NodeRecordFlag f, String title,
            String subtitle) =>
        SwitchListTile(
          key: ValueKey(key),
          secondary: Icon(icon, size: 20),
          title: Text(title),
          subtitle: Text(subtitle),
          value: _recordFlag(f),
          onChanged: (v) => unawaited(_setRecordFlag(f, v)),
        );
    return [
      _sectionHeader(
          getLocalText.s("Incoming connections from this tunnel"),
          getLocalText.s(
              "Peers on the other side of this tunnel can open connections to this device. Without the switches below they are rejected."),
          theme),
      flag(
          'node-allow-local',
          Icons.phone_android_outlined,
          NodeRecordFlag.allowLocal,
          getLocalText.s("Allow access to this device"),
          getLocalText.s(
              "Peers reach services on this device's tunnel address. The service sees them as 127.0.0.1, so everything that trusts localhost becomes reachable.")),
      flag(
          'node-allow-lan',
          Icons.lan_outlined,
          NodeRecordFlag.allowLan,
          getLocalText.s("Expose local network"),
          getLocalText.s("Peers reach private networks behind this device.")),
      flag(
          'node-allow-gateway',
          Icons.alt_route_outlined,
          NodeRecordFlag.allowGateway,
          getLocalText.s("Allow as gateway"),
          getLocalText.s(
              "Peers route any traffic through this device; it leaves through the outbound chosen in the Tunnel ingress preset.")),
      const SizedBox(height: 16),
    ];
  }

  Future<void> _setRecordFlag(NodeRecordFlag flag, bool value) async {
    final err = await widget.subController
        .setNodeRecordFlag(widget.index, widget.memberIndex, flag, value);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err.render())));
    }
    setState(() {});
  }

  /// §686 — Settings auto-узла: форма группы (общая с экраном создания).
  /// Источник истины — текст Source, как у формы OpenConnect: правка формы
  /// переписывает `tag` и `group` записи, правка текста руками доходит до
  /// формы; текст не объект — форма неактивна. Сохранение — Save экрана.
  /// Info, Masquerade, Detour и TLS у группы нет.
  Widget _buildAutoGroupSettingsTab(ThemeData theme) {
    final list = widget.entry.list;
    final candidates = list is FolderServers
        ? autoPoolCandidates(list)
        : const <AutoPoolCandidate>[];
    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        ListenableBuilder(
          listenable: _sourceCtrl,
          builder: (context, _) {
            final member = _member;
            final current = _autoGroup;
            if (member == null || current == null) {
              return const SizedBox.shrink();
            }
            final parsed =
                autoGroupFromSourceText(_sourceCtrl.text, _folderId, current);
            if (parsed != null) _autoLastGroup = parsed;
            final shown = parsed ?? _autoLastGroup ?? current;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (parsed == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        getLocalText.s(
                            "The form is off: Source is not a valid JSON object."),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  AutoGroupForm(
                    key: const ValueKey('node-auto-group-form'),
                    value: shown,
                    candidates: candidates,
                    enabled: parsed != null,
                    onChanged: (g) {
                      final next = autoGroupSourceWith(
                          _sourceCtrl.text, member, g, _folderId);
                      if (next != _sourceCtrl.text) _sourceCtrl.text = next;
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// §654 B2 — форма OpenConnect над редактором Source (общий виджет с Add
  /// server). Источник истины — текст `_sourceCtrl`, как у секции Masquerade:
  /// правка поля переписывает текст (формат и порядок ключей прежние), правка
  /// текста руками обновляет форму. Текст не объект — форма неактивна.
  /// Сохранение — Save экрана.
  Widget _buildOpenConnectSourceForm(ThemeData theme) => ListenableBuilder(
        listenable: _sourceCtrl,
        builder: (context, _) {
          final body = formBodyFromSource(_sourceCtrl.text);
          if (body != null) _ocLastBody = body;
          final shown = body ?? _ocLastBody;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (body == null)
                Text(
                  getLocalText.s(
                      "The form is off: Source is not a valid JSON object."),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              if (shown != null)
                OpenConnectForm(
                  key: const ValueKey('node-openconnect-form'),
                  body: shown,
                  enabled: body != null,
                  showErrors: true,
                  onChanged: (b) {
                    final next = sourceWithFormBody(_sourceCtrl.text, b);
                    if (next != _sourceCtrl.text) _sourceCtrl.text = next;
                  },
                ),
            ],
          );
        },
      );

  /// §455 — вкладка Source: `origin.raw` как есть, единственное место правки.
  Widget _buildSourceTab(ThemeData theme) {
    // §686 — у auto-узла источник — запись группы, подписи вида нет.
    final isAuto = _autoGroup != null;
    final kindNote = switch (_originKind) {
      'json' => getLocalText.s(
          "sing-box JSON: sent to the core as is. The core checks it on save."),
      'wg_ini' => getLocalText.s(
          "WireGuard config: saved as is. The tag is stored separately."),
      _ => getLocalText.s("Link: the tag goes into its fragment on save."),
    };
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        _sectionHeader(getLocalText.s("Source"),
            getLocalText.s("The node's original text. Save writes it as is."), theme),
        if (_node?.protocol == kOpenConnectScheme)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _buildOpenConnectSourceForm(theme),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          // §614/§624 — редактор с подсветкой: язык по виду источника на
          // лету (вставили ссылку, `.conf` или JSON — подсветка сменилась).
          // Подпись — слева в строке кнопок поля (поиск, Format).
          child: ListenableBuilder(
            listenable: _sourceCtrl,
            builder: (context, _) => LxTextCodeField(
              key: const ValueKey('node-source-editor'),
              controller: _sourceCtrl,
              minLines: 12,
              language: detectCodeLanguage(_sourceCtrl.text),
              header: isAuto
                  ? null
                  : Text(
                      kindNote,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  /// §455 — вкладка JSON: только чтение — то, что уйдёт в ядро (без префикса,
  /// detour и пост-шагов сборки). Кнопка Edit — см. [_editJson].
  Widget _buildJsonTab(ThemeData theme) {
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        _sectionHeader(getLocalText.s("Outbound JSON"),
            getLocalText.s("What the core receives. Read-only: edit the source instead."), theme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          // §624 — Copy в строке кнопок над рамкой, не поверх текста.
          child: LxJsonView(
            text: _jsonCtrl.text,
            height: 420,
            stickyHeaders: true,
            actions: [
              IconButton(
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
            ],
          ),
        ),
        // §686 — у группы нет тела узла, которое можно отдать ядру
        // дословно: правят форму или Source.
        if (_autoGroup == null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(getLocalText.s("Edit JSON")),
              onPressed: () => unawaited(_editJson()),
            ),
          ),
        ),
      ],
    );
  }

  /// §686 п. 9 — вкладка INI: только чтение — узел в виде `.conf`. Copy и
  /// Share `.conf` — в строке кнопок над рамкой, как Copy у JSON; под текстом
  /// — ключи тела, которых в `.conf` нет, и кнопка Edit INI ([_editIni]).
  Widget _buildIniTab(ThemeData theme) {
    final ini = _ini;
    final lost = ini?.lost ?? const <String>[];
    return ListView(
      padding:
          EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LxJsonView(
            text: ini?.text ?? '',
            height: 420,
            language: LxCodeLanguage.ini,
            actions: [
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: getLocalText.s("Copy"),
                visualDensity: VisualDensity.compact,
                onPressed: ini == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: ini.text));
                        _snack(getLocalText.s("INI copied"));
                      },
              ),
              IconButton(
                icon: const Icon(Icons.share, size: 16),
                tooltip: getLocalText.s("Share .conf"),
                visualDensity: VisualDensity.compact,
                onPressed: ini == null ? null : () => unawaited(_shareIni()),
              ),
            ],
          ),
        ),
        if (lost.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              getLocalText.s("Not in INI: %s", lost.join(', ')),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(getLocalText.s("Edit INI")),
              onPressed: ini == null ? null : () => unawaited(_editIni()),
            ),
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
