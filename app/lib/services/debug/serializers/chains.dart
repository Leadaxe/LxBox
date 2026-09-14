import '../../../models/source_chain.dart';

/// §393 C — цепочка для `/chains/*`: поля источника (`tag`, `label`,
/// `enabled`) и канон `source_chain.schema.json` ([SourceChain.toCanonJson]).
///
/// Места в ответе нет (§439 §3.4): порядок цепочек — порядок списка
/// `GET /chains`, как порядок записей хранения.
///
/// Ответ собирается здесь, а не из записи хранения (`chainToRecord`): форма
/// хранения меняется отдельно от формы Debug API.
Map<String, Object?> serializeChain(SourceChain c) => {
      'tag': c.tag,
      'label': c.label,
      'enabled': c.enabled,
      ...c.toCanonJson(),
    };
