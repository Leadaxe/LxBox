part of '../post_steps.dart';

/// Post-step: рандомизация регистра букв в `server_name` first-hop outbound'ов
/// (§028 spec). Mixed-case SNI ломает exact-match DPI без изменения поведения
/// сервера (RFC 6066 §3 — SNI case-insensitive). First-hop only — inner hops
/// в туннеле, локальный DPI их не видит. Punycode-метки (`xn--…`) не трогаем —
/// `xn--` префикс зарезервирован, регистр в Punycode-payload sensitive.
///
/// Выполняется на этапе emit конфига; зафиксировано на жизнь туннеля.
/// Re-randomization на каждый handshake потребовала бы патча libbox.
///
/// §636 — [byTag]: уровни TLS-политики outbound'ов из источников по
/// итоговому тегу (узел → источник → глобальный `vars`, первое не-`null`
/// побеждает). Outbound не из источника — только глобальный слой.
void applyMixedCaseSni(
  Map<String, dynamic> config,
  Map<String, String> vars, {
  Map<String, TlsLayers> byTag = const {},
}) {
  final global = vars['tls_mixed_case_sni'] == 'true';
  if (!global && byTag.isEmpty) return;
  Random? rng;
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    final layers = byTag[ob['tag']];
    final on = layers?.node.mixedCaseSni ??
        layers?.source.mixedCaseSni ??
        global;
    if (!on) continue;
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    // §363 — REALITY: SNI входит в AAD хендшейка (клиент шифрует SessionId с
    // hello.Raw целиком), а сервер матчит имя по map с точным строковым ключом
    // и БЕЗ нормализации регистра. Любая изменённая буква → промах по map →
    // молчаливый fallback на маскировочный сайт, узел не поднимается.
    // Обфусцировать тут и нечего: SNI у REALITY и так фиктивный. §636 — ни на
    // каком уровне.
    final reality = tls['reality'];
    if (reality is Map<String, dynamic> && reality['enabled'] == true) continue;
    final sn = tls['server_name'];
    if (sn is! String || sn.isEmpty) continue;
    tls['server_name'] = _randomizeHostCase(sn, rng ??= Random.secure());
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
///
/// Контракт 1.1.64 — годность поля узлу спрашивается у реестра ПО ТЕЛУ
/// ([fieldAllowedOn]): «оставил бы санитайзер `tls.fragment` при этом
/// теле». Так naive (`forbidden_for`) и masque на `vhttp: h3` (связь
/// `conflicts` с `when`) фрагментацию не получают, masque на h2/auto —
/// получает, без списка схем в коде.
///
/// §636 — [byTag]: уровни TLS-политики outbound'ов из источников по
/// итоговому тегу; каждое поле отдельно: узел → источник → глобальный `vars`.
/// `false` не снимает флаг, пришедший в теле, — только не дописывает.
/// REALITY фрагментируется, только если флаг задан на уровне узла (§627:
/// массовая настройка не знает, примет ли сервер резаный ClientHello).
void applyTlsFragment(
  Map<String, dynamic> config,
  Map<String, String> vars, {
  Map<String, TlsLayers> byTag = const {},
}) {
  final fragment = vars['tls_fragment'] == 'true';
  final recordFragment = vars['tls_record_fragment'] == 'true';
  if (!fragment && !recordFragment && byTag.isEmpty) return;

  final globalDelay = vars['tls_fragment_fallback_delay'] ?? '';
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    final layers = byTag[ob['tag']];
    final node = layers?.node ?? TlsPolicy.none;
    final source = layers?.source ?? TlsPolicy.none;
    final wantFragment = node.fragment ?? source.fragment ?? fragment;
    final wantRecord =
        node.recordFragment ?? source.recordFragment ?? recordFragment;
    var addFragment = wantFragment && fieldAllowedOn(ob, 'tls.fragment');
    var addRecord = wantRecord && fieldAllowedOn(ob, 'tls.record_fragment');
    if (!addFragment && !addRecord) continue;
    Map<String, dynamic> tls;
    // §393 — masque: TLS всегда включён по природе транспорта, выключателя
    // `enabled` у него нет, а блок `tls{}` появляется только если задан SNI.
    if (ob['type'] == 'masque') {
      tls = (ob['tls'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    } else {
      final t = ob['tls'];
      if (t is! Map<String, dynamic>) continue;
      if (t['enabled'] != true) continue;
      // §627 — REALITY-сервер не принимает разрезанный ClientHello (с lx.4
      // ядро режет и его), а маскировка у REALITY своя. §636 — кроме флага,
      // поставленного на сам узел.
      final reality = t['reality'];
      if (reality is Map && reality['enabled'] == true) {
        addFragment = addFragment && node.fragment != null;
        addRecord = addRecord && node.recordFragment != null;
        if (!addFragment && !addRecord) continue;
      }
      tls = t;
    }
    // §606 — значение, которое ядро не разберёт как duration (`500`, `fast`,
    // `1 s`), отвергло бы конфиг целиком: подставляется умолчание шаблона.
    final rawDelay = node.fallbackDelay ?? source.fallbackDelay ?? globalDelay;
    final fallbackDelay =
        parseCoreDurationNanos(rawDelay) == null ? '500ms' : rawDelay;
    if (addFragment) tls['fragment'] = true;
    if (addRecord) tls['record_fragment'] = true;
    tls['fragment_fallback_delay'] = fallbackDelay;
  }
}

/// Post-step (контракт 1.1.65): `detour` дописывает сборка ПОСЛЕ санитайзера,
/// поэтому связи `conflicts {with: detour}` реестра перепроверяются здесь, по
/// готовому телу каждого outbound/endpoint с `detour`: уступающие поля
/// снимаются с кодом связи ([yieldToBuildDetour]). Хоп сохраняется — снять
/// detour значило бы тихий прямой дозвон.
///
/// Контракт 1.1.84 (§81) — туда же `tls.fragment` (код
/// `detour_with_tls_fragment`) у любого узлового флага, откуда бы он ни
/// пришёл. Порядок в сборке: после проставления `detour` (цепочки,
/// `override_detour`) и ДО [applyTlsFragment].
///
/// §577 — [authored] (identity-множество карт тел): авторскому телу уступка
/// идёт через точку правки, мягкая (`tls.fragment`) не применяется.
List<RegistryWarning> applyDetourYields(
  Map<String, dynamic> config, {
  Set<Map<String, dynamic>> authored = const {},
}) {
  final out = <RegistryWarning>[];
  for (final key in const ['outbounds', 'endpoints']) {
    final list = config[key];
    if (list is! List) continue;
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      if (!e.containsKey('detour')) continue;
      out.addAll(yieldToBuildDetour(e, authored: authored.contains(e)));
    }
  }
  return out;
}
