/// §480 W1 — МОСТ: движок секций на месте рукописного маппера.
///
/// Наружу движок отдаёт тот же `UriMapping`, что отдавали рукописные мапперы,
/// и остальной конвейер (санитайзер → `parseSingboxEntry`) не меняется вовсе.
/// Это граница волны: W1 доказывает грамматику на одной схеме, не трогая ни
/// одного слоя ниже.
///
/// Диспетчер выбирает движок ТОЛЬКО когда для схемы есть секция
/// ([MapperSections.has]); прочие схемы идут прежними мапперами до своих волн.
library;

import '../../../models/node_warning.dart';
import '../../contract/body_sanitizer.dart' show BodySource;
import '../mappers/uri_mapper.dart';
import 'interpreter.dart';
import 'section_loader.dart';

/// Разобрать ссылку движком по секции вида `uri`.
///
/// [singboxType] — тип тела, он же имя секции. Имени СХЕМЫ движок не знает:
/// её написание приезжает лексером из самого текста, а тип тела называет
/// диспетчер по реестру.
///
/// `null` — секции нет либо запись не построилась (нет обязательного поля).
UriMapping? mapViaEngine(String uri, String singboxType) {
  final section = MapperSections.I.sectionFor('uri', singboxType);
  if (section == null) return null;
  final res = runSection(section, uri);
  if (res == null) return null;
  return UriMapping(
    body: res.body,
    label: res.label,
    warnings: res.warnings,
    extensionFields: res.extensionFields,
    wsEarlyDataHeaderImplicit: res.wsEarlyDataHeaderImplicit,
    tagAddress: res.tagAddress,
    // Рода, объявленные ВХОДОМ (`kind_when` секции): правило реестра судит
    // тело, а вход мог попросить подвид протокола и не донести ни одного
    // годного поля. Имя рода — строка ИЗ ДАННЫХ, движок его не толкует.
    kinds: res.kinds,
    // §480 — вход НАЗЫВАЕТ СЕБЯ САМ: секция объявила `body_source`, и
    // санитайзер судит по нему `except_sources`.
    bodySource: BodySource.byRegistryName(res.bodySource),
  );
}

/// §480 W5 — результат перевода ОБЪЕКТНОГО элемента (Xray/sing-box-JSON).
///
/// Отличается от [UriMapping] тем, что метку сюда движок не отдаёт: имя
/// узла объектного входа приходит от ЭЛЕМЕНТА документа (`remarks`, `tag`),
/// а это уровень сборки документа, а не маппера одного узла.
final class JsonMapping {
  const JsonMapping({
    required this.body,
    this.warnings = const [],
    this.wsEarlyDataHeaderImplicit = false,
    this.tagScheme,
  });

  final Map<String, dynamic> body;
  final List<NodeWarning> warnings;
  final bool wsEarlyDataHeaderImplicit;

  /// Написание имени в теге-фолбэке безымянного узла, когда оно не равно
  /// типу тела: объявляется секцией (`label.fallback.scheme`).
  final String? tagScheme;
}

/// Перевести ОБЪЕКТНЫЙ элемент документа секцией вида [kind].
///
/// Диспетчера по имени протокола здесь нет: секцию выбирает `detect` самой
/// секции ([MapperSections.matchJson]) — это и есть «опознание элемента
/// декларативно» (§2 НОРМЫ). Движку остаётся исполнить найденную таблицу.
///
/// `null` — ни одна секция не опознала элемент либо обязательная запись не
/// нашла значения (тем же `null` отвечал рукописный диспетчер).
JsonMapping? mapJsonViaEngine(String kind, Map<String, dynamic> element) {
  final section = MapperSections.I.matchJson(kind, element);
  if (section == null) return null;
  final res = runSectionOnJson(section, element);
  if (res == null) return null;
  return JsonMapping(
    body: res.body,
    warnings: res.warnings,
    wsEarlyDataHeaderImplicit: res.wsEarlyDataHeaderImplicit,
    tagScheme: res.tagScheme,
  );
}
