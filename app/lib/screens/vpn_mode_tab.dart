// §119 — VPN mode tab. Выбор как ядро ловит трафик (inbound-трактовка):
//   • VPN       — только tun-inbound (текущее поведение, default).
//   • Proxy     — только локальный mixed-inbound (HTTP+SOCKS), без TUN.
//   • VPN+Proxy — tun + mixed одновременно.
//
// UI для `vpn_mode` storage shape. Builder applyVpnMode() трансформирует это
// в config.inbounds. Смена режима меняет inbounds → требует FULL VPN restart
// (наследуется от config-dirty машинерии: home banner Apply/Restart).
//
// Data-driven рендер: presentational metadata (title/tooltip/options/type)
// читается из семи `wizard_ui: hidden` нод секции "VPN Mode" в
// wizard_template.json (vpn_mode/proxy_type/proxy_listen/proxy_port/
// proxy_user/proxy_pass/proxy_auth). ЗНАЧЕНИЯ при этом маппятся в
// типизированный VpnModeConfig (copyWith), НЕ в varsValues — ноды дают только
// метаданные. Ноды резолвятся по имени из `template.vars` (не `varsFor('core')`
// — тот фильтрует hidden).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/parser_config.dart' show WizardTemplate, WizardVar;
import '../services/settings_storage.dart'
    show SettingsStorage, VpnModeConfig, NativePrefsKeys;
import '../services/subscription/subscription_identity.dart'
    show generateProxyPassword;
import 'lazy_persist_mixin.dart';
import '../services/l10n/locale_controller.dart';

class VpnModeTab extends StatefulWidget {
  const VpnModeTab({
    super.key,
    required this.homeController,
    required this.subController,
    required this.template,
  });

  final HomeController homeController;
  final SubscriptionController subController;

  /// Загруженный wizard-template. Семь `vpn_mode`/`proxy_*` нод (все
  /// `wizard_ui: hidden`) поставляют title/tooltip/options/type для рендера.
  final WizardTemplate template;

  @override
  State<VpnModeTab> createState() => _VpnModeTabState();
}

