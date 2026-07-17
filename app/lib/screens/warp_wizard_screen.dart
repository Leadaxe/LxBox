import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../services/l10n/l10n.dart';
import '../services/ui_helpers.dart';
import '../services/warp/masquerade_params.dart';
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

class _WarpWizardScreenState extends State<WarpWizardScreen> with SnackHelper {
  final _license = TextEditingController();
  final _endpoint =
      TextEditingController(text: WarpAccount.defaultEndpoint);

  // §136/§143 — masquerade-параметры (Advanced). Пустой SNI(=id) → рандом из пула.
  final _sni = TextEditingController(); // id (домен маскировки)
  List<String> _sniPool = const []; // подсказки для DropdownMenu (WG §136)
  List<String> _masqueSniPool = const []; // §130 — SNI-пул для MASQUE-комбобокса
  // §143 — ip (протокол маскировки): quic/dns/stun/sip; ib (браузер) при quic.
  String _masqIp = 'quic';
  String _masqIb = 'chrome';
  final _jc = TextEditingController(text: '4');
  final _jmin = TextEditingController(text: '40');
  final _jmax = TextEditingController(text: '70');

  bool _forceNew = false;
  bool _busy = false;
  WarpAccount? _result;

  // §130 — транспорт WARP: 'wireguard' (дефолт) | 'masque'. MASQUE использует
  // ECDSA-регистрацию и Outbound type:masque (другой пул выходных нод).
  String _transport = 'wireguard';
  String _masqueNetwork = 'h3'; // h3 (QUIC) | h2 (HTTP/2)
  final _masqueSni = TextEditingController(); // опц. SNI override
  // §130 — тюнинг ресурсов: idle-suspend (минуты) и QUIC keepalive (секунды).
  // Пусто → дефолт ядра (5m / 30s). Плейсхолдеры показывают дефолт.
  final _masqueIdle = TextEditingController(); // минуты
  final _masqueKeepAlive = TextEditingController(); // секунды

  bool get _isMasque => _transport == 'masque';

  // §126/§136 — AmneziaWG обфускация (default off — обычный WARP).
  bool _obfuscate = false;
  // §142 — reserved (client_id): null = дефолт по галке (обфускация → off).
  // Юзер может переопределить чекбоксом в Advanced.
  bool? _includeReserved;

  WarpEndpointPicker? _picker; // §136 — для рандома endpoint/SNI
  bool _endpointAutoFilled = false; // §136 — endpoint в поле = наш авто-рандом

  @override
  void initState() {
    super.initState();
    // §136 — подтягиваем picker (SNI-пул для dropdown + рандом endpoint/SNI).
    WarpEndpointPicker.load().then((p) {
      if (!mounted) return;
      setState(() {
        _picker = p;
        _sniPool = p.sniPool;
        _masqueSniPool = p.masqueSniPool;
        // SNI при открытии — конкретный случайный домен (не «Random»); юзер
        // может выбрать другой/вписать свой или рерольнуть кубиком.
        if (_sni.text.trim().isEmpty) _sni.text = p.randomSni();
        // §130 — MASQUE SNI тоже предзаполняем рандомом из masque-пула (не
        // оставляем дефолт ядра): маскировка под конкретный легит-домен из
        // старта, юзер может сменить/очистить/рерольнуть.
        if (_masqueSni.text.trim().isEmpty) {
          _masqueSni.text = p.randomMasqueSni();
        }
      });
      // Если юзер успел включить обфускацию до загрузки picker — заполняем.
      if (_obfuscate && _endpointReplaceable) _fillRandomEndpoint();
    });
  }

  /// §136 — генерирует рандомный endpoint в поле (при включении обфускации).
  /// Помечает поле как авто-заполненное.
  void _fillRandomEndpoint() {
    final ep = _picker?.randomEndpoint();
    if (ep != null) {
      setState(() {
        _endpoint.text = ep;
        _endpointAutoFilled = true;
      });
    }
  }

