import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/dns/tailscale_endpoint_options.dart'
    show TailscaleEndpointOption;
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
/// §435 — режим **Tailscale** (NODE_SECTIONS.md §6): MagicDNS через узел
/// tailnet — `endpoint` выбором из узлов Tailscale + чекбокс
/// `accept_default_resolvers`; адреса и detour нет.
/// §699 — режим **Hosts**: записи «имя → адреса» строками + диалог; у группы
/// — блок Hosts (ключ `hosts`, ядро SPEC 143) под Members.
///
/// Поля пишут в канонический `body` контроллера — JSON-вкладка показывает
/// то же тело live (и наоборот: валидный JSON-edit обновляет форму).
/// `body.type` вне режимов формы (local, tcp, fakeip, dhcp, …) не выражается —
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
                  "Custom server type \"%s\" — edit it on the JSON tab. The form supports UDP / DoT / DoH / DoQ / DoH3 / Group / Tailscale / Hosts.",
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
        // §699 — восьмой сегмент (Hosts): порог 600dp, чтобы не сжимать подписи.
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 600) {
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
                  const DropdownMenuItem(
                    value: 'tailscale',
                    child: Text('Tailscale'), // l10n-exempt: protocol name
                  ),
                  DropdownMenuItem(
                    value: 'hosts',
                    child: Text(getLocalText.s("Hosts")),
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
                const ButtonSegment(
                  value: 'tailscale',
                  label: Text('Tailscale'), // l10n-exempt: protocol name
                ),
                ButtonSegment(
                  value: 'hosts',
                  label: Text(getLocalText.s("Hosts")),
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
            'tailscale' => getLocalText.s(
              "MagicDNS of the tailnet via a Tailscale node · no address",
            ),
            'hosts' => getLocalText.s(
              "Fixed addresses for chosen names, answered on the device",
            ),
            _ => getLocalText.s("Plain UDP · port 53 · fast, unencrypted"),
          }, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ),
        const SizedBox(height: 12),
        if (mode == 'group') ...[
          _GroupSection(c: c),
        ] else if (mode == 'tailscale') ...[
          _TailscaleSection(c: c),
        ] else if (mode == 'hosts') ...[
          _HostsSection(c: c),
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
        // §695 правило 2 — выключенную запись в состав не добавить.
        if (o.tag != self && (o.selectable || members.contains(o.tag))) o,
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
        _GroupHostsBlock(c: c),
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

/// §699 — блок Hosts формы группы (ядро SPEC 143): галки по серверам типа
/// `hosts` из списка, вид — как Members (§695 правило 2: выключенный не
/// предлагается, уже отмеченный показывается с пометкой). Ключ пишется в
/// порядке списка ([DnsServerEditController.toggleGroupHosts]).
class _GroupHostsBlock extends StatelessWidget {
  const _GroupHostsBlock({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hosts = c.groupHosts;
    final self = c.tagCtrl.text.trim();
    final options = [
      for (final o in c.dnsHostsOptions)
        if (o.tag != self && (o.selectable || hosts.contains(o.tag))) o,
    ];
    final unknown = [
      for (final h in hosts)
        if (!options.any((o) => o.tag == h)) h,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          getLocalText.s("Hosts"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        if (options.isEmpty && unknown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              getLocalText.s("No hosts servers in the list."),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          )
        else ...[
          for (final o in options)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: hosts.contains(o.tag),
              onChanged: (v) => c.toggleGroupHosts(o.tag, v == true),
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
          for (final h in unknown)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: true,
              onChanged: (_) => c.toggleGroupHosts(h, false),
              title: Text(
                h,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
              subtitle: Text(
                getLocalText.s("unknown server — will be skipped"),
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              getLocalText.s(
                "Names these servers know are answered first; other names go to the members.",
              ),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }
}

/// §699 — секция формы DNS-сервера `hosts`: записи `predefined` строками
/// (имя, под ним адреса через запятую, ✕ — снять), тап и «Add host» —
/// диалог [_HostsEntryDialog]. `path` формой не правится: есть в теле —
/// строка «Also reads».
class _HostsSection extends StatelessWidget {
  const _HostsSection({required this.c});
  final DnsServerEditController c;

  Future<void> _edit(BuildContext context, [DnsHostsEntry? entry]) async {
    final r = await showDialog<DnsHostsEntry>(
      context: context,
      builder: (_) => _HostsEntryDialog(c: c, entry: entry),
    );
    if (r == null) return;
    c.putHostsEntry(r.name, r.addresses, replacing: entry?.name);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final paths = c.hostsPaths;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          getLocalText.s("Hosts"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        for (final e in c.hostsEntries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: () => _edit(context, e),
            title: Text(
              e.name,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            subtitle: Text(
              e.addresses.join(', '),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            trailing: IconButton(
              tooltip: getLocalText.s("Remove"),
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => c.removeHostsEntry(e.name),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(getLocalText.s("Add host")),
            onPressed: () => _edit(context),
          ),
        ),
        if (paths.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              getLocalText.s("Also reads: %s", paths.join(', ')),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            getLocalText.s(
              "Answers only these names. Put it under Hosts of a DNS group so that other names go to the group's servers.",
            ),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// §699 — диалог записи `hosts`: Name и Addresses (по адресу в строке, как
/// поле Fixed IP §683). Проверки — [DnsServerEditController.hostsNameError]
/// и [DnsServerEditController.hostsAddressesError]; ошибка поля видна, как
/// только в нём что-то набрано, или после OK. Результат — имя в нижнем
/// регистре и адреса списком.
class _HostsEntryDialog extends StatefulWidget {
  const _HostsEntryDialog({required this.c, this.entry});
  final DnsServerEditController c;
  final DnsHostsEntry? entry;

  @override
  State<_HostsEntryDialog> createState() => _HostsEntryDialogState();
}

class _HostsEntryDialogState extends State<_HostsEntryDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.entry?.name ?? '');
  late final TextEditingController _addresses =
      TextEditingController(text: widget.entry?.addresses.join('\n') ?? '');
  bool _submitted = false;

  @override
  void dispose() {
    _name.dispose();
    _addresses.dispose();
    super.dispose();
  }

  String? get _nameError =>
      widget.c.hostsNameError(_name.text, editing: widget.entry?.name);
  String? get _addressesError =>
      DnsServerEditController.hostsAddressesError(_addresses.text);

  void _ok() {
    if (_nameError != null || _addressesError != null) {
      setState(() => _submitted = true);
      return;
    }
    Navigator.pop<DnsHostsEntry>(context, (
      name: DnsServerEditController.normalizeHostsName(_name.text),
      addresses: DnsServerEditController.hostsAddressLines(_addresses.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(getLocalText.s("Host")),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.entry == null,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: getLocalText.s("Name"),
                // l10n-exempt: host name example
                hintText: 'wg.home',
                errorText: _submitted || _name.text.isNotEmpty
                    ? _nameError
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addresses,
              minLines: 2,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: getLocalText.s("Addresses"),
                // l10n-exempt: IP address examples
                hintText: '203.0.113.10\n2001:db8::10',
                helperText: getLocalText.s("One address per line, IPv4 or IPv6."),
                errorText: _submitted || _addresses.text.isNotEmpty
                    ? _addressesError
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: _ok,
          child: Text(getLocalText.s("OK")),
        ),
      ],
    );
  }
}

/// §435 — секция формы DNS-сервера `tailscale` (NODE_SECTIONS.md §6, спека
/// §9.4): `endpoint` выбором из узлов Tailscale + чекбокс
/// `accept_default_resolvers`. Пикер — по образцу [_DomainResolverPicker]:
/// текущее значение вне списка (JSON-вкладка / узел удалён) — в начало,
/// чтобы дропдаун не падал на неизвестном value; нет узлов — подсказка.
class _TailscaleSection extends StatelessWidget {
  const _TailscaleSection({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = c.tailscaleEndpoint;
    final known = c.tailscaleEndpoints;
    final options = [
      if (current.isNotEmpty && !known.any((o) => o.tag == current))
        TailscaleEndpointOption(tag: current, enabled: true),
      ...known,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              getLocalText.s("No Tailscale nodes yet — add one on the Servers screen first"),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          )
        else
          DropdownButtonFormField<String>(
            // endpoint меняется и из JSON-вкладки — key пересоздаёт FormField
            // с новым initialValue.
            key: ValueKey('dns-ts-endpoint-$current'),
            initialValue: current.isEmpty ? null : current,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: getLocalText.s("Tailscale node"),
              helperText: getLocalText.s("Which node's tailnet answers the queries"),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final o in options)
                DropdownMenuItem(
                  value: o.tag,
                  child: Text(
                    o.enabled
                        ? o.tag
                        // Выключенный узел не эмитится — сервер на него
                        // санитайзер сборки выбросит (как члена группы).
                        : getLocalText.s("%s · disabled — will be skipped", o.tag),
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: o.enabled ? null : cs.error,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) c.setTailscaleEndpoint(v);
            },
          ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("Accept default resolvers")),
          subtitle: Text(
            getLocalText.s("Names outside the tailnet go to the default DNS servers; off — NXDOMAIN"),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          value: c.acceptDefaultResolvers,
          onChanged: c.setAcceptDefaultResolvers,
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
