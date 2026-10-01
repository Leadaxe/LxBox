import 'package:flutter/material.dart';

import '../../../models/node_warning.dart' show RegistryWarning;
import '../../../services/builder/if_engine.dart' show TemplateWarning;
import '../../../services/l10n/locale_controller.dart';
import '../../subscription_detail_screen/widgets/node_warnings_sheet.dart'
    show showNodeWarningsSheet;

/// §555 / задача 570 — поверхность `template_degraded` на Home: после
/// сборки с предупреждениями движка шаблона — короткий снек
/// «Template: N warnings» с кнопкой в шторку кодов (тексты реестра, тот же
/// [showNodeWarningsSheet], что у узла). Сохранение конфига не блокируется;
/// полные EN-строки по-прежнему в логе (первыми в отчёте сборки).
void showTemplateWarningsSnack(
    BuildContext context, List<TemplateWarning> items) {
  if (items.isEmpty) return;
  final warnings = [
    for (final w in items) RegistryWarning(code: w.code, params: w.params),
  ];
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    key: const ValueKey('template-warnings-snack'),
    content: Text(getLocalText.plural("Template: %d warnings", items.length)),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 6),
    action: SnackBarAction(
      label: getLocalText.s("Show"),
      onPressed: () {
        if (!context.mounted) return;
        showNodeWarningsSheet(context, warnings,
            sourceLabel: getLocalText.s("Template"));
      },
    ),
  ));
}
