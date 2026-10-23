import 'package:flutter/material.dart';

import '../edit_controller.dart';
import '../widgets/section_header.dart';
import '../../../models/custom_rule.dart';
import '../../../services/l10n/locale_controller.dart';

/// §683 — секция «DNS & Resolve»: всё про резолв доменов правила в одном
/// месте (бывшие секция DNS §117/§256 и окно «Action & Resolve» §247).
///
/// - Answer (радио): Default / Dedicated server / Fixed IP;
/// - Force IPv4 (§256), неактивна при Fixed IP;
/// - Resolve before routing + Strategy (§247 «Resolve first»);
/// - Advanced (свёрнут): поля бывшего окна.
///
/// Гейт портов/протоколов (headless rule_set их не выразит) гасит Answer и
/// Force IPv4; резолв от гейта не зависит.
class DnsResolveSection extends StatefulWidget {
  const DnsResolveSection({super.key, required this.controller});

  final CustomRuleEditController controller;

  @override
  State<DnsResolveSection> createState() => _DnsResolveSectionState();
}

class _DnsResolveSectionState extends State<DnsResolveSection> {
  /// Поле Fixed IP многострочное: «+», вставка нескольких строк или
  /// открытие правила с несколькими адресами.
  late bool _multiline;
  final _fixedFocus = FocusNode();

  static const _strategies = [
    'prefer_ipv4',
    'prefer_ipv6',
    'ipv4_only',
    'ipv6_only',
  ];