  /// §136 — кубик 🎲 у SNI: подставляет случайный домен из пула в поле.
  void _fillRandomSni() {
    final sni = _picker?.randomSni();
    if (sni != null && sni.isNotEmpty) {
      setState(() => _sni.text = sni);
    }
  }

  /// §130 — кубик 🎲 у MASQUE SNI: случайный домен из MASQUE-пула в поле.
  void _fillRandomMasqueSni() {
    final sni = _picker?.randomMasqueSni();
    if (sni != null && sni.isNotEmpty) {
      setState(() => _masqueSni.text = sni);
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
      _includeReserved = null; // §142 — вернуть к дефолту по галке
      _sni.text = _picker?.randomSni() ?? ''; // свежий случайный домен
      _masqIp = 'quic'; // §143
      _masqIb = 'chrome';
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
    _masqueSni.dispose();
    _masqueIdle.dispose();
    _masqueKeepAlive.dispose();
    _jc.dispose();
    _jmin.dispose();
    _jmax.dispose();
    super.dispose();
  }

  /// Собирает [QuicParams] из Advanced-полей (с дефолтами при пустых/битых).
  /// SNI-поле обычно содержит конкретный домен; пустое → register подставит
  /// рандом из пула (fallback в контроллере).
  QuicParams _buildQuicParams() {
    return QuicParams(
      sni: _sni.text.trim(),
      ip: _masqIp,
      ib: _masqIb,
      jc: int.tryParse(_jc.text.trim()) ?? 4,
      jmin: int.tryParse(_jmin.text.trim()) ?? 40,
      jmax: int.tryParse(_jmax.text.trim()) ?? 70,
    );
  }

  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_isMasque) {
        await _registerMasque();
        return;
      }
      final endpoint = _endpoint.text.trim().isEmpty
          ? WarpAccount.defaultEndpoint
          : _endpoint.text.trim();
      final license = _license.text.trim();

      final account = await widget.subController.addWarp(
        licenseKey: license.isEmpty ? null : license,
        endpoint: endpoint,
        forceNew: _forceNew,
        obfuscate: _obfuscate,
        quicParams: _buildQuicParams(),
        includeReserved: _includeReserved,
      );

      if (!mounted) return;
      final err = widget.subController.lastError;
      if (account == null || err != null) {
        showSnack(err != null
            ? err.render(context.l)
            : context.l.warpRegistrationFailed);
        return;
      }
      setState(() => _result = account);
      await widget.onAdded();
      if (!mounted) return;
      showSnack(account.warpPlus
          ? context.l.warpAddedPlusNodeSnack
          : context.l.warpAddedNodeSnack);
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §130 — регистрация MASQUE-транспорта (ECDSA + enroll).
  Future<void> _registerMasque() async {
    final sni = _masqueSni.text.trim();
    final account = await widget.subController.addMasque(
      network: _masqueNetwork,
      sni: sni.isEmpty ? null : sni,
      idleTimeout: _durationOrNull(_masqueIdle.text, 'm'),
      keepAlive: _durationOrNull(_masqueKeepAlive.text, 's'),
      forceNew: _forceNew,
    );
    if (!mounted) return;
    final err = widget.subController.lastError;
    if (account == null || err != null) {
      showSnack(err != null
          ? err.render(context.l)
          : context.l.warpMasqueRegistrationFailed);
      return;
    }
    await widget.onAdded();
    if (!mounted) return;
    showSnack(context.l.warpAddedMasqueNode);
    Navigator.of(context).pop();
  }

  /// §130 — число из поля + единица → Go-duration (`"5m"`, `"30s"`). Пусто/ноль
  /// → null (ядро возьмёт свой дефолт). Только положительные целые.
  String? _durationOrNull(String raw, String unit) {
    final n = int.tryParse(raw.trim());
    if (n == null || n <= 0) return null;
    return '$n$unit';
  }

