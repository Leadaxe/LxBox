/// §460 W1 — гард реестра на сборке конфига.
///
/// После `list.build(ctx)` и до пост-шагов каждая запись `outbounds[]`/
/// `endpoints[]`, пришедшая из источника узлов, проходит санитайзер реестра
/// ([RegistrySanitizer]). Это второй эшелон: рукописные per-protocol правила
/// парсеров остаются на месте (спека §2.5), а гард ловит то, чего они не
/// знают, — прежде всего тела JSON-источников, которые §455 переносит
/// дословно.
///
/// Почему именно на сборке, а не при разборе: гейты ядра (`min_core`,
/// `platform`) зависят от запущенного ядра, а `entry` узла от него не
/// зависит (24.1.6). Разбор-время ⚠ — волна W2.
library;

import '../../models/node_warning.dart';
import '../../models/singbox_entry.dart';
import '../contract/body_sanitizer.dart';
import '../contract/node_core_gate.dart';
import '../contract/registry.dart';
import 'core_chain_capability.dart' show kCoreBuildTags;

/// Результат прогона гарда по одной сборке.
final class RegistryGateReport {
  const RegistryGateReport(
    this.warnings,
    this.dropped, {
    this.warningsByEmittedTag = const {},
  });

  /// Строки для `emitWarnings` — как у прочих warnings сборки.
  final List<String> warnings;

  /// Записи, снятые целиком (`drop_node`): их надо убрать из конфига.
  final List<SingboxEntry> dropped;

  /// §505 — предупреждения сборки по финальному config-тегу записи.
  final Map<String, List<NodeWarning>> warningsByEmittedTag;
}

/// Прогнать санитайзер по записям узлов.
///
/// [entries] — только записи из источников: служебные outbound'ы шаблона
/// (`direct`/`block`/`dns`) и группы Направлений (`selector`/`urltest`) сюда
/// не приходят — они не тело узла (спека §2.4).
///
/// §473 — [verbatim] называет записи, чьё тело взято ДОСЛОВНО из
/// JSON-источника (§455, `verbatimBodyOf`): их вход — `singbox`, и правило
/// `max_when.except_sources` оставляет им значение, которое на прочих входах
/// заменило бы потолком. Без этой метки гард переписал бы `mtu: 1420`
/// AmneziaWG-узлу на сборке — то есть ровно то, чего §455 не позволяет:
/// узел sing-box-источника идёт в ядро дословно. Пустое множество —
/// поведение как прежде.
///
/// §56 (контракт 1.1.60) — до санитайзера каждую запись судит узловой гейт
/// ядра реестра ([nodeCoreRefusal]): протокол, поле или форма-диапазон с
/// `on_core_unsupported: drop_node`, чьё требование (`build_tag` — по
/// [coreBuildTags], `min_core` — по [coreVersion]) ядро не выполняет, снимает
/// запись целиком с кодом реестра. [coreBuildTags] `null` — теги неизвестны,
/// гейт по тегу не применяется.
///
/// Реестр не загружен — no-op: приложение работает как до §460.
RegistryGateReport applyRegistryGate(
  List<SingboxEntry> entries, {
  required String coreVersion,
  Set<String>? coreBuildTags = kCoreBuildTags,
  Set<SingboxEntry> verbatim = const {},
}) {
  final warnings = <String>[];
  final dropped = <SingboxEntry>[];
  final warningsByEmittedTag = <String, List<NodeWarning>>{};

  // Д-1 (эмулятор 19.09.2026) — СТРАХОВКА ТИПА, до и помимо реестра.
  // Запись без строкового непустого `type` — не тело sing-box, и в
  // `outbounds[]`/`endpoints[]` ей места нет. Реестр её молча пропускал
  // (`type is! String → continue`), и такое тело уезжало в конфиг как есть:
  // ядро отвечает `unknown outbound type:` и отказывает ВСЕМУ конфигу, а
  // узел при этом не назван — автоснятие 478 выключить его не может, и без
  // связи остаётся всё. Дешевле потерять один узел, чем весь конфиг.
  //
  // Код объявленный: `field_missing` с `field: type` — «в записи нет поля,
  // хотя протокол его требует; узел отброшен, ядро такую запись отвергает и
  // не запустит весь конфиг». Ровно этот случай, своей строки не нужно.
  //
  // Стоит ДО гейта загрузки реестра: страховка обязана работать и без него —
  // текста у кода тогда нет, и строка остаётся самим кодом (`registryTitle`).
  for (final entry in entries) {
    final type = entry.map['type'];
    if (type is String && type.isNotEmpty) continue;
    dropped.add(entry);
    const w = RegistryWarning(
      code: 'field_missing',
      path: 'type',
      params: {'field': 'type'},
    );
    final line = '${entry.tag}: ${w.message()} [type]';
    if (!warnings.contains(line)) warnings.add(line);
  }

  if (!ContractRegistry.I.isLoaded) {
    return RegistryGateReport(
      warnings,
      dropped,
      warningsByEmittedTag: warningsByEmittedTag,
    );
  }

  final core = CoreInfo(version: coreVersion, tags: coreBuildTags);
  for (final entry in entries) {
    final type = entry.map['type'];
    if (type is! String || type.isEmpty) continue;
    final tag = entry.tag;

    // §56 — узловой гейт ядра: узел, который ядру не по силам, конфиг не
    // собирает вовсе (ядро отвергло бы его целиком), поэтому снимается до
    // санитайзера и его кодов.
    final refusal = nodeCoreRefusal(type, entry.map, core);
    if (refusal != null) {
      final w = RegistryWarning(
        code: refusal.code,
        path: refusal.path,
        params: {'reason': refusal.reason},
        ownerTag: tag,
      );
      final where = refusal.path == null ? '' : ' [${refusal.path}]';
      final line = '$tag: ${w.message()}$where';
      if (!warnings.contains(line)) warnings.add(line);
      warningsByEmittedTag.putIfAbsent(tag, () => []).add(w);
      dropped.add(entry);
      continue;
    }

    final res = RegistrySanitizer.sanitize(
      Map<String, dynamic>.from(entry.map),
      scheme: type,
      coreVersion: coreVersion,
      source:
          verbatim.contains(entry) ? BodySource.singbox : BodySource.other,
    );
    if (res.warnings.isEmpty && res.body == null) continue;

    for (final w in res.warnings) {
      // Текст реестра на языке UI + машинный хвост с путём и значением:
      // строка уходит и в отчёт пользователю, и в Debug API.
      final where = w.path == null
          ? ''
          : ' [${w.path}${w.value == null ? '' : '=${w.value}'}]';
      final line = '$tag: ${w.message()}$where';
      if (!warnings.contains(line)) warnings.add(line);
      warningsByEmittedTag.putIfAbsent(tag, () => []).add(w);
    }

    if (res.body == null) {
      dropped.add(entry);
      continue;
    }
    // Тело переписывается НА МЕСТЕ: те же map-объекты уже разошлись по
    // аккумуляторам сборки (пулы Направлений, ctx.outbounds), и подменить
    // ссылку значило бы оставить половину из них со старым телом.
    entry.map
      ..clear()
      ..addAll(res.body!);
  }

  return RegistryGateReport(
    warnings,
    dropped,
    warningsByEmittedTag: warningsByEmittedTag,
  );
}