  CustomRuleEditController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _multiline = c.fixedIpCtrl.text.contains('\n');
  }

  @override
  void dispose() {
    _fixedFocus.dispose();
    super.dispose();
  }

  void _onFixedChanged(String text) {
    if (!_multiline && text.contains('\n')) {
      setState(() => _multiline = true);
    }
  }

  void _addLine() {
    final ctrl = c.fixedIpCtrl;
    final text = ctrl.text.trimRight();
    final next = text.isEmpty ? '' : '$text\n';
    ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() => _multiline = true);
    _fixedFocus.requestFocus();
  }

  Widget _hint(String text, ColorScheme cs, {double left = 12}) => Padding(
        padding: EdgeInsets.only(left: left, top: 2, bottom: 4),
        child: Text(text,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final dns = c.dns;
    final mode = c.dnsAnswerMode;
    final gate = c.dnsGateBlocked;
    final isSrs = c.kind == CustomRuleKind.srs;
    final serverTag = dns?.serverTag ?? '';
    // Выбранный tag мог исчезнуть из списка (сервер удалён) — показываем
    // его, build тихо не эмитит mirror (§117 решение №3).
    final tags = c.dnsServerTags.contains(serverTag) || serverTag.isEmpty
        ? c.dnsServerTags
        : [serverTag, ...c.dnsServerTags];
    final resolve = c.resolve;
    final only = c.resolveOnly;
    final resolveOn = resolve != null;
    final eligible = c.resolveEligible;
    const titleStyle = TextStyle(fontSize: 13);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: getLocalText.s("DNS & RESOLVE"),
          hint: getLocalText.s("How domains matched by this rule are resolved."),
        ),

        // ─── Answer ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(getLocalText.s("Answer"), style: t.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500)),
        ),
        RadioGroup<DnsAnswerMode>(
          groupValue: mode,
          onChanged: (v) {
            if (v != null && !gate) c.setDnsAnswerMode(v);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioListTile<DnsAnswerMode>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                enabled: !gate,
                value: DnsAnswerMode.defaultDns,
                title: Text(getLocalText.s("Default — queries go to DNS Final"),
                    style: titleStyle),
              ),
              Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: RadioListTile<DnsAnswerMode>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      enabled: !gate,
                      value: DnsAnswerMode.dedicated,
                      title: Text(getLocalText.s("Dedicated server"),
                          style: titleStyle),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('dns-server-$serverTag'),
                      initialValue:
                          tags.contains(serverTag) ? serverTag : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final tag in tags)
                          DropdownMenuItem(
                            value: tag,
                            child: Text(tag,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, fontFamily: 'monospace')),
                          ),
                      ],
                      onChanged: gate || mode != DnsAnswerMode.dedicated
                          ? null
                          : (v) {
                              if (v != null) c.setDnsServerTag(v);
                            },
                    ),
                  ),
                ],
              ),
              RadioListTile<DnsAnswerMode>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                enabled: !gate,
                value: DnsAnswerMode.fixedIp,
                title: Text(getLocalText.s("Fixed IP"), style: titleStyle),
              ),
            ],
          ),
        ),
        if (mode == DnsAnswerMode.fixedIp && !gate)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: c.fixedIpCtrl,
                    focusNode: _fixedFocus,
                    // maxLines > 1 и в однострочном виде: у maxLines == 1
                    // Flutter срезает переводы строк при вставке, а
                    // вставка нескольких строк должна раскрыть поле.
                    minLines: _multiline ? 2 : 1,
                    maxLines: 5,
                    keyboardType: _multiline
                        ? TextInputType.multiline
                        : TextInputType.text,
                    textInputAction: _multiline
                        ? TextInputAction.newline
                        : TextInputAction.done,
                    onChanged: _onFixedChanged,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: _multiline
                          ? getLocalText.s("IP addresses")
                          : getLocalText.s("IP address"),
                      hintText: '192.168.1.10',
                      helperText: _multiline
                          ? getLocalText
                              .s("One address per line, IPv4 or IPv6.")
                          : null,
                      errorText: c.fixedIpError,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: getLocalText.s("Add address"),
                  icon: const Icon(Icons.add),
                  onPressed: _addLine,
                ),
              ],
            ),
          ),
        if (gate)
          _hint(
              getLocalText.s(
                  "Unavailable with port/protocol filters — they are unknown at DNS-query time."),
              cs),
        if (isSrs &&
            !gate &&
            (mode == DnsAnswerMode.dedicated || mode == DnsAnswerMode.fixedIp))
          _hint(
              getLocalText.s(
                  "Works only if the rule-set contains domains — IP-only lists never match DNS queries."),
              cs),

        // ─── Force IPv4 (§256) ───────────────────────────────────────
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(getLocalText.s("Force IPv4 (drop AAAA)"),
              style: titleStyle),
          subtitle: Text(
            getLocalText.s(
                "Answer AAAA (IPv6) queries locally so matched traffic uses IPv4."),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          value: dns?.forceIpv4 ?? false,
          onChanged: gate || mode == DnsAnswerMode.fixedIp
              ? null
              : (v) => c.setForceIpv4(v ?? false),
        ),

        // ─── Resolve before routing (§247) ───────────────────────────
        if (eligible) ...[
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            visualDensity: VisualDensity.compact,
            title: Text(getLocalText.s("Resolve before routing"),
                style: titleStyle),
            subtitle: Text(
              only
                  ? getLocalText.s("Action is Resolve only")
                  : getLocalText.s(
                      "Look up the address before routing, so IP rules and the address family apply."),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: resolveOn,
            onChanged: only ? null : (v) => c.setResolveFirst(v ?? false),
          ),
          if (resolveOn)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
              child: DropdownButtonFormField<String>(
                initialValue: _strategies.contains(resolve.strategy)
                    ? resolve.strategy
                    : '',
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: getLocalText.s("Strategy"),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem(
                      value: '',
                      child: Text(getLocalText.s("(inherit DNS strategy)"))),
                  for (final s in _strategies)
                    // l10n-exempt: wire strategy value shown as-is
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) =>
                    c.updateResolve((r) => r.copyWith(strategy: v ?? '')),
              ),
            ),
          _advanced(context, resolve, cs),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  /// Advanced — поля бывшего окна «Action & Resolve». Активны, только когда
  /// резолв включён (Resolve before routing или Resolve only).
  Widget _advanced(BuildContext context, RuleResolve? resolve, ColorScheme cs) {
    final on = resolve != null;
    final serverTag = resolve?.serverTag ?? '';
    final tags = c.dnsServerTags;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      title: Text(getLocalText.s("Advanced"),
          style: const TextStyle(fontSize: 13)),
      children: [
        if (!on)
          Align(
            alignment: Alignment.centerLeft,
            child: _hint(
                getLocalText.s("Used when the rule resolves before routing."),
                cs,
                left: 0),
          ),
        DropdownButtonFormField<String>(
          initialValue: serverTag,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: getLocalText.s("DNS server"),
            isDense: true,
          ),
          items: [
            DropdownMenuItem(
                value: '', child: Text(getLocalText.s("(auto — route DNS)"))),
            for (final tag in tags)
              DropdownMenuItem(value: tag, child: Text(tag)),
            // Сохранённый tag, которого нет в текущем списке (сервер
            // удалили/переименовали) — показываем честно (§247).
            if (serverTag.isNotEmpty && !tags.contains(serverTag))
              DropdownMenuItem(
                  value: serverTag,
                  child: Text(getLocalText.s("%s (missing)", serverTag))),
          ],
          onChanged: on
              ? (v) => c.updateResolve((r) => r.copyWith(serverTag: v ?? ''))
              : null,
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          value: resolve?.disableCache ?? false,
          onChanged: on
              ? (v) =>
                  c.updateResolve((r) => r.copyWith(disableCache: v ?? false))
              : null,
          title: Text(getLocalText.s("Disable cache"),
              style: const TextStyle(fontSize: 13)),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          value: resolve?.disableOptimisticCache ?? false,
          onChanged: on
              ? (v) => c.updateResolve(
                  (r) => r.copyWith(disableOptimisticCache: v ?? false))
              : null,
          title: Text(getLocalText.s("Disable optimistic cache"),
              style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: c.resolveTtlCtrl,
          enabled: on,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: getLocalText.s("Rewrite TTL"),
            hintText: getLocalText.s("seconds, empty = keep"),
            isDense: true,
            errorText: on ? c.resolveTtlError : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: c.resolveTimeoutCtrl,
          enabled: on,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: getLocalText.s("Query timeout"),
            hintText: getLocalText.s("e.g. 5s, empty = default"),
            isDense: true,
            errorText: on ? c.resolveTimeoutError : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: c.resolveSubnetCtrl,
          enabled: on,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: getLocalText.s("Client subnet"),
            hintText: getLocalText.s("e.g. 1.2.3.0/24, empty = off"),
            isDense: true,
            errorText: on ? c.resolveSubnetError : null,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
