import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../edit_controller.dart';

/// §117 задача 4b — структурная форма inline-DNS-сервера: три режима
/// **UDP / DoT / DoH** (sing-box `udp`/`tls`/`https`) + адрес/порт,
/// для DoH — path, для DoT/DoH — TLS SNI, для hostname-адреса —
/// Domain resolver (решение №4: чем резолвить имя самого DNS-сервера).
///
/// Поля пишут в канонический `body` контроллера — JSON-вкладка показывает
/// то же тело live (и наоборот: валидный JSON-edit обновляет форму).
/// `body.type` вне трёх режимов (local, h3, …) формой не выражается —
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
                'Custom server type "${c.rawServerType}" — edit it on the '
                'JSON tab. The form supports UDP / DoT / DoH.',
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
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'udp', label: Text('UDP')),
            ButtonSegment(value: 'tls', label: Text('DoT')),
            ButtonSegment(value: 'https', label: Text('DoH')),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => c.setServerMode(s.first),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            switch (mode) {
              'tls' => 'DNS-over-TLS · port 853',
              'https' => 'DNS-over-HTTPS · port 443',
              _ => 'Plain UDP · port 53 · fast, unencrypted',
            },
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: c.addressCtrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Server address',
                  hintText: mode == 'https'
                      ? '9.9.9.9 / dns.example.com / https://… URL'
                      : '9.9.9.9 / dns.example.com',
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
                  labelText: 'Port',
                  hintText: '${defaultDnsPort(mode)}',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: c.onPortChanged,
              ),
            ),
          ],
        ),
        if (mode == 'https') ...[
          const SizedBox(height: 12),
          TextField(
            controller: c.pathCtrl,
            decoration: const InputDecoration(
              labelText: 'Path',
              hintText: '/dns-query',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: c.onPathChanged,
          ),
        ],
        if (mode != 'udp') ...[
          const SizedBox(height: 12),
          TextField(
            controller: c.sniCtrl,
            decoration: const InputDecoration(
              labelText: 'TLS server name (SNI) — optional',
              hintText: 'dns.example.com — needed when address is an IP',
              border: OutlineInputBorder(),
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
      decoration: const InputDecoration(
        labelText: 'Domain resolver',
        helperText: 'Resolves the server hostname itself',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: tags
          .map((t) => DropdownMenuItem(
                value: t,
                child: Text(t,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace')),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) c.setDomainResolver(v);
      },
    );
  }
}
