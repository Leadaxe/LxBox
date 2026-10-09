/// §623 — поля маскировки WireGuard/AmneziaWG (`ip`/`id`/`ib`).
///
/// Один виджет на визард WARP (Advanced) и секцию Masquerade экрана узла:
/// подсказки по протоколу и проверка домена не расходятся.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/wireguard/masquerade_source.dart';

/// Подсказка под выбором протокола: что значит домен и обязателен ли он.
String masqueradeProtocolHint(String ip) => switch (ip) {
  'quic' => getLocalText.s(
    "The domain goes into the SNI of the decoy QUIC ClientHello. Required.",
  ),
  'dns' => getLocalText.s(
    "The domain is the DNS query name, visible on the wire. Empty: the core makes up a name.",
  ),
  'sip' => getLocalText.s(
    "The domain is the SIP request host, visible on the wire. Empty: the core makes up a name.",
  ),
  'stun' => getLocalText.s("The STUN decoy carries no domain."),
  _ => getLocalText.s("No decoy packets before the handshake."),
};

/// Текст ошибки домена для поля.
String? masqueradeDomainErrorText(MasqueradeDomainError? e) => switch (e) {
  MasqueradeDomainError.required => getLocalText.s(
    "Domain is required for QUIC.",
  ),
  MasqueradeDomainError.invalid => getLocalText.s("Not a valid domain name."),
  null => null,
};

/// Три поля маскировки. Состояние держит владелец: [ip] (`''` = Off),
/// [ib] (`''` = по умолчанию ядра), контроллер домена [domain].
class MasqueradeFields extends StatelessWidget {
  const MasqueradeFields({
    super.key,
    required this.ip,
    required this.ib,
    required this.domain,
    required this.onIpChanged,
    required this.onIbChanged,
    this.enabled = true,
    this.allowOff = true,
    this.sipBlocked = false,
    this.domainPool = const [],
    this.onRandomDomain,
    this.domainError,
  });

  final String ip;
  final String ib;
  final TextEditingController domain;
  final ValueChanged<String> onIpChanged;
  final ValueChanged<String> onIbChanged;

  /// `false` — все поля только для просмотра.
  final bool enabled;

  /// Пункты `Off` у протокола и `Default` у браузера (у визарда WARP их нет:
  /// он всегда строит маскировку).
  final bool allowOff;

  /// Узел задаёт `i2` явно: `sip` занимает `i2`, пункт выключен.
  final bool sipBlocked;

  /// Подсказки поля домена (пул визарда, `ScanPool.wgSniPool`).
  final List<String> domainPool;

  /// Кубик: случайный домен из пула. `null` — кубика нет.
  final VoidCallback? onRandomDomain;

  /// Текст ошибки под полем домена.
  final String? domainError;

  static const _protocols = ['quic', 'dns', 'stun', 'sip'];
  static const _browsers = ['chrome', 'firefox', 'curl'];

  static String _protocolName(String v) => switch (v) {
    'quic' => 'QUIC', // l10n-exempt: protocol name
    'dns' => 'DNS', // l10n-exempt: protocol name
    'stun' => 'STUN', // l10n-exempt: protocol name
    _ => 'SIP', // l10n-exempt: protocol name
  };

