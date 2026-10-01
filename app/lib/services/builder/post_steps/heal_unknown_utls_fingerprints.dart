part of '../post_steps.dart';

/// Post-step: §281 — страховка от неизвестного uTLS fingerprint.
///
/// ПРОБЛЕМА: значение `tls.utls.fingerprint` вне словаря ядра
/// (`uTLSClientHelloID`, case-sensitive) = «unknown uTLS fingerprint» при
/// конструировании outbound в box.New = fatal ВСЕГО конфига на старте.
/// Парсер уже канонизирует на входе (см. utls_fingerprint.dart), этот шаг —
/// страховка для путей мимо парсера (vars-подстановки, будущие источники).
///
/// РЕШЕНИЕ (как §172): известные xray-псевдонимы (hellochrome_* и семейство)
/// канонизируются молча; неопознанный мусор → `chrome` + запись для
/// emitWarnings. Пробельное значение → поле снимается (utls остаётся
/// enabled — пустой fingerprint ядро трактует как chrome).
///
/// Контракт 1.1.61 (§556): пара REALITY ↔ uTLS — правила реестра
/// (`tls.reality.enabled` requires `tls.utls.enabled` с `set`,
/// `tls.utls.fingerprint.coerce_when` random → chrome); их исполняет
/// санитайзер на всех входах и гард сборки, с кодом на узле. Сборочной
/// копии здесь больше нет: пустой отпечаток под REALITY остаётся пустым
/// (ядро = chrome).
///
/// Возвращает список замен мусора (`owner → исходное значение`). Пустой =
/// всё чисто (тихие канонизации псевдонимов в список не попадают).
///
/// §577 — правка идёт через точку правки ([editBodyPath]): у авторского
/// тела ([authored], identity-множество карт) применяется только жёсткое
/// правило (`utls_fp_unknown` — `core_rejects`); снятие uTLS/REALITY на
/// QUIC (`tls_not_applicable_quic`) мягкое — тело не меняется.
List<({String owner, String original})> healUnknownUtlsFingerprints(
  Map<String, dynamic> config, {
  Set<Map<String, dynamic>> authored = const {},
}) {
  final healed = <({String owner, String original})>[];
  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  for (final o in outbounds) {
    final tls = o['tls'];
    if (tls is! Map<String, dynamic>) continue;
    // §282 — uTLS И reality поверх QUIC (hysteria2/tuic) = мёртвая нода
    // (SPECS/027). Здесь именно СНИМАЕМ оба блока (эмиттер их не пишет, но
    // vars/будущие пути могут); НЕ восстанавливаем utls как для TCP+reality
    // ниже — иначе воскресили бы мёртвую QUIC-ноду.
    final own = authored.contains(o);
    if (o['type'] == 'hysteria2' || o['type'] == 'tuic') {
      for (final k in const ['utls', 'reality']) {
        if (!tls.containsKey(k)) continue;
        editBodyPath(o,
            authored: own,
            code: 'tls_not_applicable_quic',
            path: 'tls.$k',
            remove: true);
      }
      continue;
    }
    final utls = tls['utls'];
    if (utls is! Map<String, dynamic>) continue;
    final fp = utls['fingerprint'];
    if (fp is String && fp.isNotEmpty) {
      final n = normalizeUtlsFingerprintValue(fp);
      if (n.value != fp) {
        final done = editBodyPath(o,
            authored: own,
            code: 'utls_fp_unknown',
            path: 'tls.utls.fingerprint',
            value: n.value,
            remove: n.value.isEmpty);
        if (done && n.value.isNotEmpty && n.junk) {
          healed.add((owner: o['tag'] as String? ?? '', original: fp));
        }
      }
    }
  }
  return healed;
}
