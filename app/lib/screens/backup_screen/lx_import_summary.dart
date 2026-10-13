import '../../services/l10n/locale_controller.dart';
import '../../services/lx_backup.dart';

/// §641 — сколько правил приёмника снял импорт: `count` предупреждения
/// [kWarnRulesReplaced] (detail `rules: <count>`, §640). 0 — замены не было:
/// файл без ключа `rules` или правил у приёмника не было.
int lxRulesReplacedCount(List<LxBackupWarning> warnings) {
  for (final w in warnings) {
    if (w.code != kWarnRulesReplaced) continue;
    final colon = w.detail.lastIndexOf(':');
    return int.tryParse(w.detail.substring(colon + 1).trim()) ?? 0;
  }
  return 0;
}

/// §641 — строки превью импорта LX Backup до применения.
///
/// [parsed] — `plan.file`: предупреждения плана в нём уже есть, и
/// [kWarnRulesReplaced] несёт число правил приёмника. Этот код — не отказ, а
/// будущая замена: в «Not applied as-is:» его нет, о нём говорит последняя
/// строка.
List<String> lxImportPreviewLines(LxBackupFile parsed) {
  final lines = <String>[
    getLocalText.s(
      "From %s %s",
      parsed.exportedByApp,
      parsed.exportedByVersion,
    ),
    // §393 B5 — Направления названы отдельной строкой: они не «часть
    // правил», а создаваемые сущности, и пользователь вправе увидеть,
    // сколько их заведётся, ДО применения.
    if (parsed.directions.isNotEmpty)
      getLocalText.s("Directions: %d", parsed.directions.length),
    // §393 C9 — цепочки хопов: тоже создаваемые сущности, и их число
    // пользователь вправе увидеть ДО применения.
    if (parsed.chains.isNotEmpty)
      getLocalText.s("Chains: %d", parsed.chains.length),
    getLocalText.s("Rules: %d", parsed.rules.length),
    getLocalText.s("Subscriptions: %d", parsed.subscriptions.length),
    // §401 — одиночные узлы и члены папок: до этого их разбирали и не
    // применяли, и пользователь не видел ни строки о том, что приехало.
    if (parsed.servers.isNotEmpty)
      getLocalText.s("Servers: %d", parsed.servers.length),
    getLocalText.s("Variables: %d", parsed.vars.length),
    // §393 B8/B9 — секции, которые теперь применяются: пользователь должен
    // увидеть их ДО применения, а не обнаружить постфактум чужой DNS-сервер
    // в списке.
    if (parsed.dns != null && !parsed.dns!.isEmpty)
      getLocalText.s(
        "DNS entries: %d",
        parsed.dns!.servers.length + parsed.dns!.rules.length,
      ),
    if (parsed.warp.isNotEmpty)
      getLocalText.s("WARP accounts: %d", parsed.warp.length),
  ];
  final notApplied = [
    for (final w in parsed.warnings)
      if (w.code != kWarnRulesReplaced) w,
  ];
  if (notApplied.isNotEmpty) {
    lines.add('');
    lines.add(getLocalText.s("Not applied as-is:"));
    for (final w in notApplied.take(8)) {
      lines.add('• ${w.detail}');
    }
    if (notApplied.length > 8) {
      lines.add('… +${notApplied.length - 8}');
    }
  }
  lines.add('');
  // §640 — файл без ключа `rules` правил приёмника не трогает.
  final replaced = lxRulesReplacedCount(parsed.warnings);
  lines.add(
    !parsed.rulesDeclared
        ? getLocalText.s("This file has no rules. The current rules stay.")
        : replaced > 0
        ? getLocalText.s("Importing replaces the current %d rule(s).", replaced)
        : getLocalText.s("Importing adds the file's rules."),
  );
  return lines;
}

/// §641 — итог импорта LX Backup одной строкой для снека.
///
/// [file] — `result.file`; [appliedDirections], [appliedSettings],
/// [appliedChains] — счётчики применения.
String lxImportSnackText(
  LxBackupFile file, {
  required int appliedDirections,
  required int appliedSettings,
  required int appliedChains,
}) {
  final rules = file.rules.length;
  final counts = appliedSettings;
  // §641 — замена правил приёмника не отказ: в «не применено» не идёт, а
  // названа хвостом сообщения.
  final replaced = lxRulesReplacedCount(file.warnings);
  final skipped = file.warnings
      .where((w) => w.code != kWarnRulesReplaced)
      .length;
  // Счётное существительное — только через plural: по-русски иначе
  // получится «Импортировано 2 правил».
  //
  // §393 B5 — созданные Направления названы отдельно: правила приехали
  // рабочими именно потому, что цели заведены, и молчать об этом значило
  // бы скрыть половину произошедшего с настройками.
  //
  // §393 B6 — то же и с остальными секциями: подписки, DNS, переменные и
  // регистрации WARP теперь реально применяются, и счётчик обязан их
  // показать — иначе «Импортировано 0 правил» после файла с тремя
  // подписками выглядит как отказ, хотя всё применилось.
  //
  // §641 — всё по нулям (в том числе файл без ключа `rules`, §640): не
  // «Imported 0 rules», а прямо — импортировать нечего.
  if (skipped == 0 &&
      rules == 0 &&
      appliedDirections == 0 &&
      counts == 0 &&
      appliedChains == 0 &&
      replaced == 0) {
    return getLocalText.s(
      "Nothing to import: the file has no rules, directions or settings.",
    );
  }
  final String head;
  if (skipped > 0) {
    head = getLocalText.s(
      "Imported %d rule(s), %d items not applied",
      rules,
      skipped,
    );
  } else if (appliedDirections > 0 && counts > 0) {
    head = getLocalText.s(
      "Imported %1\$d rules, %2\$d directions and %3\$d settings",
      rules,
      appliedDirections,
      counts,
    );
  } else if (appliedDirections > 0) {
    head = getLocalText.s(
      "Imported %1\$d rules and %2\$d directions",
      rules,
      appliedDirections,
    );
  } else if (counts > 0) {
    head = getLocalText.s(
      "Imported %1\$d rules and %2\$d settings",
      rules,
      counts,
    );
  } else {
    head = getLocalText.plural("Imported %d rules", rules);
  }
  final message = replaced > 0
      ? '$head, ${getLocalText.s("replaced %d rule(s)", replaced)}'
      : head;
  // §393 C9 — цепочки названы ОТДЕЛЬНОЙ клаузой, а не влиты в счётчик
  // настроек: это созданные сущности, как Направления, и «Импортировано
  // правил: 0, настроек: 2» после файла с двумя маршрутами скрыло бы
  // ровно то, что произошло. Клауза-суффикс, а не шестая ветка лестницы:
  // добавить цепочки измерением удвоило бы число строк каталога,
  // из которых половина не встречается никогда.
  return appliedChains > 0
      ? '$message; ${getLocalText.s("chains: %d", appliedChains)}'
      : message;
}
