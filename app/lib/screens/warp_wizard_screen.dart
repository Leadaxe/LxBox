import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../services/warp/awg_junk.dart';
import '../services/warp/warp_account.dart';
import '../services/warp/warp_endpoint_picker.dart';

/// §025 — Full-screen визард «Get WARP». Открывается из overflow-меню
/// Subscriptions. Один тап «Register» для free; license/endpoint опциональны
/// под «Advanced».
///
/// Поведение: `subController.addWarp(...)` регистрирует устройство в Cloudflare
/// (приватный ключ генерится на телефоне) и добавляет готовый WireGuard-узел.
/// После успеха → [onAdded] (regenerate config + save в parent) → pop.
class WarpWizardScreen extends StatefulWidget {
  const WarpWizardScreen({
    super.key,
    required this.subController,
    required this.onAdded,
  });

  final SubscriptionController subController;
  final Future<void> Function() onAdded;

  @override
  State<WarpWizardScreen> createState() => _WarpWizardScreenState();
}

class _WarpWizardScreenState extends State<WarpWizardScreen> {
  final _license = TextEditingController();
  final _endpoint =
      TextEditingController(text: WarpAccount.defaultEndpoint);

  // §136 — QUIC-параметры (Advanced). Пустой SNI → рандом из пула.
  final _sni = TextEditingController();
  List<String> _sniPool = const []; // подсказки для DropdownMenu
  int _quicLevel = 0;
  final _jc = TextEditingController(text: '4');
  final _jmin = TextEditingController(text: '40');
  final _jmax = TextEditingController(text: '70');

  bool _forceNew = false;
  bool _busy = false;
  WarpAccount? _result;

  // §126/§136 — AmneziaWG обфускация (default off — обычный WARP).
  bool _obfuscate = false;
  JunkTemplate _template = JunkTemplate.quic;

  WarpEndpointPicker? _picker; // §136 — для рандома endpoint/SNI
  bool _endpointAutoFilled = false; // §136 — endpoint в поле = наш авто-рандом

  @override
  void initState() {
    super.initState();
    // §136 — подтягиваем picker (SNI-пул для dropdown + рандом endpoint).
    WarpEndpointPicker.load().then((p) {
      if (!mounted) return;
      setState(() {
        _picker = p;
        _sniPool = p.sniPool;
      });
      // Если юзер успел включить обфускацию до загрузки picker — заполняем.
      if (_obfuscate && _endpointReplaceable) _fillRandomEndpoint();
    });
  }

  /// §136 — генерирует рандомный endpoint в поле (при включении обфускации /
  /// по кнопке refresh). Помечает поле как авто-заполненное.
  void _fillRandomEndpoint() {
    final ep = _picker?.randomEndpoint();
    if (ep != null) {
      setState(() {
        _endpoint.text = ep;
        _endpointAutoFilled = true;
      });
    }
  }

  /// true если в поле endpoint — дефолт/пусто/наш авто-рандом (не вписан юзером
  /// вручную → можно перезаписать).
  bool get _endpointReplaceable {
    final v = _endpoint.text.trim();
    return v.isEmpty || v == WarpAccount.defaultEndpoint || _endpointAutoFilled;
  }

  /// §136 — снятие галки обфускации → все обфускация-поля в стандарт.
  /// Endpoint возвращаем к дефолту только если он был НАШИМ авто-рандомом
  /// (вписанный юзером свой IP:port не трогаем). QUIC-параметры (скрытые без
  /// галки) сбрасываем к дефолтам, чтобы повторное включение стартовало чисто.
  void _resetObfuscationFields() {
    setState(() {
      if (_endpointAutoFilled) {
        _endpoint.text = WarpAccount.defaultEndpoint;
        _endpointAutoFilled = false;
      }
      _template = JunkTemplate.quic;
      _sni.clear();
      _quicLevel = 0;
      _jc.text = '4';
      _jmin.text = '40';
      _jmax.text = '70';
    });
  }

