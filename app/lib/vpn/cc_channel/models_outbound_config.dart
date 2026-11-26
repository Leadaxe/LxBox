part of '../cc_channel.dart';

/// §761 — ответ `GetOutboundConfig(tag)` ядра (v1.14.4-lx.37-rc.2, SPEC 165
/// форка §2.2): узел таким, каким его запустило ядро.
///
/// `original` — как в `GetRunningConfig` (до перезаписи), `effective` — как
/// в `GetEffectiveConfig` (после перезаписи цепочек и выравнивания MTU),
/// `changes` — что поменялось, в порядке применения. У хопа цепочки
/// (`chain-hop`) есть только `effective`.
class CcOutboundConfig {
  const CcOutboundConfig({
    required this.tag,
    required this.effective,
    this.original,
    this.changes = const [],
  });

  final String tag;
  final Map<String, dynamic> effective;
  final Map<String, dynamic>? original;
  final List<CcConfigChange> changes;

  /// Разбор строки `content()`. Не JSON, не объект или без `effective` —
  /// `null`: показывать нечего, свой конфиг вместо него не подставляется.
  static CcOutboundConfig? tryParse(String? content) {
    if (content == null || content.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final effective = decoded['effective'];
    if (effective is! Map) return null;
    final original = decoded['original'];
    final rawChanges = decoded['changes'];
    return CcOutboundConfig(
      tag: decoded['tag']?.toString() ?? '',
      effective: effective.cast<String, dynamic>(),
      original: original is Map ? original.cast<String, dynamic>() : null,
      changes: [
        if (rawChanges is List)
          for (final c in rawChanges)
            if (c is Map) CcConfigChange.fromMap(c.cast<String, dynamic>()),
      ],
    );
  }
}

/// Одна правка поля узла: `field` — путь через точку (`tls.server_name`),
/// `from` нет — поля не было, `to` нет — поле снято.
class CcConfigChange {
  const CcConfigChange({
    required this.field,
    required this.by,
    this.from,
    this.to,
    this.hasFrom = false,
    this.hasTo = false,
  });

  final String field;
  final Object? from;
  final Object? to;
  final bool hasFrom;
  final bool hasTo;
  final CcConfigChangeBy by;

  factory CcConfigChange.fromMap(Map<String, dynamic> m) => CcConfigChange(
        field: m['field']?.toString() ?? '',
        from: m['from'],
        to: m['to'],
        hasFrom: m.containsKey('from'),
        hasTo: m.containsKey('to'),
        by: CcConfigChangeBy.fromMap(
            m['by'] is Map ? (m['by'] as Map).cast<String, dynamic>() : const {}),
      );
}

/// Кто сделал правку. `type` — закрытый список ядра: [typeChain],
/// [typeChainRewrite], [typeMtuAlign]; остальные поля — по типу.
class CcConfigChangeBy {
  const CcConfigChangeBy({
    required this.type,
    this.chain = '',
    this.position = 0,
    this.nodeType = '',
    this.mode = '',
    this.below = '',
    this.overhead = 0,
    this.reason = '',
  });

  static const typeChain = 'chain';
  static const typeChainRewrite = 'chain_rewrite';
  static const typeMtuAlign = 'mtu_align';

  final String type;
  final String chain;

  /// Позиция цепочки с 0, как у ядра.
  final int position;
  final String nodeType;
  final String mode;
  final String below;
  final int overhead;
  final String reason;

  factory CcConfigChangeBy.fromMap(Map<String, dynamic> m) => CcConfigChangeBy(
        type: m['type']?.toString() ?? '',
        chain: m['chain']?.toString() ?? '',
        position: _int(m['position']),
        nodeType: m['node_type']?.toString() ?? '',
        mode: m['mode']?.toString() ?? '',
        below: m['below']?.toString() ?? '',
        overhead: _int(m['overhead']),
        reason: m['reason']?.toString() ?? '',
      );
}
