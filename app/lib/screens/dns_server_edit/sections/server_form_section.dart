import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../edit_controller.dart';
import '../../../services/l10n/locale_controller.dart';

/// §117 задача 4b — структурная форма inline-DNS-сервера: режимы
/// **UDP / DoT / DoH** (sing-box `udp`/`tls`/`https`) + адрес/порт,
/// для DoH — path, для DoT/DoH — TLS SNI, для hostname-адреса —
/// Domain resolver (решение №4: чем резолвить имя самого DNS-сервера).
/// §312 — режим **Group** (kernel SPEC 033): члены + режим
/// выбора + TTL; транспортных полей у группы нет.
/// §411 — **DoQ** (`quic`, порт 853, как DoT) и **DoH3** (`h3`, порт 443
/// + path, как DoH): ядро их знает давно, форма не давала выбрать.
///
/// Поля пишут в канонический `body` контроллера — JSON-вкладка показывает
/// то же тело live (и наоборот: валидный JSON-edit обновляет форму).
/// `body.type` вне режимов формы (local, dhcp, …) не выражается —
/// показываем пометку «use JSON tab».
class ServerFormSection extends StatelessWidget {
  const ServerFormSection({super.key, required this.c});

  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mode = c.serverMode;

    if (mode == null) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.data_object, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                getLocalText.s(
                  "Custom server type \"%s\" — edit it on the JSON tab. The form supports UDP / DoT / DoH / DoQ / DoH3.",
                  c.rawServerType,
                ),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        // §312 — режимы в сегментах. На узких экранах сегменты не влезают —
        // дропдаун (решение юзера №1). §411 — сегментов стало шесть, порог
        // поднят: на телефоне (< 520dp) всегда дропдаун, сегменты — планшет.
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 520) {
              return DropdownButtonFormField<String>(
                key: ValueKey('dns-mode-$mode'),
                initialValue: mode,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Server type"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  // l10n-exempt: protocol name
                  const DropdownMenuItem(value: 'udp', child: Text('UDP')),
                  // l10n-exempt: protocol name
                  const DropdownMenuItem(value: 'tls', child: Text('DoT')),
                  // l10n-exempt: protocol name
                  const DropdownMenuItem(value: 'https', child: Text('DoH')),
                  // l10n-exempt: protocol name
                  const DropdownMenuItem(value: 'quic', child: Text('DoQ')),
                  // l10n-exempt: protocol name
                  const DropdownMenuItem(value: 'h3', child: Text('DoH3')),
                  DropdownMenuItem(
                    value: 'group',
                    child: Text(getLocalText.s("Group")),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) c.setServerMode(v);
                },
              );
            }
            return SegmentedButton<String>(
              segments: [
                // l10n-exempt: protocol name
                const ButtonSegment(value: 'udp', label: Text('UDP')),
                // l10n-exempt: protocol name
                const ButtonSegment(value: 'tls', label: Text('DoT')),
                // l10n-exempt: protocol name
                const ButtonSegment(value: 'https', label: Text('DoH')),
                // l10n-exempt: protocol name
                const ButtonSegment(value: 'quic', label: Text('DoQ')),
                // l10n-exempt: protocol name
                const ButtonSegment(value: 'h3', label: Text('DoH3')),
                ButtonSegment(
                  value: 'group',
                  label: Text(getLocalText.s("Group")),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => c.setServerMode(s.first),
            );
          },
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(switch (mode) {
            'tls' => getLocalText.s("DNS-over-TLS · port 853"),
            'https' => getLocalText.s("DNS-over-HTTPS · port 443"),
            'quic' => getLocalText.s("DNS-over-QUIC · port 853"),
            'h3' => getLocalText.s("DNS-over-HTTP/3 · port 443"),
            'group' => getLocalText.s(
              "Several servers behind one tag — survives a member failure",
            ),
            _ => getLocalText.s("Plain UDP · port 53 · fast, unencrypted"),
          }, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ),
        const SizedBox(height: 12),
        if (mode == 'group') ...[
          _GroupSection(c: c),
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: c.addressCtrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: getLocalText.s("Server address"),
                    hintText: kDnsPathModes.contains(mode)
                        ? getLocalText.s(
                            "192.168.1.1 / dns.example.com / https://… URL",
                          )
                        : getLocalText.s("192.168.1.1 / dns.example.com"),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: c.onAddressChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: c.portCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: getLocalText.s("Port"),
                    hintText: '${defaultDnsPort(mode)}',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: c.onPortChanged,
                ),
              ),
            ],
          ),
          if (kDnsPathModes.contains(mode)) ...[
            const SizedBox(height: 12),
            TextField(
              controller: c.pathCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("Path"),
                // l10n-exempt: URL path example
                hintText: '/dns-query',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: c.onPathChanged,
            ),
          ],
          if (mode != 'udp') ...[
            const SizedBox(height: 12),
            TextField(
              controller: c.sniCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("TLS server name (SNI) — optional"),
                hintText: getLocalText.s(
                  "dns.example.com — needed when address is an IP",
                ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: c.onSniChanged,
            ),
          ],
          if (c.isHostnameAddress) ...[
            const SizedBox(height: 12),
            _DomainResolverPicker(c: c),
          ],
        ],
      ],
    );
  }
}