  @override
  void dispose() {
    _license.dispose();
    _endpoint.dispose();
    _sni.dispose();
    _jc.dispose();
    _jmin.dispose();
    _jmax.dispose();
    super.dispose();
  }

  /// Sentinel-метка «рандом» в SNI-combobox (= пустой SNI → рандом из пула).
  static const _sniRandomLabel = 'Random (default)';

  /// Собирает [QuicParams] из Advanced-полей (с дефолтами при пустых/битых).
  /// «Random (default)»-метку трактуем как пустой SNI (DropdownMenu пишет
  /// label выбранного пункта в контроллер).
  QuicParams _buildQuicParams() {
    final sni = _sni.text.trim();
    return QuicParams(
      sni: sni == _sniRandomLabel ? '' : sni,
      level: _quicLevel,
      jc: int.tryParse(_jc.text.trim()) ?? 4,
      jmin: int.tryParse(_jmin.text.trim()) ?? 40,
      jmax: int.tryParse(_jmax.text.trim()) ?? 70,
    );
  }

  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final endpoint = _endpoint.text.trim().isEmpty
          ? WarpAccount.defaultEndpoint
          : _endpoint.text.trim();
      final license = _license.text.trim();

      final account = await widget.subController.addWarp(
        licenseKey: license.isEmpty ? null : license,
        endpoint: endpoint,
        forceNew: _forceNew,
        obfuscate: _obfuscate,
        template: _template,
        quicParams: _buildQuicParams(),
      );

