import '../../../models/source_chain.dart';

/// §393 C — цепочка для `/chains/*`: поля источника (`tag`, `label`,
/// `enabled`), канон `source_chain.schema.json` ([SourceChain.toCanonJson]) и
/// позиция в общем списке источников `order`.
///
/// Ответ собирается здесь, а не из записи хранения (`SourceChain.toJson`):
/// форма хранения меняется отдельно от формы Debug API (§439).
Map<String, Object?> serializeChain(SourceChain c) => {
      'tag': c.tag,
      'label': c.label,
      'enabled': c.enabled,
      ...c.toCanonJson(),
      if (c.order >= 0) 'order': c.order,
    };