class _VpnModeTabState extends State<VpnModeTab>
    with WidgetsBindingObserver, LazyPersistMixin<VpnModeTab> {
  VpnModeConfig _cfg = const VpnModeConfig.defaults();
  bool _loading = true;
  bool _showPassword = false;

  // §188 — TUN-зависимые native-тумблеры (keep-alive / allow-bypass) переехали
  // сюда из App Settings: осмысленны только при наличии TUN (`hasTun`). Хранятся
  // в native SharedPrefs (BoxVpnClient get/set), НЕ в vpn_mode storage.
  bool _keepOnExit = true; // §188 — дефолт ON
  bool _allowBypass = false;
  bool _tunTogglesLoaded = false;

  late final TextEditingController _portCtl;
  late final TextEditingController _userCtl;
  late final TextEditingController _passCtl;
  late final TextEditingController _listenCtl;
  String _portError = '';
  String _listenError = '';

  // ─── Ноды-метаданные (резолв по имени из полного template.vars) ───
  // `varsFor('core')` НЕ годится: он отфильтровывает wizard_ui == 'hidden',
  // а все семь нод именно hidden. Поэтому читаем из template.vars напрямую.
  late final WizardVar _vpnModeNode = _node('vpn_mode');
  late final WizardVar _proxyTypeNode = _node('proxy_type');
  late final WizardVar _listenNode = _node('proxy_listen');
  late final WizardVar _portNode = _node('proxy_port');
  late final WizardVar _userNode = _node('proxy_user');
  late final WizardVar _passNode = _node('proxy_pass');
  late final WizardVar _authNode = _node('proxy_auth');

  /// firstWhere без orElse — отсутствующая нода = баг bundled-темплейта
  /// (fail-fast, как TemplateLoader.validateIfConstructs).
  WizardVar _node(String name) =>
      widget.template.vars.firstWhere((v) => v.name == name);

  @override
  SubscriptionController get lazyController => widget.subController;

  @override
  void initState() {
    super.initState();
    _portCtl = TextEditingController();
    _userCtl = TextEditingController();
    _passCtl = TextEditingController();
    _listenCtl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _portCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _listenCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await SettingsStorage.getVpnMode();
    // §188/§189 — native-тумблеры (keep-alive / allow-bypass) читаем из
    // JSON-зеркала native_prefs (источник истины), не method-channel.
    final keep =
        await SettingsStorage.getNativeBool(NativePrefsKeys.keepOnExit);
    final bypass =
        await SettingsStorage.getNativeBool(NativePrefsKeys.allowBypass);
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _portCtl.text = cfg.proxyPort.toString();
      _userCtl.text = cfg.proxyUsername;
      _passCtl.text = cfg.proxyPassword;
      _listenCtl.text = cfg.proxyListen;
      _keepOnExit = keep;
      _allowBypass = bypass;
      _tunTogglesLoaded = true;
      _loading = false;
    });
  }

  // §188/§189 — keep-alive: пишем через NativePrefs (JSON-истина + зеркало в
  // native) + restart-banner. НЕ напрямую в native (иначе sync откатил бы).
  void _toggleKeepOnExit(bool val) {
    setState(() => _keepOnExit = val);
    unawaited(
        SettingsStorage.setNativeBool(NativePrefsKeys.keepOnExit, val));
    widget.homeController.markConfigChangedNeedRestart();
  }

  // §188/§189 — allow-bypass: через NativePrefs + restart-banner.
  void _toggleAllowBypass(bool val) {
    setState(() => _allowBypass = val);
    unawaited(
        SettingsStorage.setNativeBool(NativePrefsKeys.allowBypass, val));
    widget.homeController.markConfigChangedNeedRestart();
  }

  @override
  Future<void> stageChanges() async {
    await SettingsStorage.setVpnMode(_cfg, flush: false);
  }

  /// Любая мутация: staging + sync configDirty (mixin) + restart-banner если
  /// туннель поднят (смена inbounds → full restart).
  void _commit() {
    markDirty();
    widget.homeController.markConfigChangedNeedRestart();
  }

  void _setMode(String mode) {
    var next = _cfg.copyWith(mode: mode);
    // При переходе на режим с прокси + включённый auth + пустой пароль —
    // генерим (по образцу §118 HWID lazy-gen).
    if (next.hasMixed && next.effectiveAuth && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() => _cfg = next);
    // §192 — зеркалим has_tun в native: гейтит VpnService.prepare() (proxy →
    // не звать prepare → чужой VPN не отзывается). Производное от mode.
    unawaited(SettingsStorage.setNativeHasTun(next.hasTun));
    _commit();
  }

  void _setProtocol(String proto) {
    if (proto == _cfg.proxyProtocol) return;
    setState(() => _cfg = _cfg.copyWith(proxyProtocol: proto));
    _commit();
  }

  /// Применить введённый/выбранный listen-адрес. Невалидный IPv4 → errorText,
  /// не сохраняем. Не-loopback форсит auth on → генерим пароль если пуст.
  /// Свободно введённый IPv4 (например 127.10.20.5) идёт ПО ЭТОМУ ЖЕ пути.
  void _applyListen(String raw) {
    final addr = raw.trim();
    if (!VpnModeConfig.isValidListenAddr(addr)) {
      setState(() => _listenError = 'Enter a valid IPv4 (e.g. 127.0.0.1)');
      return;
    }
    if (addr == _cfg.proxyListen) {
      setState(() => _listenError = '');
      return;
    }
    var next = _cfg.copyWith(proxyListen: addr);
    // Не-loopback форсит auth on → пустой пароль надо сгенерить.
    if (next.effectiveAuth && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() {
      _listenError = '';
      _cfg = next;
    });
    _commit();
  }

  void _toggleAuth(bool enable) {
    var next = _cfg.copyWith(proxyAuthEnabled: enable);
    if (enable && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() => _cfg = next);
    _commit();
  }

  void _applyPort(String raw) {
    final port = int.tryParse(raw);
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _portError = 'Port must be 1024..65535');
      return;
    }
    if (port == _cfg.proxyPort) {
      setState(() => _portError = '');
      return;
    }
    setState(() {
      _portError = '';
      _cfg = _cfg.copyWith(proxyPort: port);
    });
    _commit();
  }

  void _applyUsername(String raw) {
    final u = raw.trim();
    if (u == _cfg.proxyUsername) return;
    setState(() => _cfg = _cfg.copyWith(proxyUsername: u));
    _commit();
  }

  void _applyPassword(String raw) {
    if (raw == _cfg.proxyPassword) return;
    setState(() => _cfg = _cfg.copyWith(proxyPassword: raw));
    _commit();
  }

  void _regeneratePassword() {
    final pass = generateProxyPassword();
    setState(() {
      _cfg = _cfg.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    });
    _commit();
  }

  // ─────────────────────────── render helpers ───────────────────────────

  /// Заголовок-строка `title` + info-иконка с tooltip ноды.
  Widget _labelRow(WizardVar node, TextStyle? style, {double iconSize = 18}) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Flexible(child: Text(node.title, style: style)),
        if (node.tooltip.isNotEmpty) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: node.tooltip,
            triggerMode: TooltipTriggerMode.tap,
            child: Icon(Icons.info_outline,
                size: iconSize, color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  /// Короткий лейбл для SegmentedButton: ведущий токен до ` — ` («VPN —
  /// system-wide tunnel» → «VPN»), чтобы сегменты не переполнялись.
  String _shortLabel(String title) {
    final i = title.indexOf(' — ');
    return i >= 0 ? title.substring(0, i) : title;
  }

  /// MODE (vpn_mode): SegmentedButton — явное исключение из «enum→dropdown»
  /// (решение юзера). Сегменты из node.options, короткие лейблы.
  Widget _buildModeSegments() {
    return SegmentedButton<String>(
      segments: _vpnModeNode.options
          .map((o) => ButtonSegment(
                value: o.value,
                label: Text(_shortLabel(o.title)),
              ))
          .toList(),
      selected: {_cfg.mode},
      onSelectionChanged: (s) => _setMode(s.first),
    );
  }

  /// PROTOCOL (proxy_type, enum+options): non-editable DropdownMenu.
  Widget _buildEnumDropdown(
    WizardVar node, {
    required String current,
    required ValueChanged<String> onSelected,
  }) {
    return DropdownMenu<String>(
      initialSelection: current,
      label: Text(node.title),
      expandedInsets: EdgeInsets.zero,
      dropdownMenuEntries: node.options
          .map((o) => DropdownMenuEntry(value: o.value, label: o.title))
          .toList(),
      onSelected: (v) {
        if (v != null) onSelected(v);
      },
    );
  }

  /// LISTEN (proxy_listen, text+options): EDITABLE combobox. requestFocusOnTap
  /// делает поле редактируемым → можно ввести произвольный IPv4 (не из
  /// options). onSelected ловит тап по подсказке; свободный ввод коммитится
  /// при потере фокуса (Focus.onFocusChange) через _applyListen — тот же
  /// валидирующий путь.
  Widget _buildListenCombobox() {
    return Focus(
      onFocusChange: (has) {
        if (!has) _applyListen(_listenCtl.text);
      },
      child: DropdownMenu<String>(
        controller: _listenCtl,
        requestFocusOnTap: true,
        enableFilter: false,
        label: Text(_listenNode.title),
        expandedInsets: EdgeInsets.zero,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        errorText: _listenError.isEmpty ? null : _listenError,
        dropdownMenuEntries: _listenNode.options
            .map((o) => DropdownMenuEntry(value: o.value, label: o.title))
            .toList(),
        onSelected: (v) {
          if (v != null) {
            _listenCtl.text = v;
            _applyListen(v);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad),
      children: [
        // ─── MODE (vpn_mode → SegmentedButton) ───
        _labelRow(_vpnModeNode, tt.titleMedium),
        const SizedBox(height: 8),
        _buildModeSegments(),
        const SizedBox(height: 8),
        Text(
          _modeDescription(_cfg.mode),
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),

        // ─── TUNNEL OPTIONS (§188): keep-alive + allow-bypass ───
        // Видны только при наличии TUN (vpn / vpn_proxy). В proxy-режиме оба
        // бессмысленны (нет VpnService.establish / Builder) → скрыты.
        if (_cfg.hasTun) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(getLocalText.s("Tunnel options"), style: tt.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(getLocalText.s("Keep VPN on exit")),
            subtitle: Text(getLocalText.s("VPN stays active when app is closed")),
            secondary: const Icon(Icons.exit_to_app),
            value: _keepOnExit,
            onChanged: _tunTogglesLoaded ? _toggleKeepOnExit : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(getLocalText.s("Allow VPN bypass")),
            subtitle: Text(
              _allowBypass
                  ? getLocalText.s("Apps may use ConnectivityManager to bypass tun.")
                  : getLocalText.s("Strict tunnel — all traffic goes through tun."),
            ),
            secondary: const Icon(Icons.alt_route),
            value: _allowBypass,
            onChanged: _tunTogglesLoaded ? _toggleAllowBypass : null,
          ),
        ],

        if (_cfg.hasMixed) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(getLocalText.s("Local proxy"), style: tt.titleMedium),
          const SizedBox(height: 12),

          // ─── PROTOCOL (proxy_type → dropdown) ───
          _labelRow(_proxyTypeNode, tt.bodyMedium, iconSize: 16),
          const SizedBox(height: 6),
          _buildEnumDropdown(
            _proxyTypeNode,
            current: _cfg.proxyProtocol,
            onSelected: _setProtocol,
          ),
          const SizedBox(height: 16),

          // ─── LISTEN (proxy_listen → editable combobox) ───
          _labelRow(_listenNode, tt.bodyMedium, iconSize: 16),
          const SizedBox(height: 6),
          _buildListenCombobox(),
          const SizedBox(height: 4),
          Text(
            _cfg.isPublicListen
                ? getLocalText.s("Reachable from other devices on the network — auth required.")
                : getLocalText.s("Reachable only from this device."),
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // ─── PORT (proxy_port → numeric field) ───
          TextField(
            controller: _portCtl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: _portNode.title,
              helperText: getLocalText.s("Range 1024..65535"),
              errorText: _portError.isEmpty ? null : _portError,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: _applyPort,
          ),
          const SizedBox(height: 16),

          // ─── AUTH (proxy_auth → switch; forced-on for non-loopback) ───
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_authNode.title),
            subtitle: Text(
              _cfg.isPublicListen
                  ? getLocalText.s("Required for LAN-exposed proxy (cannot be disabled).")
                  : getLocalText.s("Recommended. Protects the local proxy port."),
            ),
            value: _cfg.effectiveAuth,
            // 0.0.0.0 → залочен on (onChanged null = disabled).
            onChanged: _cfg.isPublicListen ? null : _toggleAuth,
          ),

          if (_cfg.effectiveAuth) ...[
            const SizedBox(height: 8),
            // ─── USER (proxy_user → text field) ───
            TextField(
              controller: _userCtl,
              decoration: InputDecoration(
                labelText: _userNode.title,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: _applyUsername,
            ),
            const SizedBox(height: 12),
            // ─── PASS (proxy_pass → masked + show/hide + regenerate) ───
            TextField(
              controller: _passCtl,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: _passNode.title,
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _showPassword
                          ? getLocalText.s("Hide")
                          : getLocalText.s("Show"),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                    IconButton(
                      tooltip: getLocalText.s("Regenerate"),
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: _regeneratePassword,
                    ),
                  ],
                ),
              ),
              onChanged: _applyPassword,
            ),
          ],
        ],
      ],
    );
  }

  String _modeDescription(String mode) {
    switch (mode) {
      case 'proxy':
        return 'Local HTTP+SOCKS proxy only. No system-wide tunnel, no VPN key '
            'icon. Point apps at the proxy manually.';
      case 'vpn_proxy':
        return 'System-wide tunnel AND a local proxy port at the same time.';
      default:
        return 'System-wide tunnel — all traffic goes through the VPN (default).';
    }
  }
}
