import 'package:flutter/material.dart';

import '../../services/l10n/l10n.dart';
import '../../services/traffic_profiler.dart';

void showWipeAllDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l.statsTraceClearAllTitle),
      content: Text(ctx.l.statsTraceClearAllBody),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l.commonCancel)),
        TextButton(
          onPressed: () {
            TrafficProfiler.I.clearAll();
            Navigator.pop(ctx);
          },
          child: Text(ctx.l.commonClear),
        ),
      ],
    ),
  );
}

void showHelpDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l.statsTraceHelpTitle),
      content: SingleChildScrollView(
        child: Text(
          ctx.l.statsTraceHelpBody,
          style: const TextStyle(fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l.commonClose)),
      ],
    ),
  );
}
