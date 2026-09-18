import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/contract/contract_docs.dart';
import '../../../services/contract/registry.dart';
import '../../../services/contract/registry_warning.dart';
import '../../../services/contract/warning_codes.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../services/url_launcher.dart' as ul;
import '../../../widgets/app_bottom_sheet.dart';
import '../../../widgets/banner_palette.dart';

/// §460 W2b — карточка предупреждений узла.
///
/// Строка под узлом ([NodeWarningRow]) показывает первое предупреждение и
/// «+N more» — места на большее там нет. Здесь тот же список целиком, и к
/// каждой записи — то, чего строка не вмещает: почему так вышло и что с этим
/// делать. Оба текста лежат в реестре контракта (`cause_*`/`fix_*`, §467) и
/// показываются офлайн; наружу ведёт только «Learn more».
///
/// Текст самого предупреждения берётся из `message()` — того же, что в
/// строке: две формулировки одного события расходились бы при первой же
/// правке. Причина, способ исправления и ссылка появляются у предупреждений,
/// код которых реестр знает; у рукописного класса код тоже может совпасть с
/// реестровым — тогда блоки будут и у него.
Future<void> showNodeWarningsSheet(
  BuildContext context,
  List<NodeWarning> warnings,
) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => NodeWarningsSheet(warnings),
  );
}

/// Содержимое шторки. Отдельный публичный виджет — чтобы виджет-тесты могли
/// строить его без модального роутера.
class NodeWarningsSheet extends StatelessWidget {
  const NodeWarningsSheet(this.warnings, {super.key});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Порядок — как в строке под узлом: сначала то, что громче.
    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              getLocalText.s("Warnings"),
              style: theme.textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: sorted.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _WarningCard(sorted[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard(this.warning);

  final NodeWarning warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Значок и цвет — те же, что у строки под узлом: одно событие в двух
    // местах не должно выглядеть двумя разными (§471 — общая палитра).
    final (color, icon) = warningSeverityStyle(context, warning.severity);

    final code = warningCodeOf(warning);
    // Код есть у класса, а текстов может не быть: реестр не синхронизирован,
    // либо код в нём рукописный без описания. Ссылку даём только когда
    // страница про этот код действительно есть — то есть реестр его знает.
    final known = code != null && ContractRegistry.I.textFor(code) != null;
    final lang = registryLangForTag(LocaleController.I.effectiveTag);
    // Подстановки несёт только RegistryWarning: у рукописного класса свои
    // поля, и текст он собрал сам. Тексты реестра для его кода при этом
    // остаются осмысленными — они про код, а не про конкретное значение.
    final w = warning;
    final subst = w is RegistryWarning ? w : null;
    final cause = known
        ? registryCause(code, lang,
            path: subst?.path,
            value: subst?.value,
            params: subst?.params ?? const {})
        : null;
    final fix = known
        ? registryFix(code, lang,
            path: subst?.path,
            value: subst?.value,
            params: subst?.params ?? const {})
        : const <String>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  warning.message(),
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
                if (cause != null) ...[
                  const SizedBox(height: 10),
                  _Block(title: getLocalText.s("Why"), child: Text(cause, style: theme.textTheme.bodySmall)),
                ],
                if (fix.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _Block(
                    title: getLocalText.s("What to do"),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final step in fix)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // l10n-exempt: маркер списка, не текст
                                Text('•  ', style: theme.textTheme.bodySmall),
                                Expanded(
                                  child: Text(step,
                                      style: theme.textTheme.bodySmall),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (known) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      onPressed: () =>
                          ul.UrlLauncher.open(contractWarningDocUrl(code)),
                      label: Text(getLocalText.s("Learn more")),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}
