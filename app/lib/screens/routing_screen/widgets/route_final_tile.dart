import 'package:flutter/material.dart';

import '../routing_screen_helpers.dart';

/// ListTile с дропдауном "Default traffic" (route.final) на табе Channels.
class RouteFinalTile extends StatelessWidget {
  const RouteFinalTile({
    super.key,
    required this.options,
    required this.routeFinal,
    required this.onChanged,
  });

  final List<RoutingOutboundOption> options;
  final String routeFinal;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('Default traffic'),
      subtitle: const Text(
        'Fallback for unmatched traffic (route.final)',
        style: TextStyle(fontSize: 12),
      ),
      trailing: SizedBox(
        width: 120,
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: options.any((o) => o.tag == routeFinal)
              ? routeFinal
              : options.first.tag,
          items: options
              .map((o) => DropdownMenuItem(
                  value: o.tag,
                  child:
                      Text(o.label, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (val) {
            if (val == null) return;
            onChanged(val);
          },
        ),
      ),
    );
  }
}
