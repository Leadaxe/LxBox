part of '../post_steps.dart';

/// Post-step: рандомизация регистра букв в `server_name` first-hop outbound'ов
/// (§028 spec). Mixed-case SNI ломает exact-match DPI без изменения поведения
/// сервера (RFC 6066 §3 — SNI case-insensitive). First-hop only — inner hops
/// в туннеле, локальный DPI их не видит. Punycode-метки (`xn--…`) не трогаем —
/// `xn--` префикс зарезервирован, регистр в Punycode-payload sensitive.
///
/// Выполняется на этапе emit конфига; зафиксировано на жизнь туннеля.
/// Re-randomization на каждый handshake потребовала бы патча libbox.
void applyMixedCaseSni(Map<String, dynamic> config, Map<String, String> vars) {
  if (vars['tls_mixed_case_sni'] != 'true') return;
  final rng = Random.secure();
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    // §363 — REALITY: SNI входит в AAD хендшейка (клиент шифрует SessionId с
    // hello.Raw целиком), а сервер матчит имя по map с точным строковым ключом
    // и БЕЗ нормализации регистра. Любая изменённая буква → промах по map →
    // молчаливый fallback на маскировочный сайт, узел не поднимается.
    // Обфусцировать тут и нечего: SNI у REALITY и так фиктивный.
    final reality = tls['reality'];
    if (reality is Map<String, dynamic> && reality['enabled'] == true) continue;
    final sn = tls['server_name'];
    if (sn is! String || sn.isEmpty) continue;
    tls['server_name'] = _randomizeHostCase(sn, rng);
  }
}

String _randomizeHostCase(String host, Random rng) {
  // Идём по DNS-меткам (split по '.'). xn--… — Punycode, не трогаем.
  final labels = host.split('.');
  for (var i = 0; i < labels.length; i++) {
    final label = labels[i];
    if (label.startsWith('xn--')) continue;
    final buf = StringBuffer();
    for (final cu in label.codeUnits) {
      // ASCII letter? рандомим. Всё остальное (цифры, дефис, не-ASCII) — как есть.
      final isUpper = cu >= 0x41 && cu <= 0x5A;
      final isLower = cu >= 0x61 && cu <= 0x7A;
      if (isUpper || isLower) {
        buf.writeCharCode(rng.nextBool() ? (cu | 0x20) : (cu & ~0x20));
      } else {
        buf.writeCharCode(cu);
      }
    }
    labels[i] = buf.toString();
  }
  return labels.join('.');
}

/// Post-step: применение tls_fragment к first-hop'ам (без `detour`).
/// Inner hops уже в туннеле, DPI не видит их TLS — фрагментация не нужна.
void applyTlsFragment(Map<String, dynamic> config, Map<String, String> vars) {
  final fragment = vars['tls_fragment'] == 'true';
  final recordFragment = vars['tls_record_fragment'] == 'true';
  if (!fragment && !recordFragment) return;

  final fallbackDelay = vars['tls_fragment_fallback_delay'] ?? '500ms';
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    // §270 — naive-outbound отвергает fragment/record_fragment на уровне ядра
    // (fatal «fragment is not supported on naive outbound»). naive принимает в
    // TLS только enabled/server_name — глобальный fragment ему не наложить.
    if (ob['type'] == 'naive') continue;
    // §393 — masque: TLS всегда включён по природе транспорта, поля `enabled`
    // у него нет, а блок `tls{}` появляется только если задан SNI. Фрагментация
    // осмысленна лишь на `vhttp: h2` (TCP+TLS); при h3 ядро пишет предупреждение
    // и игнорирует её — пропускаем молча, глобальный тумблер не должен ругаться
    // на каждый неподходящий узел. Legacy-имя `network` читаем для конфигов,
    // написанных до миграции (ручной редактор, чужой JSON).
    if (ob['type'] == 'masque') {
      final v = ob['vhttp'] ?? ob['network'];
      if (v != 'h2') continue;
      final mTls = (ob['tls'] ??= <String, dynamic>{}) as Map<String, dynamic>;
      if (fragment) mTls['fragment'] = true;
      if (recordFragment) mTls['record_fragment'] = true;
      mTls['fragment_fallback_delay'] = fallbackDelay;
      continue;
    }
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    if (tls['enabled'] != true) continue;
    if (fragment) tls['fragment'] = true;
    if (recordFragment) tls['record_fragment'] = true;
    tls['fragment_fallback_delay'] = fallbackDelay;
  }
}
