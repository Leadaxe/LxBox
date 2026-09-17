import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../controllers/subscription_controller.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import '../models/tls_spec.dart';
import '../services/parser/uri_utils.dart' show newUuidV4;
import '../services/ui_helpers.dart';
import '../widgets/emoji_picker_button.dart';
import '../widgets/lx_code_editor.dart';
import '../services/l10n/locale_controller.dart';
import '../services/subscription/subscription_identity.dart';
import '../widgets/safe_bottom.dart';
import '../models/tailscale_bundle.dart';

// SocksSpec.emit() требует TemplateVars — для wizard-created SOCKS5 без
// substitution используем пустые. Это match'ит manual UserServer pattern
// (no template processing).
final TemplateVars _emptyVars = TemplateVars.empty;

/// §074 — Add server wizard. Full-screen route с 5 tabs: SOCKS5 form,
/// HTTP form (§222), Paste URI, Paste JSON, Tailscale form (§435).
/// Открывается long-press'ом на «+» в Subscriptions screen.
///
/// Submit поведение:
///   - SOCKS5 / HTTP tabs → конструируют `SocksSpec`/`HttpSpec` +
///     `UserServer`, через `subController.addUserServer(...)`.
///   - URI / JSON tabs → text идёт в `subController.addFromInput(...)`
///     (тот же путь что у tap-«+»).
///   - Tailscale tab (§435) → `TailscaleSpec` + `UserServer` с канонической
///     связкой секций (`tailscale_bundle.dart`), через `addUserServer`.
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
    with SingleTickerProviderStateMixin, SnackHelper {
  late final TabController _tab;

  // Дефолтные tag'и при пустом поле Tag (поле опционально с §243).
  static const _kDefaultSocksTag = 'local-socks5-out';
  static const _kDefaultHttpTag = 'local-http-out';

  // SOCKS5 tab controllers.
  //
  // §243 — отдельного поля «Display name» (= UserServer.name) больше нет:
  // заголовок записи в списке Servers — это tag узла (displayName игнорирует
  // UserServer.name), поэтому поле Tag — единственный источник имени. Поле
  // опционально: пусто → _kDefaultSocksTag. SocksSpec.label = tag для
  // lossless serialization через JSON outbound (parseSingboxEntry читает
  // tag, label = tag) — tag переживает рестарт через re-parse rawBody.
  final _socksTag = TextEditingController();
  final _socksHost = TextEditingController(text: '127.0.0.1');
  final _socksPort = TextEditingController(text: '1080');
  final _socksUser = TextEditingController();
  final _socksPass = TextEditingController();
  final _socksFormKey = GlobalKey<FormState>();

  // HTTP tab controllers (§222) — зеркало SOCKS5-формы + TLS switch.
  final _httpTag = TextEditingController();
  final _httpHost = TextEditingController(text: '127.0.0.1');
  final _httpPort = TextEditingController(text: '8080');
  final _httpUser = TextEditingController();
  final _httpPass = TextEditingController();
  final _httpFormKey = GlobalKey<FormState>();
  bool _httpTls = false;

  // Paste URI tab controller (multi-line text area). §333 — построчный
  // редактор: сюда вставляют и простыни на тысячи ссылок.
  final _uriCtrl = CodeLineEditingController();

  // Paste JSON tab controller.
  final _jsonCtrl = CodeLineEditingController();

  // §435 — Tailscale tab (NODE_SECTIONS.md §6 «конструктор»). Тело
  // endpoint'а собирается из полей как есть: пустые не пишутся, булевы —
  // только `true` (дефолт ядра — false). Auth key — секрет: в лог не идёт,
  // поле маскировано с show/hide.
  static const _kDefaultTailscaleTag = 'tailscale';
  final _tsTag = TextEditingController();
  final _tsAuthKey = TextEditingController();
  final _tsControlUrl = TextEditingController();
  final _tsHostname = TextEditingController();
  final _tsExitNode = TextEditingController();
  final _tsFormKey = GlobalKey<FormState>();
  bool _tsEphemeral = false;
  bool _tsAcceptRoutes = false;
  bool _tsShowKey = false;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    _tab.addListener(() => setState(() {})); // обновить Add button enabled
    // §449 — hostname узла Tailscale: дефолт видно до создания узла, юзер его
    // правит или стирает (пусто = имя выбирает tsnet, как было).
    _tsHostname.text =
        defaultTailscaleHostname(SubscriptionIdentity.effectiveDeviceModel);
  }

  @override
  void dispose() {
    _tab.dispose();
    _socksTag.dispose();
    _socksHost.dispose();
    _socksPort.dispose();
    _socksUser.dispose();
    _socksPass.dispose();
    _httpTag.dispose();
    _httpHost.dispose();
    _httpPort.dispose();
    _httpUser.dispose();
    _httpPass.dispose();
    _uriCtrl.dispose();
    _jsonCtrl.dispose();
    _tsTag.dispose();
    _tsAuthKey.dispose();
    _tsControlUrl.dispose();
    _tsHostname.dispose();
    _tsExitNode.dispose();
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
          await _submitHttp();
        case 2:
          await _submitInput(_uriCtrl.text);
        case 3:
          await _submitInput(_jsonCtrl.text);
        case 4:
          await _submitTailscale();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §435 — узел Tailscale: `TailscaleSpec` с телом из полей формы и
  /// `UserServer` с канонической связкой (маршрут `100.64.0.0/10` → узел,
  /// DNS-сервер `@{self}-dns`, правило `.ts.net`). `rawBody` = `toUri()` —
  /// компактный JSON endpoint'а с `tag`: `UserServer.fromJson` ре-парсит его
  /// как `singboxOutbound`, tag переживает рестарт. Без `exit_node` узел не
  /// кандидат Направлений (это делает сборка), но связка работает.
  Future<void> _submitTailscale() async {
    if (!(_tsFormKey.currentState?.validate() ?? false)) return;
    final tagInput = _tsTag.text.trim();
    final tag = tagInput.isNotEmpty ? tagInput : _kDefaultTailscaleTag;
    final controlUrl = _tsControlUrl.text.trim();
    final hostname = _tsHostname.text.trim();
    final exitNode = _tsExitNode.text.trim();

    final spec = TailscaleSpec(
      id: newUuidV4(),
      tag: tag,
      label: tag,
      body: {
        'auth_key': _tsAuthKey.text.trim(),
        if (controlUrl.isNotEmpty) 'control_url': controlUrl,
        if (hostname.isNotEmpty) 'hostname': hostname,
        if (_tsEphemeral) 'ephemeral': true,
        if (_tsAcceptRoutes) 'accept_routes': true,
        if (exitNode.isNotEmpty) 'exit_node': exitNode,
      },
    );
    // §243 — name всегда пуст: заголовок записи = tag узла.
    final us = UserServer(
      id: newUuidV4(),
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      rawBody: spec.toUri(),
      nodes: [spec],
      sections: canonicalTailscaleSections(),
    );
    await widget.subController.addUserServer(us);
    await _afterAdd(addedTag: tag);
  }

  Future<void> _submitSocks() async {
    if (!(_socksFormKey.currentState?.validate() ?? false)) return;
    // §243 — пустое поле Tag → дефолтный tag (поле опционально).
    final tagInput = _socksTag.text.trim();
    final tag = tagInput.isNotEmpty ? tagInput : _kDefaultSocksTag;
    final host = _socksHost.text.trim();
    // Defensive parse — validator уже отфильтровал, но int.parse бросит
    // на любой raceconditional edge. tryParse ?? 0 + дополнительная
    // проверка returns раньше чем мы упрёмся в SocksSpec assertion'ы.
    final port = int.tryParse(_socksPort.text.trim()) ?? 0;
    if (port < 1 || port > 65535) {
      showSnack(getLocalText.s("Invalid port"));
      return;
    }
    final user = _socksUser.text;
    final pass = _socksPass.text;

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
      rawSource: '',
      username: user,
      password: pass,
    );
    // rawBody = JSON outbound (sing-box format). UserServer.fromJson
    // re-parsит rawBody через parseSingboxEntry → tag preserved exactly.
    // Альтернатива (toUri) теряет tag в URI fragment round-trip.
    // §243 — name всегда пуст: заголовок записи = tag узла (displayName
    // игнорирует UserServer.name).
    final outboundJson = spec.emit(_emptyVars).map;
    final us = UserServer(
      id: newUuidV4(),
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      rawBody: jsonEncode(outboundJson),
      nodes: [spec],
    );
    await widget.subController.addUserServer(us);
    await _afterAdd(addedTag: tag);
  }

  /// §222 — зеркало [_submitSocks] для HTTP(S)-прокси. Тот же lossless-путь:
  /// label = tag, rawBody = JSON outbound (parseSingboxEntry сохраняет tag).
  Future<void> _submitHttp() async {
    if (!(_httpFormKey.currentState?.validate() ?? false)) return;
    // §243 — пустое поле Tag → дефолтный tag (поле опционально).
    final tagInput = _httpTag.text.trim();
    final tag = tagInput.isNotEmpty ? tagInput : _kDefaultHttpTag;
    final host = _httpHost.text.trim();
    final port = int.tryParse(_httpPort.text.trim()) ?? 0;
    if (port < 1 || port > 65535) {
      showSnack(getLocalText.s("Invalid port"));
      return;
    }

    final spec = HttpSpec(
      id: newUuidV4(),
      tag: tag,
      label: tag,
      server: host,
      port: port,
      rawSource: '',
      username: _httpUser.text,
      password: _httpPass.text,
      // Тонкая настройка TLS (sni/insecure/alpn) — через JSON-редактор ноды.
      tls: _httpTls
          ? TlsSpec(enabled: true, serverName: host)
          : TlsSpec.disabled,
    );
    // §243 — name всегда пуст: заголовок записи = tag узла.
    final outboundJson = spec.emit(_emptyVars).map;
    final us = UserServer(
      id: newUuidV4(),
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      rawBody: jsonEncode(outboundJson),
      nodes: [spec],
    );
    await widget.subController.addUserServer(us);
    await _afterAdd(addedTag: tag);
  }

  Future<void> _submitInput(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      showSnack(getLocalText.s("Input is empty"));
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
    if (err != null) {
      showSnack(err.render());
      return;
    }
    await widget.onAdded();
    if (!mounted) return;
    final msg = addedTag != null && addedTag.isNotEmpty
        ? getLocalText.s("Added: %s", addedTag)
        : getLocalText.s("Added");
    showSnack(msg);
    Navigator.of(context).pop();
  }

  // §219 — _showSnack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Add server")),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(getLocalText.s("Cancel")),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(getLocalText.s("Add")),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: getLocalText.s("SOCKS5")),
            Tab(text: getLocalText.s("HTTP")),
            Tab(text: getLocalText.s("Paste URI")),
            Tab(text: getLocalText.s("Paste JSON")),
            // §435 — последней, чтобы индексы прежних вкладок не поехали.
            // l10n-exempt: protocol name
            const Tab(text: 'Tailscale'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildSocksForm(context),
          _buildHttpForm(context),
          _buildUriPaste(context),
          _buildJsonPaste(context),
          _buildTailscaleForm(context),
        ],
      ),
    );
  }

  /// §435 — вставка эмодзи из пикера в позицию курсора поля Tag (Tailscale).
  void _insertTailscaleTagEmoji(String emoji) {
    final text = _tsTag.text;
    final sel = _tsTag.selection;
    final start =
        (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    final end = (sel.end >= 0 && sel.end <= text.length) ? sel.end : start;
    final insert = '$emoji ';
    _tsTag.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
  }

  /// §435 — форма Tailscale (NODE_SECTIONS.md §6): Tag, Auth key (секрет,
  /// обязателен, с подсказкой про одноразовый ключ и каталог состояния),
  /// Control URL, Hostname, Ephemeral, Accept routes, Exit node.
  Widget _buildTailscaleForm(BuildContext context) {
    final hintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32).withSafeBottom(context),
      child: Form(
        key: _tsFormKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(getLocalText.s("Tag (optional)")),
            TextFormField(
              controller: _tsTag,
              decoration: _input(_kDefaultTailscaleTag).copyWith(
                suffixIcon: EmojiPickerButton(onPick: _insertTailscaleTagEmoji),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              getLocalText.s("Shown as the server title in the Servers list. If empty, \"%s\" is used.", _kDefaultTailscaleTag),
              style: hintStyle,
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Auth key")),
            TextFormField(
              controller: _tsAuthKey,
              obscureText: !_tsShowKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _input('tskey-auth-…').copyWith(
                suffixIcon: IconButton(
                  tooltip: _tsShowKey
                      ? getLocalText.s("Hide")
                      : getLocalText.s("Show"),
                  icon: Icon(
                    _tsShowKey ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _tsShowKey = !_tsShowKey),
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? getLocalText.s("Auth key required")
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              getLocalText.s("A one-time key is consumed on the first login; the device identity then lives in the state directory. Clearing the app data registers a new device."),
              style: hintStyle,
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Control URL (optional)")),
            TextFormField(
              controller: _tsControlUrl,
              decoration: _input('https://controlplane.tailscale.com'),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Hostname (optional)")),
            TextFormField(
              controller: _tsHostname,
              decoration: _input(''),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(getLocalText.s("Ephemeral")),
              subtitle: Text(getLocalText.s("The device is removed from the tailnet when it goes offline")),
              value: _tsEphemeral,
              onChanged: (v) => setState(() => _tsEphemeral = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(getLocalText.s("Accept routes")),
              subtitle: Text(getLocalText.s("Use subnet routes advertised by other tailnet devices")),
              value: _tsAcceptRoutes,
              onChanged: (v) => setState(() => _tsAcceptRoutes = v),
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Exit node (optional)")),
            TextFormField(
              controller: _tsExitNode,
              decoration: _input(''),
              autocorrect: false,
            ),
            const SizedBox(height: 6),
            Text(
              getLocalText.s("Tailscale IP or machine name of a peer that advertises an exit node; pick this node as the Direction on Home to route your internet through it. Leave empty for tailnet access only — the node will not appear in Directions"),
              style: hintStyle,
            ),
          ],
        ),
      ),
    );
  }

  /// §090 G2b — вставка эмодзи из пикера в позицию курсора поля Tag (SOCKS).
  void _insertSocksTagEmoji(String emoji) {
    final text = _socksTag.text;
    final sel = _socksTag.selection;
    final start =
        (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    final end = (sel.end >= 0 && sel.end <= text.length) ? sel.end : start;
    final insert = '$emoji ';
    _socksTag.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
  }

  Widget _buildSocksForm(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32).withSafeBottom(context),
      child: Form(
        key: _socksFormKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // §243 — tag = заголовок записи; поле опционально (пусто →
            // дефолтный tag). Отдельного «Display name» больше нет.
            _label(getLocalText.s("Tag (optional)")),
            TextFormField(
              controller: _socksTag,
              decoration: _input(_kDefaultSocksTag).copyWith(
                suffixIcon: EmojiPickerButton(onPick: _insertSocksTagEmoji),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              getLocalText.s("Shown as the server title in the Servers list. If empty, \"%s\" is used.", _kDefaultSocksTag),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Host")),
            TextFormField(
              controller: _socksHost,
              decoration: _input('127.0.0.1'),
              keyboardType: TextInputType.url,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? getLocalText.s("Host required")
                  : null,
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Port")),
            TextFormField(
              controller: _socksPort,
              decoration: _input('1080'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n < 1 || n > 65535) {
                  return getLocalText.s("Port 1..65535");
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Username (optional)")),
            TextFormField(
              controller: _socksUser,
              decoration: _input(''),
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Password (optional)")),
            TextFormField(
              controller: _socksPass,
              decoration: _input(''),
              obscureText: true,
            ),
          ],
        ),
      ),
    );
  }

  /// §222 — вставка эмодзи из пикера в позицию курсора поля Tag (HTTP).
  void _insertHttpTagEmoji(String emoji) {
    final text = _httpTag.text;
    final sel = _httpTag.selection;
    final start =
        (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    final end = (sel.end >= 0 && sel.end <= text.length) ? sel.end : start;
    final insert = '$emoji ';
    _httpTag.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
  }

  Widget _buildHttpForm(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32).withSafeBottom(context),
      child: Form(
        key: _httpFormKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // §243 — tag = заголовок записи; поле опционально (пусто →
            // дефолтный tag). Отдельного «Display name» больше нет.
            _label(getLocalText.s("Tag (optional)")),
            TextFormField(
              controller: _httpTag,
              decoration: _input(_kDefaultHttpTag).copyWith(
                suffixIcon: EmojiPickerButton(onPick: _insertHttpTagEmoji),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              getLocalText.s("Shown as the server title in the Servers list. If empty, \"%s\" is used.", _kDefaultHttpTag),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Host")),
            TextFormField(
              controller: _httpHost,
              decoration: _input('127.0.0.1'),
              keyboardType: TextInputType.url,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? getLocalText.s("Host required")
                  : null,
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Port")),
            TextFormField(
              controller: _httpPort,
              decoration: _input('8080'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n < 1 || n > 65535) {
                  return getLocalText.s("Port 1..65535");
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Username (optional)")),
            TextFormField(
              controller: _httpUser,
              decoration: _input(''),
            ),
            const SizedBox(height: 12),
            _label(getLocalText.s("Password (optional)")),
            TextFormField(
              controller: _httpPass,
              decoration: _input(''),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(getLocalText.s("HTTPS (TLS to proxy)")),
              subtitle: Text(getLocalText.s("Connect to the proxy over TLS. Advanced TLS options (SNI, ALPN) can be edited later via node JSON.")),
              value: _httpTls,
              onChanged: (v) => setState(() => _httpTls = v),
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
          _label(getLocalText.s("Paste a proxy URL")),
          Expanded(
            child: LxCodeEditor(
              controller: _uriCtrl,
              fontSize: 13,
              hint:
                  'vless://… / vmess://… / trojan://… / socks5://… / proxy-http://… / wireguard://…',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            getLocalText.s("Supported: vless / vmess / trojan / ss / hy2 / tuic / socks5 / proxy-http(s) / wireguard URLs"),
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
          _label(getLocalText.s("Paste a sing-box outbound JSON")),
          Expanded(
            child: LxCodeEditor(
              controller: _jsonCtrl,
              fontSize: 13,
              hint: '{"type": "vless", "tag": "…", …}',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            getLocalText.s("Single object or array of outbounds. WireGuard routes to endpoints[] automatically."),
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