/// §312 — секция формы DNS-группы (kernel SPEC 033): члены + режим + TTL.
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final members = c.groupMembers;
    final self = c.tagCtrl.text.trim();
    final options = [
      for (final o in c.dnsMemberOptions)
        if (o.tag != self) o,
    ];
    // Члены, которых нет среди известных опций (введены JSON-вкладкой /
    // сервер удалён) — показываем строкой, чтобы юзер мог снять.
    final unknownMembers = [
      for (final m in members)
        if (!options.any((o) => o.tag == m)) m,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          getLocalText.s("Members"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        if (options.isEmpty && unknownMembers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              getLocalText.s("No other DNS servers to add — create them first"),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        for (final o in options)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: members.contains(o.tag),
            onChanged: (v) => c.toggleGroupMember(o.tag, v == true),
            title: Text(
              o.tag,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            subtitle: o.enabled
                // l10n-exempt: wire type as-is
                ? Text(o.type, style: const TextStyle(fontSize: 11))
                : Text(
                    getLocalText.s("%s · disabled — will be skipped", o.type),
                    style: TextStyle(fontSize: 11, color: cs.error),
                  ),
          ),
        for (final m in unknownMembers)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: true,
            onChanged: (_) => c.toggleGroupMember(m, false),
            title: Text(
              m,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            subtitle: Text(
              getLocalText.s("unknown server — will be skipped"),
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('dns-group-mode-${c.groupMode}'),
          initialValue: c.groupMode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: getLocalText.s("Selection mode"),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem(
              value: 'stable',
              child: Text(
                getLocalText.s("Stable — stick to one until it fails"),
              ),
            ),
            DropdownMenuItem(
              value: 'fastest',
              child: Text(
                getLocalText.s("Fastest — race, then stick to the winner"),
              ),
            ),
            DropdownMenuItem(
              value: 'parallel',
              child: Text(getLocalText.s("Parallel — race every query")),
            ),
          ],
          onChanged: (v) {
            if (v != null) c.setGroupMode(v);
          },
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: c.errorTtlCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Error TTL"),
                  // l10n-exempt: duration example
                  hintText: '2m',
                  errorText: c.groupErrorTtlInvalid
                      ? getLocalText.s("Invalid duration (e.g. 2m, 90s)")
                      : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: c.onErrorTtlChanged,
              ),
            ),
            if (c.groupMode == 'fastest') ...[
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: c.winTtlCtrl,
                  decoration: InputDecoration(
                    labelText: getLocalText.s("Win TTL"),
                    // l10n-exempt: duration example
                    hintText: '5m',
                    errorText: c.groupWinTtlInvalid
                        ? getLocalText.s("Invalid duration (e.g. 2m, 90s)")
                        : null,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: c.onWinTtlChanged,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Доменный адрес → нужен DNS-сервер, который отрезолвит само имя
/// (chicken-egg; решение №4 — как `dom_resolver` у Safe DNS).
class _DomainResolverPicker extends StatelessWidget {
  const _DomainResolverPicker({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final current = c.domainResolver;
    final tags = c.dnsServerTags.contains(current) || current.isEmpty
        ? c.dnsServerTags
        : [current, ...c.dnsServerTags];
    return DropdownButtonFormField<String>(
      // domain_resolver может смениться программно (авто-дефолт при вводе
      // hostname) — key пересоздаёт FormField с новым initialValue.
      key: ValueKey('dns-domres-$current'),
      initialValue: tags.contains(current) ? current : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: getLocalText.s("Domain resolver"),
        helperText: getLocalText.s("Resolves the server hostname itself"),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: tags
          .map(
            (t) => DropdownMenuItem(
              value: t,
              child: Text(
                t,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) c.setDomainResolver(v);
      },
    );
  }
}
