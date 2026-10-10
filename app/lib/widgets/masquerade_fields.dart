/// §623 — маскировка WireGuard/AmneziaWG (`ip`/`id`/`ib`) в интерфейсе.
///
/// Общее у визарда WARP и экрана узла — подсказки по протоколу, проверка
/// домена и списки значений. Вид разный (ревизия 1 §623): у визарда форма
/// [MasqueradeFields] (узел создаётся одной кнопкой), у экрана узла — строки
/// [MasqueradeSection], как блок Detour: тап → выбор → запись сразу.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/wireguard/masquerade_source.dart';

/// Протоколы маскировки (`ip`).
const kMasqueradeProtocols = ['quic', 'dns', 'stun', 'sip'];

/// Профили клиента у `quic` (`ib`).
const kMasqueradeBrowsers = ['chrome', 'firefox', 'curl'];

/// Имя протокола; `''` — Off.
String masqueradeProtocolName(String v) => switch (v) {
  '' => getLocalText.s("Off"),
  'quic' => 'QUIC', // l10n-exempt: protocol name
  'dns' => 'DNS', // l10n-exempt: protocol name
  'stun' => 'STUN', // l10n-exempt: protocol name
  'sip' => 'SIP', // l10n-exempt: protocol name
  _ => v,
};

/// Имя профиля клиента; `''` — по умолчанию ядра.
String masqueradeBrowserName(String v) => switch (v) {
  '' => getLocalText.s("Default"),
  'chrome' => 'Chrome', // l10n-exempt: brand name
  'firefox' => 'Firefox', // l10n-exempt: brand name
  'curl' => 'curl', // l10n-exempt: brand name
  _ => v,
};

/// Подсказка по протоколу: что значит домен и обязателен ли он.
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

/// Поле домена маскировки (ревизия 2 §623): одна рамка с подписью, в ней
/// кубик (случайный домен из пула) и стрелка — меню со ВСЕМ пулом независимо
/// от текста; выбор пункта ставит домен в поле, свой домен вписывается
/// руками. Общее у диалога домена экрана узла и визарда WARP.
class MasqueradeDomainField extends StatelessWidget {
  const MasqueradeDomainField({
    super.key,
    required this.controller,
    this.pool = const [],
    this.onRandom,
    this.enabled = true,
    this.helperText,
    this.errorText,
  });

  final TextEditingController controller;
  final List<String> pool;

  /// Кубик; `null` или пустой пул — кубика нет.
  final VoidCallback? onRandom;
  final bool enabled;
  final String? helperText;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final hasPool = pool.isNotEmpty;
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: getLocalText.s("Masquerade domain"),
        helperText: helperText,
        helperMaxLines: 3,
        errorText: errorText,
        errorMaxLines: 2,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: hasPool
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onRandom != null)
                    IconButton(
                      key: const ValueKey('masquerade-domain-dice'),
                      icon: const Icon(Icons.casino_outlined),
                      tooltip: getLocalText.s("Pick another random domain"),
                      onPressed: enabled ? onRandom : null,
                    ),
                  MenuAnchor(
                    style: const MenuStyle(
                      maximumSize: WidgetStatePropertyAll(
                        Size(double.infinity, 280),
                      ),
                    ),
                    menuChildren: [
                      for (final d in pool)
                        MenuItemButton(
                          onPressed: () => controller.text = d,
                          child: Text(d),
                        ),
                    ],
                    builder: (ctx, menu, _) => IconButton(
                      key: const ValueKey('masquerade-domain-arrow'),
                      icon: const Icon(Icons.arrow_drop_down),
                      onPressed: enabled
                          ? () => menu.isOpen ? menu.close() : menu.open()
                          : null,
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

/// Форма маскировки визарда WARP: три поля с подписью в рамке. Состояние
/// держит визард: [ip], [ib], контроллер домена [domain].
class MasqueradeFields extends StatelessWidget {
  const MasqueradeFields({
    super.key,
    required this.ip,
    required this.ib,
    required this.domain,
    required this.onIpChanged,
    required this.onIbChanged,
    this.enabled = true,
    this.domainPool = const [],
    this.onRandomDomain,
    this.domainError,
  });

  final String ip;
  final String ib;
  final TextEditingController domain;
  final ValueChanged<String> onIpChanged;
  final ValueChanged<String> onIbChanged;
  final bool enabled;

  /// Подсказки поля домена (пул визарда, `ScanPool.wgSniPool`).
  final List<String> domainPool;

  /// Кубик: случайный домен из пула.
  final VoidCallback? onRandomDomain;

  final String? domainError;

  @override
  Widget build(BuildContext context) {
    final ipValue = kMasqueradeProtocols.contains(ip) ? ip : 'quic';
    final ibValue = kMasqueradeBrowsers.contains(ib) ? ib : 'chrome';
    final showDomain = ipValue != 'stun';
    InputDecoration decoration(String label, {String? helper}) =>
        InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          isDense: true,
          border: const OutlineInputBorder(),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('masquerade-ip-$ipValue'),
          initialValue: ipValue,
          isExpanded: true,
          decoration: decoration(
            getLocalText.s("Masquerade protocol"),
            helper: masqueradeProtocolHint(ipValue),
          ),
          items: [
            for (final v in kMasqueradeProtocols)
              DropdownMenuItem(
                value: v,
                child: Text(masqueradeProtocolName(v)),
              ),
          ],
          onChanged: enabled ? (v) => onIpChanged(v ?? 'quic') : null,
        ),
        if (showDomain) ...[
          const SizedBox(height: 12),
          MasqueradeDomainField(
            key: const ValueKey('masquerade-domain'),
            controller: domain,
            enabled: enabled,
            pool: domainPool,
            onRandom: onRandomDomain,
            errorText: domainError,
          ),
        ],
        if (ipValue == 'quic') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('masquerade-ib-$ibValue'),
            initialValue: ibValue,
            isExpanded: true,
            decoration: decoration(getLocalText.s("Browser")),
            items: [
              for (final v in kMasqueradeBrowsers)
                DropdownMenuItem(
                  value: v,
                  child: Text(masqueradeBrowserName(v)),
                ),
            ],
            onChanged: enabled ? (v) => onIbChanged(v ?? 'chrome') : null,
          ),
        ],
      ],
    );
  }
}

