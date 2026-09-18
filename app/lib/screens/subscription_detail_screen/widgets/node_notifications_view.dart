import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/contract/contract_docs.dart';
import '../../../services/contract/registry.dart';
import '../../../services/contract/registry_warning.dart';
import '../../../services/contract/warning_codes.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../services/url_launcher.dart' as ul;
import '../../../widgets/banner_palette.dart';

/// §479 — уведомления узла: один компонент на два места (раздел
/// `Notifications` вкладки Settings экрана узла и нижняя шторка из списка
/// подписки). До §479 это были две разные поверхности: плоский список
/// карточек в шторке и строка-простыня наверху экрана узла — одно событие
/// выглядело по-разному в зависимости от того, откуда на него посмотрели.
///
/// Логика заимствована у лаунчера (решение владельца 19.09.2026): шапка со
/// счётчиками по уровням, подразделы Errors → Warnings → Info, запись —
/// короткий заголовок, который разворачивается в разбор. Перенесена логика,
/// а не пиксели: экран телефонный, тултипов нет, и на строку уведомления
/// приходится одна строка высоты, пока её не открыли.
class NodeNotificationsView extends StatelessWidget {
  const NodeNotificationsView(this.warnings, {super.key});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final byLevel = groupWarningsBySeverity(warnings);
    // Уровень без записей раздела не получает — и в счётчике не участвует.
    final present = byLevel.entries.where((e) => e.value.isNotEmpty).toList();
    if (present.isEmpty) return const SizedBox.shrink();

    // Подзаголовок нужен, только когда уровней несколько: над единственной
    // группой он повторял бы шапку со счётчиком.
    final single = present.length == 1;
    // Единственное уведомление разворачиваем сразу: лишний тап ради одной
    // записи на телефоне не окупается.
    final soleEntry = warnings.length == 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: _Counters(byLevel),
        ),
        for (final entry in present) ...[
          if (!single)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: _LevelHeader(entry.key),
            ),
          for (final w in entry.value)
            _NotificationTile(w, initiallyExpanded: soleEntry),
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Предупреждения по уровням, старшее первым. Порядок ключей — порядок
/// разделов; пустые уровни остаются в карте (счётчик их пропускает сам).
Map<WarningSeverity, List<NodeWarning>> groupWarningsBySeverity(
    List<NodeWarning> warnings) {
  return {
    for (final level in const [
      WarningSeverity.error,
      WarningSeverity.warning,
      WarningSeverity.info,
    ])
      level: warnings.where((w) => w.severity == level).toList(),
  };
}

/// `✖ 1 · ⚠ 2 · ⓘ 3` — нулевые уровни не показываются: «0 ошибок» читается
/// как ошибка, которую не смогли назвать.
class _Counters extends StatelessWidget {
  const _Counters(this.byLevel);

  final Map<WarningSeverity, List<NodeWarning>> byLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <Widget>[];
    for (final e in byLevel.entries) {
      if (e.value.isEmpty) continue;
      final (color, icon) = warningSeverityStyle(context, e.key);
      if (parts.isNotEmpty) {
        parts.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          // l10n-exempt: разделитель счётчиков, не текст
          child: Text('·', style: theme.textTheme.bodySmall),
        ));
      }
      parts.addAll([
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          '${e.value.length}', // l10n-exempt: число рядом со значком уровня
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: parts);
  }
}

/// Подзаголовок уровня — значок, цвет и имя уровня.
class _LevelHeader extends StatelessWidget {
  const _LevelHeader(this.severity);

  final WarningSeverity severity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = warningSeverityStyle(context, severity);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          severityTitle(severity),
          style: theme.textTheme.labelMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Имя уровня. `Info` — форма 1 словаря: корневой `Info` уже занят разделом
/// «Protocol and server details» экрана узла («Информация»), а здесь нужно
/// «К сведению» — то же английское слово в другом смысле (§285 collisions).
String severityTitle(WarningSeverity severity) => switch (severity) {
      WarningSeverity.error => getLocalText.s("Errors"),
      WarningSeverity.warning => getLocalText.s("Warnings"),
      WarningSeverity.info => getLocalText.s(1, "Info"),
    };

/// Одно уведомление: заголовок в одну строку и раскрывающийся разбор.
///
/// Заголовок — `message()`: у кода реестра это `title_<lang>` (короткая
/// строка про событие), у рукописного класса — его собственный текст. Он же
/// стоит в строке под узлом: две формулировки одного события расходились бы
/// при первой правке.
class _NotificationTile extends StatelessWidget {
  const _NotificationTile(this.warning, {required this.initiallyExpanded});

  final NodeWarning warning;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final path = subst?.path;
    final detail = known
        ? registryText(code, lang,
            path: path, value: subst?.value, params: subst?.params ?? const {})
        : '';
    final cause = known
        ? registryCause(code, lang,
            path: path, value: subst?.value, params: subst?.params ?? const {})
        : null;
    final fix = known
        ? registryFix(code, lang,
            path: path, value: subst?.value, params: subst?.params ?? const {})
        : const <String>[];

    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      dense: true,
      leading: Icon(icon, size: 18, color: color),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Text(
        warning.message(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(color: color),
      ),
      children: [
        if (path != null && path.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              path, // l10n-exempt: путь поля в теле узла, wire-имя
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        if (detail.isNotEmpty)
          _Block(
            title: getLocalText.s("What happened"),
            child: Text(detail, style: theme.textTheme.bodySmall),
          ),
        if (cause != null)
          _Block(
            title: getLocalText.s("Why it happens"),
            child: Text(cause, style: theme.textTheme.bodySmall),
          ),
        if (fix.isNotEmpty)
          _Block(
            title: getLocalText.s("What you can do"),
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
                          child:
                              Text(step, style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (known)
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
              label: Text(getLocalText.s("Details")),
            ),
          ),
      ],
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
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
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
          Align(alignment: Alignment.centerLeft, child: child),
        ],
      ),
    );
  }
}
