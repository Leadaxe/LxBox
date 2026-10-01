/// §54/§57 (контракт 1.1.58/1.1.61) — каталог `strip` цепочки и
/// `on_hop_required` по реестру.
///
/// Каталог — поле `strip` тела `chain.json`: `order` — порядок показа и
/// эмиссии, `default` ключа — снимается ли он при включённом
/// `strip_evasion`. Своего списка ключей в Dart нет: имена, порядок и
/// умолчания живут в реестре, код только обходит их.
///
/// `on_hop_required {action: unstrip, code}` у ключа каталога: цепочка снимает
/// ключ, а тело звена на позиции ≥ 1 этот путь ТРЕБУЕТ (прогон тела без пути
/// через санитайзер вернул бы его правилом-починкой) — ключ снимается с патча
/// цепочки, цепочка собирается, код встаёт предупреждением. Ядро применяет
/// каталог ко всем звеньям разом, поэтому ключ остаётся у всех.
library;

import '../../models/source_chain.dart' show kChainOutboundType;
import '../json_clone.dart' show deepCloneJson;
import 'body_sanitizer.dart';
import 'registry.dart';
import 'registry_warning.dart';

/// Ключ каталога `strip`.
final class ChainStripKey {
  const ChainStripKey({
    required this.key,
    required this.stripByDefault,
    required this.schema,
  });

  /// Ключ ядра (`tls.utls`). Точка — часть имени, не вложенность; по тому же
  /// пути лежит снимаемая часть тела звена.
  final String key;

  /// `default` — снимается ли ключ при включённом `strip_evasion`.
  final bool stripByDefault;

  final FieldSchema schema;

  Map<String, dynamic>? get _onHopRequired =>
      (schema.raw['on_hop_required'] as Map?)?.cast<String, dynamic>();

  /// Код `on_hop_required` с действием `unstrip`; `null` — атрибута нет.
  String? get unstripCode {
    final r = _onHopRequired;
    if (r == null || r['action'] != 'unstrip') return null;
    return r['code'] as String?;
  }

  /// Описание ключа из реестра на языке [lang].
  String description(RegistryLang lang) =>
      (schema.raw[lang == RegistryLang.ru ? 'desc_ru' : 'desc_en']
          as String?) ??
      '';
}

/// Каталог в порядке `order`. Пусто — реестр не загружен (или у схемы
/// цепочки каталога нет).
List<ChainStripKey> chainStripCatalog() {
  final strip = ContractRegistry.I
      .schemaFor(kChainOutboundType)
      ?.fields['strip'];
  final fields = strip?.fields;
  if (fields == null) return const [];
  final order = strip!.order ?? fields.keys.toList();
  return [
    for (final k in order)
      if (fields[k] != null)
        ChainStripKey(
          key: k,
          stripByDefault: fields[k]!.defaultValue == true,
          schema: fields[k]!,
        ),
  ];
}

/// Ключи каталога в порядке показа.
List<String> chainStripKeys() => [for (final k in chainStripCatalog()) k.key];

/// Годится ли [key] в патч `strip`. Реестр не загружен — судить нечем, ключ
/// сохраняется (неизвестный ключ на сборке снимет гард реестра).
bool chainStripKeyKnown(String key) {
  final keys = chainStripKeys();
  return keys.isEmpty || keys.contains(key);
}

/// Патч [strip] в порядке каталога; ключи вне каталога (реестр не загружен)
/// — следом, в своём порядке.
Map<String, bool> orderedChainStrip(Map<String, bool> strip) {
  final keys = chainStripKeys();
  return {
    for (final k in keys)
      if (strip.containsKey(k)) k: strip[k]!,
    for (final e in strip.entries)
      if (!keys.contains(e.key)) e.key: e.value,
  };
}

/// Снимается ли ключ при данных галках: точечный патч, затем общий
/// `strip_evasion` (выключен — не снимается ничего), затем `default`
/// каталога. Та же лестница, что у ядра.
bool chainStripsKey(
  ChainStripKey k, {
  required bool? stripEvasion,
  required Map<String, bool> patch,
}) {
  final explicit = patch[k.key];
  if (explicit != null) return explicit;
  if (stripEvasion == false) return false;
  return k.stripByDefault;
}

/// Требует ли тело [body] путь [path]: тело без пути, прогнанное через
/// санитайзер, получает его обратно правилом-починкой (`requires[].set`).
bool hopBodyRequiresPath(Map<String, dynamic> body, String path) {
  final type = body['type'];
  if (type is! String) return false;
  final copy = (deepCloneJson(body) as Map).cast<String, dynamic>();
  final parts = path.split('.');
  Map<String, dynamic>? cur = copy;
  for (var i = 0; i < parts.length - 1 && cur != null; i++) {
    final next = cur[parts[i]];
    cur = next is Map ? next.cast<String, dynamic>() : null;
  }
  // Пути в теле нет вовсе (родителя нет) — тело его и не требует: санитайзер
  // не создаёт ветку, которой нет.
  if (cur == null) return false;
  cur.remove(parts.last);
  final out = RegistrySanitizer.sanitize(
    copy,
    scheme: type,
    coreVersion: '',
    applyCoreGates: false,
  ).body;
  if (out == null) return false;
  Object? v = out;
  for (final p in parts) {
    if (v is! Map) return false;
    v = v[p];
  }
  return v != null;
}

/// Ключ, снятый с патча цепочки ради звена [target].
final class ChainUnstrip {
  const ChainUnstrip({
    required this.key,
    required this.code,
    required this.target,
  });

  final String key;
  final String code;

  /// Тег звена, которое путь требует.
  final String target;
}

/// Что снимается с патча цепочки по `on_hop_required`. [hops] — позиции в
/// порядке пакета с телами (тело `null` — не узел или неизвестно); судятся
/// позиции ≥ 1: каталог действует на звенья, первая позиция идёт как есть.
List<ChainUnstrip> chainHopUnstrips({
  required bool? stripEvasion,
  required Map<String, bool> patch,
  required List<(String, Map<String, dynamic>?)> hops,
}) {
  final out = <ChainUnstrip>[];
  if (hops.length < 2) return out;
  for (final k in chainStripCatalog()) {
    final code = k.unstripCode;
    if (code == null) continue;
    if (!chainStripsKey(k, stripEvasion: stripEvasion, patch: patch)) continue;
    for (var i = 1; i < hops.length; i++) {
      final body = hops[i].$2;
      if (body == null) continue;
      if (hopBodyRequiresPath(body, k.key)) {
        out.add(ChainUnstrip(key: k.key, code: code, target: hops[i].$1));
      }
    }
  }
  return out;
}

/// Патч [patch] после [unstrips]: снятые ключи явно `false`.
Map<String, bool> applyChainUnstrips(
  Map<String, bool> patch,
  List<ChainUnstrip> unstrips,
) => orderedChainStrip({...patch, for (final u in unstrips) u.key: false});