/// Строки секции Masquerade вкладки Settings узла WireGuard/AmneziaWG — как
/// блок Detour: `ListTile` со значением, тап → диалог выбора → [onChanged]
/// сразу пишет в источник. Значение — из модели узла: при отказе записи
/// строка остаётся прежней. Заголовок секции рисует экран.
class MasqueradeSection extends StatelessWidget {
  const MasqueradeSection({
    super.key,
    required this.value,
    required this.onChanged,
    this.unavailableReason,
    this.sipBlocked = false,
    this.sourceDirty = false,
    this.onSourceDirty,
    this.domainPool = const [],
    this.randomDomain,
  });

  /// Маскировка узла из модели.
  final Masquerade value;

  /// Запись новой маскировки в источник; сообщения показывает экран.
  final Future<void> Function(Masquerade) onChanged;

  /// Секция недоступна (явный `i1`, упакованная ссылка, чужой формат):
  /// строки выключены, причина — под заголовком.
  final String? unavailableReason;

  /// Узел задаёт `i2` явно: `sip` занимает `i2`, пункт выключен.
  final bool sipBlocked;

  /// На вкладке Source несохранённая правка: тап выбор не открывает,
  /// вызывается [onSourceDirty].
  final bool sourceDirty;
  final VoidCallback? onSourceDirty;

  final List<String> domainPool;

  /// Случайный домен из пула (`''` — пул пуст).
  final String Function()? randomDomain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final enabled = unavailableReason == null;
    final ip = value.ip ?? '';
    final showDomain = ip == 'quic' || ip == 'dns' || ip == 'sip';

    void tap(Future<void> Function() open) {
      if (sourceDirty) {
        onSourceDirty?.call();
        return;
      }
      unawaited(open());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (unavailableReason != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              unavailableReason!,
              key: const ValueKey('masquerade-unavailable'),
              style: note,
            ),
          ),
        ListTile(
          key: const ValueKey('masquerade-protocol'),
          enabled: enabled,
          leading: const Icon(Icons.theater_comedy_outlined, size: 20),
          title: Text(getLocalText.s("Masquerade protocol")),
          subtitle: Text(masqueradeProtocolName(ip)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => tap(() => _pickProtocol(context)),
        ),
        if (showDomain)
          ListTile(
            key: const ValueKey('masquerade-domain'),
            enabled: enabled,
            leading: const Icon(Icons.language, size: 20),
            title: Text(getLocalText.s("Masquerade domain")),
            subtitle: Text(value.id ?? getLocalText.s("Generated by the core")),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => tap(() => _pickDomain(context, value)),
          ),
        if (ip == 'quic')
          ListTile(
            key: const ValueKey('masquerade-browser'),
            enabled: enabled,
            leading: const Icon(Icons.web, size: 20),
            title: Text(getLocalText.s("Browser")),
            subtitle: Text(masqueradeBrowserName(value.ib ?? '')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => tap(() => _pickBrowser(context)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(masqueradeProtocolHint(ip), style: note),
        ),
      ],
    );
  }

