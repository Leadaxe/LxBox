part of '../post_steps.dart';

/// Post-step: §343 — страховка от битого REALITY-блока в собранном конфиге.
///
/// ПРОБЛЕМА: ядро декодирует `tls.reality.short_id` как hex в `[8]byte` —
/// нечётная длина / non-hex / >16 символов = fatal ВСЕГО конфига на старте
/// (`initialize outbound[N]: decode short_id: ...`). Аналогично
/// `public_key`, не декодирующийся в 32 байта X25519 = `invalid public_key`.
/// Парсер уже гейтит оба (§169 pbk, §343 normalizeRealityShortId), этот шаг
/// — страховка для путей мимо парсера: raw sing-box JSON узлы, §302 import
/// rules (Replace патчит emit-JSON), vars-подстановки, Debug API.
///
/// РЕШЕНИЕ (принцип §169: битое значение отбрасывается, не подгоняется):
/// - невалидный `short_id` → `''` (пустой sid легален: клиент шлёт нулевой
///   `[8]byte`, сервер без shortIds принимает) + запись для emitWarnings;
/// - невалидный `public_key` → снимаем весь `reality`-блок, нода
///   деградирует до plain TLS (зеркало §169 на последнем рубеже) + запись.
///
/// Возвращает список исправлений (`owner → field → исходное значение`).
/// Пустой = всё чисто.
List<({String owner, String field, String original})> healInvalidReality(
    Map<String, dynamic> config) {
  final healed = <({String owner, String field, String original})>[];
  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  for (final o in outbounds) {
    final tls = o['tls'];
    if (tls is! Map<String, dynamic>) continue;
    final reality = tls['reality'];
    if (reality is! Map<String, dynamic>) continue;
    // Выключенный блок ядро не декодирует — не fatal, не трогаем (как §281).
    if (reality['enabled'] != true) continue;
    final tag = o['tag'] as String? ?? '';

    final pbk = reality['public_key'];
    if (pbk is! String || !isValidRealityPublicKey(pbk)) {
      tls.remove('reality');
      healed.add((owner: tag, field: 'public_key', original: '$pbk'));
      continue;
    }

    final sid = reality['short_id'];
    if (sid != null && sid is! String) {
      // Не-строковый short_id (число из raw-JSON узла / §302-патча) ядро
      // тоже не декодирует — тот же fatal. Отброс, не подгон (§169).
      reality['short_id'] = '';
      healed.add((owner: tag, field: 'short_id', original: '$sid'));
    } else if (sid is String && sid.isNotEmpty && !_isValidRealityShortId(sid)) {
      reality['short_id'] = '';
      healed.add((owner: tag, field: 'short_id', original: sid));
    }
  }
  return healed;
}

/// Строгая проверка формы short_id (без нормализации — на этом рубеже
/// значение обязано быть уже каноничным): hex 0-9a-fA-F, чётная длина, ≤16.
bool _isValidRealityShortId(String s) {
  if (s.length > 16 || s.length.isOdd) return false;
  for (final r in s.runes) {
    final hex = (r >= 0x30 && r <= 0x39) ||
        (r >= 0x61 && r <= 0x66) ||
        (r >= 0x41 && r <= 0x46);
    if (!hex) return false;
  }
  return true;
}