  // §219 — _showSnack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l.warpTitle),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(context.l.commonCancel),
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
              // l10n-exempt: brand name heading
              'Cloudflare WARP',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              context.l.warpIntro,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            // §130 — выбор транспорта WARP. WireGuard (дефолт) или MASQUE
            // (CONNECT-IP over HTTP/3/2 — другой пул выходных нод, иностранные IP).
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'wireguard',
                    // l10n-exempt: protocol name
                    label: Text('WireGuard'),
                    icon: Icon(Icons.vpn_key_outlined)),
                ButtonSegment(
                    value: 'masque',
                    // l10n-exempt: protocol name
                    label: Text('MASQUE'),
                    icon: Icon(Icons.hub_outlined)),
              ],
              selected: {_transport},
              onSelectionChanged: _busy
                  ? null
                  : (sel) => setState(() => _transport = sel.first),
            ),
            const SizedBox(height: 16),
            // §130 — MASQUE: транспорт h3/h2 + опц. SNI. Обфускация и WG-Advanced
            // не применяются (MASQUE сам маскируется под HTTPS/QUIC).
            if (_isMasque) ...[
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.l.warpMasqueIntro,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _label('Transport'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _masqueNetwork,
                              isDense: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: 'h3',
                                    // l10n-exempt: protocol name
                                    child: Text('HTTP/3 (QUIC)')),
                                DropdownMenuItem(
                                    value: 'h2',
                                    // l10n-exempt: protocol name
                                    child: Text('HTTP/2 (TCP)')),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _masqueNetwork = v ?? 'h3'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _masqueNetwork == 'h2'
                            ? context.l.warpMasqueH2Note
                            : context.l.warpMasqueH3Note,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      _label('SNI (optional)'),
                      // combo-box: пункты из sni_pool + свободный ввод. Пусто →
                      // дефолт ядра (consumer-masque.cloudflareclient.com).
                      // Кубик подставляет случайный домен из пула.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (ctx, c) => DropdownMenu<String>(
                                controller: _masqueSni,
                                enabled: !_busy,
                                width: c.maxWidth,
                                requestFocusOnTap: true,
                                menuHeight: 280,
                                hintText: context.l.warpMasqueSniHint,
                                dropdownMenuEntries: [
                                  for (final s in _masqueSniPool)
                                    DropdownMenuEntry(value: s, label: s),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.casino_outlined),
                            tooltip: context.l.warpRandomDomainTooltip,
                            onPressed: _busy ? null : _fillRandomMasqueSni,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _masqueIdle,
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: _input('5').copyWith(
                                labelText: context.l.warpIdleTimeoutLabel,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _masqueKeepAlive,
                              // keep-alive осмыслен только для h3 (QUIC).
                              enabled: !_busy && _masqueNetwork == 'h3',
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: _input('30').copyWith(
                                labelText: context.l.warpKeepAliveLabel,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        context.l.warpMasqueTimersHelp,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _forceNew,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _forceNew = v ?? false),
                        title: Text(context.l.warpForceNewTitle),
                        subtitle: Text(context.l.warpForceNewSubtitle),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // §126 — значимая опция (не прячем в Advanced): обфускация под DPI.
            if (!_isMasque)
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
                    title: Text(context.l.warpObfuscateTitle),
                    subtitle: Text(context.l.warpObfuscateSubtitle),
                  ),
                  // §143 — masquerade под выбранный протокол (id/ip/ib, ядро
                  // 009 генерит i1). Протокол/домен/браузер — в Advanced.
                  if (_obfuscate)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        context.l.warpObfuscateHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            // §130 — WG-Advanced (license/endpoint/masquerade) только для
            // WireGuard-транспорта; MASQUE имеет свой блок выше.
            if (!_isMasque) ...[
            const SizedBox(height: 16),
            ExpansionPanelList.radio(
              elevation: 0,
              expandedHeaderPadding: EdgeInsets.zero,
              children: [
                ExpansionPanelRadio(
                  value: 'advanced',
                  canTapOnHeader: true,
                  headerBuilder: (_, _) =>
                      ListTile(title: Text(context.l.commonAdvanced)),
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
                          context.l.warpPlusHelp,
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
                            // §136 — кубик: реролл рандомного endpoint (только
                            // его). Видна при обфускации.
                            suffixIcon: _obfuscate
                                ? IconButton(
                                    icon: const Icon(Icons.casino_outlined),
                                    tooltip: context.l.warpRandomEndpointTooltip,
                                    onPressed:
                                        _busy ? null : _fillRandomEndpoint,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.l.warpEndpointHelp,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        // §142 — reserved (client_id) опция. Дефолт по галке:
                        // обфускация → off (привязка к устройству режется).
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _includeReserved ?? !_obfuscate,
                          onChanged: _busy
                              ? null
                              : (v) =>
                                  setState(() => _includeReserved = v),
                          title: Text(context.l.warpReservedTitle),
                          subtitle: Text(context.l.warpReservedSubtitle),
                        ),
                        // §143 — masquerade id/ip/ib (ядро 009 генерит i1).
                        if (_obfuscate) ...[
                          const SizedBox(height: 16),
                          // ip — протокол маскировки.
                          Row(
                            children: [
                              _label('Masquerade protocol'),
                              const SizedBox(width: 16),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _masqIp,
                                  isDense: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'quic', child: Text('QUIC')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'dns', child: Text('DNS')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'stun', child: Text('STUN')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'sip', child: Text('SIP')),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(
                                          () => _masqIp = v ?? 'quic'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _masqIp == 'dns' || _masqIp == 'sip'
                                // Имена полей протокола (wire-термины) —
                                // подставляются как payload, не переводятся.
                                ? context.l.warpDecoyDomainVisible(
                                    _masqIp == 'dns' ? 'DNS QNAME' : 'SIP host')
                                : context.l.warpDecoyNoHostname,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          _label('Masquerade domain (id)'),
                          // combo-box (пункты из sni_pool + свободный ввод) +
                          // свой кубик: реролл случайного домена из пула.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (ctx, c) => DropdownMenu<String>(
                                    controller: _sni,
                                    enabled: !_busy,
                                    width: c.maxWidth,
                                    requestFocusOnTap: true,
                                    menuHeight: 280,
                                    dropdownMenuEntries: [
                                      for (final s in _sniPool)
                                        DropdownMenuEntry(value: s, label: s),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.casino_outlined),
                                tooltip: context.l.warpRandomDomainTooltip,
                                onPressed: _busy ? null : _fillRandomSni,
                              ),
                            ],
                          ),
                          // ib — браузер (только при quic).
                          if (_masqIp == 'quic') ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                _label('Browser (ib)'),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    initialValue: _masqIb,
                                    isDense: true,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'chrome',
                                          // l10n-exempt: brand name
                                          child: Text('Chrome')),
                                      DropdownMenuItem(
                                          value: 'firefox',
                                          // l10n-exempt: brand name
                                          child: Text('Firefox')),
                                      DropdownMenuItem(
                                          value: 'curl',
                                          // l10n-exempt: brand name
                                          child: Text('cURL')),
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(
                                            () => _masqIb = v ?? 'chrome'),
                                  ),
                                ),
                              ],
                            ),
                          ],
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
                          title: Text(context.l.warpForceNewTitle),
                          subtitle: Text(context.l.warpForceNewSubtitle),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            ],
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
              label: Text(_busy
                  ? context.l.warpRegisteringButton
                  : context.l.warpRegisterButton),
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
            Text(
                account.warpPlus
                    ? context.l.warpRegisteredPlusTitle
                    : context.l.warpRegisteredTitle,
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