      if (!mounted) return;
      final err = widget.subController.lastError;
      if (account == null || err.isNotEmpty) {
        _showSnack(err.isNotEmpty ? err : 'WARP registration failed');
        return;
      }
      setState(() => _result = account);
      await widget.onAdded();
      if (!mounted) return;
      _showSnack(account.warpPlus ? 'Added WARP+ node' : 'Added WARP node');
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Get WARP'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // §025 — официальный двухтональный логотип-облако Cloudflare
            // (Wikimedia Commons, ~2.8:1). Ширина = доля экрана (≈40%,
            // зажата 120..200 px), чтобы масштабировалось под любой телефон;
            // BoxFit.contain сохраняет пропорции и не обрезает макушку.
            Builder(builder: (context) {
              final w = MediaQuery.of(context).size.width;
              final logoW = (w * 0.40).clamp(120.0, 200.0);
              return Image.asset('assets/icons/cloudflare.png',
                  width: logoW, fit: BoxFit.contain);
            }),
            const SizedBox(height: 16),
            Text(
              'Cloudflare WARP',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Registers a free WireGuard tunnel on Cloudflare. The private key '
              'is generated on this device and never leaves it.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            // §126 — значимая опция (не прячем в Advanced): обфускация под DPI.
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  CheckboxListTile(
                    value: _obfuscate,
                    onChanged: _busy
                        ? null
                        : (v) {
                            final on = v ?? false;
                            setState(() => _obfuscate = on);
                            if (on) {
                              // Включение → сразу рандомный endpoint в поле
                              // (если там дефолт/пусто/прошлый авто-рандом, но
                              // НЕ вписанный юзером вручную).
                              if (_endpointReplaceable) _fillRandomEndpoint();
                            } else {
                              // Выключение → всё в стандарт (без галки обфускация
                              // не применяется, поля не должны вводить в
                              // заблуждение).
                              _resetObfuscationFields();
                            }
                          },
                    title: const Text('Add Amnezia obfuscation'),
                    subtitle: const Text(
                        'Masks WireGuard from DPI by adding junk traffic. '
                        'Enable if WARP is blocked.'),
                  ),
                  if (_obfuscate) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          _label('Junk template'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: DropdownButtonFormField<JunkTemplate>(
                              initialValue: _template,
                              isDense: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding:
                                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: JunkTemplate.quic,
                                  child: Text('QUIC (default)'),
                                ),
                                DropdownMenuItem(
                                  value: JunkTemplate.sip,
                                  child: Text('SIP'),
                                ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _template = v ?? JunkTemplate.quic),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            ExpansionPanelList.radio(
              elevation: 0,
              expandedHeaderPadding: EdgeInsets.zero,
              children: [
                ExpansionPanelRadio(
                  value: 'advanced',
                  canTapOnHeader: true,
                  headerBuilder: (_, _) =>
                      const ListTile(title: Text('Advanced')),
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('WARP+ license key (optional)'),
                        TextField(
                          controller: _license,
                          enabled: !_busy,
                          decoration: _input('Leave empty for free WARP'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'WARP+ adds Argo Smart Routing (lower latency). '
                          'Privacy is the same as free. Leave empty for free WARP.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 12),
                        _label('Endpoint'),
                        TextField(
                          controller: _endpoint,
                          enabled: !_busy,
                          // Ручная правка → больше не считаем поле авто-рандомом.
                          onChanged: (_) {
                            if (_endpointAutoFilled) {
                              setState(() => _endpointAutoFilled = false);
                            }
                          },
                          decoration: _input(WarpAccount.defaultEndpoint).copyWith(
                            // §136 — кнопка перегенерации рандомного endpoint
                            // (видна при обфускации).
                            suffixIcon: _obfuscate
                                ? IconButton(
                                    icon: const Icon(Icons.casino_outlined),
                                    tooltip: 'Pick another random IP:port',
                                    onPressed:
                                        _busy ? null : _fillRandomEndpoint,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'host:port of the Cloudflare peer. With obfuscation a '
                          'random working IP:port is filled in — tap the dice to '
                          'reroll, or type your own to pin a specific one.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        // §136 — QUIC-параметры (только при QUIC-обфускации).
                        if (_obfuscate && _template == JunkTemplate.quic) ...[
                          const SizedBox(height: 16),
                          _label('QUIC SNI (masquerade domain)'),
                          // combo-box: пункты из sni_pool + «Random», и можно
                          // вписать свой домен (editable). Пустой = рандом из пула.
                          LayoutBuilder(
                            builder: (ctx, c) => DropdownMenu<String>(
                              controller: _sni,
                              enabled: !_busy,
                              width: c.maxWidth,
                              hintText: _sniRandomLabel,
                              requestFocusOnTap: true,
                              menuHeight: 280,
                              dropdownMenuEntries: [
                                const DropdownMenuEntry(
                                    value: '', label: _sniRandomLabel),
                                for (final s in _sniPool)
                                  DropdownMenuEntry(value: s, label: s),
                              ],
                              onSelected: (v) {
                                // «Random» → очищаем поле (пусто = рандом).
                                if (v == '') _sni.clear();
                              },
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Domain the junk QUIC packet pretends to reach. '
                            'Pick one, type your own, or leave it on Random.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              _label('QUIC level'),
                              const SizedBox(width: 16),
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  initialValue: _quicLevel,
                                  isDense: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                  ),
                                  items: [
                                    for (var i = 0; i <= 4; i++)
                                      DropdownMenuItem(
                                          value: i, child: Text('$i')),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) =>
                                          setState(() => _quicLevel = v ?? 0),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _numField(_jc, 'Jc'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _numField(_jmin, 'Jmin'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _numField(_jmax, 'Jmax'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _forceNew,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _forceNew = v ?? false),
                          title: const Text('Re-register (force new account)'),
                          subtitle: const Text(
                              'Ignore the cached account and register a fresh one.'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _register,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_busy ? 'Registering…' : 'Register'),
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              _StatusCard(account: _result!),
            ],
          ],
        ),
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

  /// §136 — компактное числовое поле для Jc/Jmin/Jmax.
  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.account});
  final WarpAccount account;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.warpPlus ? 'Registered: WARP+' : 'Registered: WARP',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('Account', account.accountId),
            _row('Device', account.deviceId),
            _row('Address', account.clientV4),
            _row('Endpoint', account.endpoint),
            if (account.awg != null) _row('Obfuscation', 'Amnezia 1.5'),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 80, child: Text(k)),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ),
      );
}
