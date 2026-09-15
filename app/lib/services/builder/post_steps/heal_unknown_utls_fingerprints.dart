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
/// §444 (заменяет подмену SPEC 083 / D-104 из 2.23.2; у лаунчера — D-119):
/// под REALITY явный отпечаток узла из подписки уходит в конфиг КАК ЕСТЬ —
/// приложение не переписывает выбор источника. Про Xray ≥ v26.9.8 узлу
/// говорит `RealityFingerprintWarning` (парсер), конфиг не трогаем.
///
/// `chrome` пишется ЯВНО только там, где выбора не было: отсутствующий или
/// пустой fingerprint и `random`. `random` — дефолт парсеров vless/anytls/
/// Xray-JSON при пустом `fp` (D-009); в модели он от явного `fp=random`
/// неотличим, поэтому подменяется любой `random` (как у лаунчера). Молча:
/// это наш дефолт, а не чужой выбор.
///
/// Возвращает список замен мусора (`owner → исходное значение`). Пустой =
/// всё чисто (тихие канонизации псевдонимов в список не попадают).
List<({String owner, String original})> healUnknownUtlsFingerprints(
    Map<String, dynamic> config) {
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
    if (o['type'] == 'hysteria2' || o['type'] == 'tuic') {
      tls.remove('utls');
      tls.remove('reality');
      continue;
    }
    var utls = tls['utls'];
    // §281 (ревью) — REALITY без uTLS-блока = fatal «uTLS is required by
    // reality client» при создании outbound. Восстанавливаем минимальный
    // блок (пустой fingerprint ядро трактует как chrome).
    final reality = tls['reality'];
    if (reality is Map<String, dynamic> && reality['enabled'] == true) {
      if (utls is! Map<String, dynamic>) {
        utls = <String, dynamic>{'enabled': true};
        tls['utls'] = utls;
      } else if (utls['enabled'] != true) {
        utls['enabled'] = true;
      }
    }
    if (utls is! Map<String, dynamic>) continue;
    final fp = utls['fingerprint'];
    if (fp is String && fp.isNotEmpty) {
      final n = normalizeUtlsFingerprintValue(fp);
      if (n.value != fp) {
        if (n.value.isEmpty) {
          utls.remove('fingerprint');
        } else {
          utls['fingerprint'] = n.value;
          if (n.junk) {
            healed.add((owner: o['tag'] as String? ?? '', original: fp));
          }
        }
      }
    }
    // §444 — под REALITY `chrome` ЯВНО только вместо «выбора не было»
    // (см. docstring); на дефолт ядра для пустой строки не полагаемся, чтобы
    // конфиг не зависел от того, что ядро считает дефолтом в этой версии.
    // Любой другой отпечаток из словаря — выбор источника узла, не трогаем.
    final realityOn =
        reality is Map<String, dynamic> && reality['enabled'] == true;
    if (realityOn) {
      final cur = utls['fingerprint'];
      if (cur is! String || cur.isEmpty || cur == 'random') {
        utls['fingerprint'] = 'chrome';
      }
    }
  }
  return healed;
}
