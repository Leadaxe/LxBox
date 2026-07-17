import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';
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
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(context.l.routingDefaultTraffic),
      subtitle: Text(
        context.l.routingDefaultTrafficSub,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: SizedBox(
        width: 120,
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: options.any((o) => o.tag == routeFinal)
              ? routeFinal
              : options.first.tag,
          // §201 — danger-опция (block) красным, как reject в правилах.
          items: options
              .map((o) => DropdownMenuItem(
                  value: o.tag,
                  child: Text(o.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: o.danger ? cs.error : null,
                      ))))
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
