import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../services/parser/uri_utils.dart' show newUuidV4;

// SocksSpec.emit() требует TemplateVars — для wizard-created SOCKS5 без
// substitution используем пустые. Это match'ит manual UserServer pattern
// (no template processing).
final TemplateVars _emptyVars = TemplateVars.empty;

/// §074 — Add server wizard. Full-screen route с 3 tabs: SOCKS5 form,
/// Paste URI, Paste JSON. Открывается long-press'ом на «+» в
/// Subscriptions screen.
///
/// Submit поведение:
///   - SOCKS5 tab → конструирует `SocksSpec` + `UserServer`, через
///     `subController.addUserServer(...)`.
///   - URI / JSON tabs → text идёт в `subController.addFromInput(...)`
///     (тот же путь что у tap-«+»).
///
/// После successful add → callback [onAdded] (regenerate config + save +
/// snackbar в parent screen).
class AddServerWizardScreen extends StatefulWidget {
  const AddServerWizardScreen({
    super.key,
    required this.subController,
    required this.onAdded,
  });

  final SubscriptionController subController;
  final Future<void> Function() onAdded;

  @override
  State<AddServerWizardScreen> createState() => _AddServerWizardScreenState();
}

class _AddServerWizardScreenState extends State<AddServerWizardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // SOCKS5 tab controllers.
  final _socksTag = TextEditingController(text: 'local-socks5-out');
  final _socksHost = TextEditingController(text: '127.0.0.1');
  final _socksPort = TextEditingController(text: '1080');
  final _socksUser = TextEditingController();
  final _socksPass = TextEditingController();
  // §074 — «Display name» = UserServer.name (persisted натив'но, не через
  // rawBody round-trip). SocksSpec.label = tag для lossless serialization
  // через JSON outbound (parseSingboxEntry читает tag, label = tag).
  // Раньше в spec'е было отдельное «label» поле в SocksSpec — но URI/JSON
  // round-trip с `label != tag` ломал ссылки в routing rules (label
  // derive'ит tag в URI parser, или label = tag в JSON parser).
  final _socksName = TextEditingController();
  final _socksFormKey = GlobalKey<FormState>();

  // Paste URI tab controller (multi-line text area).
  final _uriCtrl = TextEditingController();

  // Paste JSON tab controller.
  final _jsonCtrl = TextEditingController();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() => setState(() {})); // обновить Add button enabled
  }

  @override
  void dispose() {
    _tab.dispose();
    _socksTag.dispose();
    _socksHost.dispose();
    _socksPort.dispose();
    _socksUser.dispose();
    _socksPass.dispose();
    _socksName.dispose();
    _uriCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      switch (_tab.index) {
        case 0:
          await _submitSocks();
        case 1:
          await _submitInput(_uriCtrl.text);
        case 2:
          await _submitInput(_jsonCtrl.text);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitSocks() async {
    if (!(_socksFormKey.currentState?.validate() ?? false)) return;
    final tag = _socksTag.text.trim();
    final host = _socksHost.text.trim();
    // Defensive parse — validator уже отфильтровал, но int.parse бросит
    // на любой raceconditional edge. tryParse ?? 0 + дополнительная
    // проверка returns раньше чем мы упрёмся в SocksSpec assertion'ы.
    final port = int.tryParse(_socksPort.text.trim()) ?? 0;
    if (port < 1 || port > 65535) {
      _showSnack('Invalid port');
      return;
    }
    final user = _socksUser.text;
    final pass = _socksPass.text;
    final name = _socksName.text.trim();

    // Construct SocksSpec с label = tag — иначе round-trip ломается:
    // URI persists fragment (label) и tag re-derive'ится из fragment'а
    // на reload, теряя original tag. JSON-outbound persistence — label
    // = tag нативно. Сохраняем lossless для обоих путей.
    final spec = SocksSpec(
      id: newUuidV4(),
      tag: tag,
      label: tag,
      server: host,
      port: port,
      rawUri: '',
      username: user,
      password: pass,
    );
    // rawBody = JSON outbound (sing-box format). UserServer.fromJson
    // re-parsит rawBody через parseSingboxEntry → tag preserved exactly.
    // Альтернатива (toUri) теряет tag в URI fragment round-trip.
    final outboundJson = spec.emit(_emptyVars).map;
    final us = UserServer(
      id: newUuidV4(),
      name: name.isNotEmpty ? name : tag,
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.now(),
      rawBody: jsonEncode(outboundJson),
      nodes: [spec],
    );
    await widget.subController.addUserServer(us);
    await _afterAdd(addedTag: tag);
  }

  Future<void> _submitInput(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _showSnack('Input is empty');
      return;
    }
    await widget.subController.addFromInput(trimmed);
    await _afterAdd(addedTag: null);
  }

  /// После successful add: regenerate config через callback, snack, pop.
  ///
  /// Snackbar показывает tag, который **юзер ввёл**, не финальный после
  /// builder'а. `EmitContext.allocateTag` может суффиксовать `-1`/`-2` при
  /// коллизии — но это происходит в build pipeline уже после add'а,
  /// controller'у не возвращается. Если потребуется показать final tag —
  /// нужно plumbing'ть addUserServer чтобы возвращал диагностику от
  /// builder'а. Сейчас trade-off: проще + честно (юзер видит свой ввод).
  Future<void> _afterAdd({String? addedTag}) async {
    if (!mounted) return;
    final err = widget.subController.lastError;
    if (err.isNotEmpty) {
      _showSnack(err);
      return;
    }
    await widget.onAdded();
    if (!mounted) return;
    final msg = addedTag != null && addedTag.isNotEmpty
        ? 'Added: $addedTag'
        : 'Added';
    _showSnack(msg);
    Navigator.of(context).pop();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add server'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: const Text('Add'),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'SOCKS5'),
            Tab(text: 'Paste URI'),
            Tab(text: 'Paste JSON'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildSocksForm(context),
          _buildUriPaste(context),
          _buildJsonPaste(context),
        ],
      ),
    );
  }

  Widget _buildSocksForm(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Form(
        key: _socksFormKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label('Tag'),
            TextFormField(
              controller: _socksTag,
              decoration: _input('local-socks5-out'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Tag required' : null,
            ),
            const SizedBox(height: 12),
            _label('Host'),
            TextFormField(
              controller: _socksHost,
              decoration: _input('127.0.0.1'),
              keyboardType: TextInputType.url,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Host required' : null,
            ),
            const SizedBox(height: 12),
            _label('Port'),
            TextFormField(
              controller: _socksPort,
              decoration: _input('1080'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n < 1 || n > 65535) return 'Port 1..65535';
                return null;
              },
            ),
            const SizedBox(height: 12),
            _label('Username (optional)'),
            TextFormField(
              controller: _socksUser,
              decoration: _input(''),
            ),
            const SizedBox(height: 12),
            _label('Password (optional)'),
            TextFormField(
              controller: _socksPass,
              decoration: _input(''),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            _label('Display name (optional)'),
            TextFormField(
              controller: _socksName,
              decoration: _input('My local proxy'),
            ),
            const SizedBox(height: 6),
            Text(
              'Shown as the entry title in Subscriptions list. If empty, '
              'tag is used as the title.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUriPaste(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('Paste a proxy URL'),
          Expanded(
            child: TextField(
              controller: _uriCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: _input(
                  'vless://… / vmess://… / trojan://… / socks5://… / wireguard://…'),
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Supported: vless / vmess / trojan / ss / hy2 / tuic / socks5 / wireguard URLs',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildJsonPaste(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('Paste a sing-box outbound JSON'),
          Expanded(
            child: TextField(
              controller: _jsonCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: _input('{"type": "vless", "tag": "…", …}'),
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Single object or array of outbounds. WireGuard routes to endpoints[] automatically.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
      );

  InputDecoration _input(String hint) => InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
}