  static String _browserName(String v) => switch (v) {
    'chrome' => 'Chrome', // l10n-exempt: brand name
    'firefox' => 'Firefox', // l10n-exempt: brand name
    _ => 'cURL', // l10n-exempt: brand name
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final protocols = [if (allowOff) '', ..._protocols];
    final browsers = [if (allowOff) '', ..._browsers];
    final ipValue = protocols.contains(ip) ? ip : protocols.first;
    final ibValue = browsers.contains(ib) ? ib : browsers.first;
    final showDomain =
        ipValue == 'quic' || ipValue == 'dns' || ipValue == 'sip';
    String protocolLabel(String v) =>
        v.isEmpty ? getLocalText.s("Off") : _protocolName(v);
    String browserLabel(String v) =>
        v.isEmpty ? getLocalText.s("Default") : _browserName(v);
    const decoration = InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          context,
          getLocalText.s("Masquerade protocol"),
          DropdownButtonFormField<String>(
            key: ValueKey('masquerade-ip-$ipValue'),
            initialValue: ipValue,
            isDense: true,
            isExpanded: true,
            decoration: decoration,
            selectedItemBuilder: (_) => [
              for (final v in protocols) Text(protocolLabel(v)),
            ],
            items: [
              for (final v in protocols)
                if (v == 'sip' && sipBlocked)
                  DropdownMenuItem(
                    value: v,
                    enabled: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          protocolLabel(v),
                          style: TextStyle(color: theme.disabledColor),
                        ),
                        Text(
                          getLocalText.s(
                            "Not available: the node sets I2 explicitly.",
                          ),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.disabledColor,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  DropdownMenuItem(value: v, child: Text(protocolLabel(v))),
            ],
            onChanged: enabled ? (v) => onIpChanged(v ?? '') : null,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          masqueradeProtocolHint(ipValue),
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        if (showDomain) ...[
          const SizedBox(height: 12),
          _label(context, getLocalText.s("Masquerade domain")),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, c) => DropdownMenu<String>(
                    key: const ValueKey('masquerade-domain'),
                    controller: domain,
                    enabled: enabled,
                    width: c.maxWidth,
                    requestFocusOnTap: true,
                    menuHeight: 280,
                    errorText: domainError,
                    dropdownMenuEntries: [
                      for (final s in domainPool)
                        DropdownMenuEntry(value: s, label: s),
                    ],
                  ),
                ),
              ),
              if (onRandomDomain != null)
                IconButton(
                  icon: const Icon(Icons.casino_outlined),
                  tooltip: getLocalText.s("Pick another random domain"),
                  onPressed: enabled ? onRandomDomain : null,
                ),
            ],
          ),
        ],
        if (ipValue == 'quic') ...[
          const SizedBox(height: 12),
          _row(
            context,
            getLocalText.s("Browser"),
            DropdownButtonFormField<String>(
              key: ValueKey('masquerade-ib-$ibValue'),
              initialValue: ibValue,
              isDense: true,
              isExpanded: true,
              decoration: decoration,
              items: [
                for (final v in browsers)
                  DropdownMenuItem(value: v, child: Text(browserLabel(v))),
              ],
              onChanged: enabled ? (v) => onIbChanged(v ?? '') : null,
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, String label, Widget field) => Row(
    children: [
      _label(context, label),
      const SizedBox(width: 16),
      Expanded(child: field),
    ],
  );

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// Секция Masquerade вкладки Settings узла WireGuard/AmneziaWG: поля, текст
/// недоступности, своя кнопка Save.
class MasqueradeSection extends StatefulWidget {
  const MasqueradeSection({
    super.key,
    required this.initial,
    required this.onSave,
    this.unavailableReason,
    this.readOnly = false,
    this.sipBlocked = false,
    this.sourceDirty = false,
    this.domainPool = const [],
    this.randomDomain,
  });

  /// Значения из модели узла.
  final Masquerade initial;

  /// Запись в источник; ошибки и сообщения показывает владелец.
  final Future<void> Function(Masquerade) onSave;

  /// Секция недоступна (явный `i1`, упакованная ссылка, чужой формат):
  /// текст причины, поля выключены, Save нет.
  final String? unavailableReason;

  /// Только просмотр (узел подписки): поля выключены, Save нет.
  final bool readOnly;

  final bool sipBlocked;

  /// На вкладке Source несохранённая правка: Save выключен.
  final bool sourceDirty;

  final List<String> domainPool;

  /// Случайный домен из пула; `null` или пустая строка — кубик ничего не
  /// меняет.
  final String Function()? randomDomain;

  @override
  State<MasqueradeSection> createState() => _MasqueradeSectionState();
}

class _MasqueradeSectionState extends State<MasqueradeSection> {
  late String _ip;
  late String _ib;
  final _domain = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _reset();
    _domain.addListener(_onDomain);
  }

  @override
  void didUpdateWidget(MasqueradeSection old) {
    super.didUpdateWidget(old);
    if (old.initial != widget.initial) _reset();
  }

  @override
  void dispose() {
    _domain.removeListener(_onDomain);
    _domain.dispose();
    super.dispose();
  }

  void _reset() {
    _ip = widget.initial.ip ?? '';
    _ib = widget.initial.ib ?? '';
    _domain.text = widget.initial.id ?? '';
  }

  void _onDomain() {
    if (mounted) setState(() {});
  }

  Masquerade get _value => Masquerade.fromForm(_ip, _domain.text, _ib);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final reason = widget.unavailableReason;
    final editable = reason == null && !widget.readOnly;
    final error = masqueradeDomainError(_ip, _domain.text);
    final changed = _value != widget.initial;
    final canSave =
        editable && changed && error == null && !widget.sourceDirty && !_saving;
    final note = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            getLocalText.s("Masquerade"),
            style: theme.textTheme.titleSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            getLocalText.s("Decoy packets before the WireGuard handshake"),
            style: note,
          ),
          const Divider(),
          if (reason != null) ...[
            Text(
              reason,
              key: const ValueKey('masquerade-unavailable'),
              style: note,
            ),
            const SizedBox(height: 12),
          ],
          MasqueradeFields(
            ip: _ip,
            ib: _ib,
            domain: _domain,
            enabled: editable,
            sipBlocked: widget.sipBlocked,
            domainPool: widget.domainPool,
            onRandomDomain: widget.randomDomain == null
                ? null
                : () {
                    final d = widget.randomDomain!();
                    if (d.isNotEmpty) _domain.text = d;
                  },
            domainError: editable && _ip != 'stun'
                ? masqueradeDomainErrorText(error)
                : null,
            onIpChanged: (v) => setState(() => _ip = v),
            onIbChanged: (v) => setState(() => _ib = v),
          ),
          if (editable) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('masquerade-save'),
                onPressed: canSave ? () => unawaited(_save()) : null,
                child: Text(getLocalText.s("Save")),
              ),
            ),
            if (widget.sourceDirty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  getLocalText.s("Source has unsaved changes."),
                  textAlign: TextAlign.end,
                  style: note,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_value);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
