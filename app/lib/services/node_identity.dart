import '../models/node_spec.dart';

/// §321 P4 / §322 — идентичность узла: `protocol|server|port|credential`.
///
/// Тот же ключ, что парсер считает по сырому Xray-JSON (`_xrayIdentity`), но
/// от готового [NodeSpec]. Нужен там, где сырья уже нет: резолв состава пула
/// автовыбора на билде, таблица синонимов.
///
/// **Не включает транспорт и TLS** — решение юзера 30.07.2026 («протокол
/// сервер порт uuid»). Следствие: один сервер с двумя разными SNI считается
/// одним узлом.
///
/// `null` — у узла нет адреса (группа §322) либо протокол без учётных данных,
/// который нельзя отличить от соседа. Такой узел не участвует в дедупе и не
/// может быть членом пула по ключу.
String? nodeIdentityKey(NodeSpec node) {
  // §302 — правило импорта могло переписать узел (`patchedJson`), и в конфиг
  // уходит именно патч. Считаем ключ от НЕГО: иначе замена `server`/`uuid`
  // делает состав пула §322 висячим — синонимы указывают на прежний адрес.
  final patch = node.patchedJson;
  if (patch != null && !node.isGroup) {
    final server = _patchServer(patch);
    if (server.isEmpty) return null;
    final type = patch['type']?.toString() ?? node.protocol;
    return '$type|$server|${patch['server_port'] ?? node.port}|'
        '${_patchCred(patch)}';
  }
  return nodeIdentityKeyRaw(node);
}

/// Идентичность БЕЗ учёта §302-патча — как узел приехал от провайдера.
/// Нужна, чтобы сопоставить «было → стало» при пересчёте синонимов.
String? nodeIdentityKeyRaw(NodeSpec node) {
  if (node.isGroup || node.server.isEmpty) return null;
  final cred = switch (node) {
    VlessSpec s => s.uuid,
    VmessSpec s => s.uuid,
    TrojanSpec s => s.password,
    ShadowsocksSpec s => s.password,
    Hysteria2Spec s => s.password,
    AnyTlsSpec s => s.password,
    TuicSpec s => s.uuid,
    NaiveSpec s => s.password,
    SocksSpec s => s.username,
    HttpSpec s => s.username,
    SshSpec s => s.user,
    WireguardSpec s => s.privateKey,
    MasqueSpec s => s.privateKeyDer,
    AutoSelectSpec() => '',
  };
  return '${node.protocol}|${node.server}|${node.port}|$cred';
}

/// Адрес из sing-box-патча. WireGuard-endpoint держит его в `peers[0]`.
String _patchServer(Map<String, dynamic> patch) {
  final direct = patch['server']?.toString() ?? '';
  if (direct.isNotEmpty) return direct;
  final peers = patch['peers'];
  if (peers is List && peers.isNotEmpty && peers.first is Map) {
    return (peers.first as Map)['address']?.toString() ?? '';
  }
  return '';
}

/// Учётные данные из патча — первое непустое из известных имён полей
/// (`node_spec_emit.dart`). Порядок повторяет приоритет протоколов: у TUIC
/// есть и `uuid`, и `password`, ключом служит `uuid` (как в switch выше).
String _patchCred(Map<String, dynamic> patch) {
  for (final k in const ['uuid', 'password', 'private_key', 'username', 'user']) {
    final v = patch[k]?.toString() ?? '';
    if (v.isNotEmpty) return v;
  }
  return '';
}
