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
  );
}