  Future<void> _pickProtocol(BuildContext context) async {
    final current = value.ip ?? '';
    final picked = await _pickOne(
      context,
      title: getLocalText.s("Masquerade protocol"),
      current: current,
      options: ['', ...kMasqueradeProtocols],
      label: masqueradeProtocolName,
      disabledNote: (v) => v == 'sip' && sipBlocked
          ? getLocalText.s("Not available: the node sets I2 explicitly.")
          : null,
    );
    if (picked == null || picked == current || !context.mounted) return;
    var next = value.withProtocol(picked, randomDomain: randomDomain?.call());
    // Пул пуст, а протокол с доменом: домен вводится до записи.
    if (next.id == null && const {'quic', 'dns', 'sip'}.contains(next.ip)) {
      final domain = await _domainDialog(context, next);
      if (domain == null) return;
      next = Masquerade.fromForm(next.ip!, domain, next.ib ?? '');
    }
    await onChanged(next);
  }

  Future<void> _pickBrowser(BuildContext context) async {
    final current = value.ib ?? '';
    final picked = await _pickOne(
      context,
      title: getLocalText.s("Browser"),
      current: current,
      options: ['', ...kMasqueradeBrowsers],
      label: masqueradeBrowserName,
    );
    if (picked == null || picked == current) return;
    await onChanged(
      Masquerade.fromForm(value.ip ?? '', value.id ?? '', picked),
    );
  }

  Future<void> _pickDomain(BuildContext context, Masquerade m) async {
    final domain = await _domainDialog(context, m);
    if (domain == null || domain == (m.id ?? '')) return;
    await onChanged(Masquerade.fromForm(m.ip ?? '', domain, m.ib ?? ''));
  }

  /// Диалог-список с радио. `null` — отмена.
  Future<String?> _pickOne(
    BuildContext context, {
    required String title,
    required String current,
    required List<String> options,
    required String Function(String) label,
    String? Function(String)? disabledNote,
  }) => showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in options)
                RadioListTile<String>(
                  key: ValueKey('masquerade-option-$v'),
                  value: v,
                  enabled: disabledNote?.call(v) == null,
                  title: Text(label(v)),
                  subtitle: switch (disabledNote?.call(v)) {
                    final String n => Text(n),
                    null => null,
                  },
                ),
            ],
          ),
        ),
      ],
    ),
  );

  /// Диалог домена: поле, кубик, подсказки пула. `null` — отмена.
  Future<String?> _domainDialog(BuildContext context, Masquerade m) =>
      showDialog<String>(
        context: context,
        builder: (_) => _DomainDialog(
          ip: m.ip ?? '',
          initial: m.id ?? '',
          pool: domainPool,
          randomDomain: randomDomain,
        ),
      );
}

class _DomainDialog extends StatefulWidget {
  const _DomainDialog({
    required this.ip,
    required this.initial,
    required this.pool,
    this.randomDomain,
  });

  final String ip;
  final String initial;
  final List<String> pool;
  final String Function()? randomDomain;

  @override
  State<_DomainDialog> createState() => _DomainDialogState();
}

class _DomainDialogState extends State<_DomainDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onText);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onText);
    _ctrl.dispose();
    super.dispose();
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final error = masqueradeDomainError(widget.ip, _ctrl.text);
    final random = widget.randomDomain;
    return AlertDialog(
      title: Text(getLocalText.s("Masquerade domain")),
      content: SizedBox(
        width: double.maxFinite,
        child: MasqueradeDomainField(
          key: const ValueKey('masquerade-domain-input'),
          controller: _ctrl,
          pool: widget.pool,
          onRandom: random == null
              ? null
              : () {
                  final d = random();
                  if (d.isNotEmpty) _ctrl.text = d;
                },
          helperText: masqueradeProtocolHint(widget.ip),
          errorText: masqueradeDomainErrorText(error),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        FilledButton(
          key: const ValueKey('masquerade-domain-ok'),
          onPressed: error == null
              ? () => Navigator.pop(context, _ctrl.text.trim())
              : null,
          child: Text(getLocalText.s("OK")),
        ),
      ],
    );
  }
}
