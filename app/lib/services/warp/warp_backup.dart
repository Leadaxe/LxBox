/// §393 B8 — WARP-регистрации в LX Backup (`warp[]`).
///
/// Секция схемы — `contract/schema/backup.schema.json` (`warp[]`), семантика —
/// `contract/docs/BACKUP.md` §2: «WG/MASQUE-аккаунты; имена полей —
/// канонические из схемы (`type: wg|masque` + snake_case-поля регистрации),
/// маппинг в нативные при импорте».
///
/// Канон — snake_case-поля лаунчера (`core/state/disk_v6.go`:
/// `WarpWGAccount`/`WarpMasqueAccount`), а не мобильные имена: `private_key`
/// против `priv_key`, `peer_public` против `peer_pub`, `private_key_der`
/// против `priv_key_der`. Отсюда явная таблица перекладки — совпадение имён
/// тут случайное на трёх полях из десяти, и «просто отдать toJson()» дало бы
/// файл, который лаунчер прочитает как пустую регистрацию.
///
/// Поля, которых у канона нет (мобильная AWG-обфускация §126, SNI и таймауты
/// MASQUE-узла), едут в `extensions.lxbox` записи: применить их лаунчер не
/// может, но вернуть обязан (§1 BACKUP.md).
library;

import 'masque_account.dart';
import 'warp_account.dart';

/// Ключ приложения в per-entity `extensions` записи `warp[]`.
const String _kLxBox = 'lxbox';

/// §393 B8 — [WarpAccount] → каноническая запись `warp[]` (`type: wg`).
Map<String, dynamic> warpAccountToBackup(WarpAccount acc) {
  final own = <String, dynamic>{
    // §126 — AWG-обфускация: у лаунчера в снимке регистрации её нет
    // (там она свойство узла), а у нас лежит на аккаунте.
    if (acc.awg != null) 'awg': Map<String, Object>.from(acc.awg!.fields),
    // Endpoint у канона тоже отсутствует: лаунчер держит его в URI источника.
    if (acc.endpoint.isNotEmpty && acc.endpoint != WarpAccount.defaultEndpoint)
      'endpoint': acc.endpoint,
  };
  return <String, dynamic>{
    'type': 'wg',
    'private_key': acc.privKey,
    'peer_public': acc.peerPub,
    'client_v4': acc.clientV4,
    'client_v6': acc.clientV6,
    if (acc.clientId.isNotEmpty) 'client_id': acc.clientId,
    if (acc.deviceId.isNotEmpty) 'device_id': acc.deviceId,
    if (acc.token.isNotEmpty) 'token': acc.token,
    if (acc.accountId.isNotEmpty) 'account_id': acc.accountId,
    if (acc.license != null && acc.license!.isNotEmpty) 'license': acc.license,
    if (acc.warpPlus) 'warp_plus': true,
    if (acc.createdAt.isNotEmpty) 'created_at': acc.createdAt,
    if (own.isNotEmpty) 'extensions': {_kLxBox: own},
  };
}

/// §393 B8 — [MasqueAccount] → каноническая запись `warp[]` (`type: masque`).
Map<String, dynamic> masqueAccountToBackup(MasqueAccount acc) {
  // sni/idle_timeout/keep_alive — параметры УЗЛА, а не регистрации: канон их
  // не знает (`WarpMasqueAccount` их и не хранит), поэтому в своё расширение.
  final own = <String, dynamic>{
    if (acc.sni.isNotEmpty) 'sni': acc.sni,
    if (acc.idleTimeout.isNotEmpty) 'idle_timeout': acc.idleTimeout,
    if (acc.keepAlive.isNotEmpty) 'keep_alive': acc.keepAlive,
  };
  return <String, dynamic>{
    'type': 'masque',
    'private_key_der': acc.privKeyDer,
    'server_pub_der': acc.serverPubDer,
    'client_v4': acc.clientV4,
    'client_v6': acc.clientV6,
    'server': acc.server,
    if (acc.port != 0) 'port': acc.port,
    if (acc.deviceId.isNotEmpty) 'device_id': acc.deviceId,
    if (acc.token.isNotEmpty) 'token': acc.token,
    if (acc.createdAt.isNotEmpty) 'created_at': acc.createdAt,
    if (own.isNotEmpty) 'extensions': {_kLxBox: own},
  };
}

/// §393 B8 — каноническая запись → [WarpAccount]; `null` = не разобралось.
///
/// Регистрация без приватного ключа или без публичного ключа пира узел не
/// соберёт (эталон `import.go:601` — `acc.PrivateKey == ""` → skip): такая
/// запись не «частично применяется», она бесполезна целиком.
WarpAccount? warpAccountFromBackup(Map<String, dynamic> j) {
  if (j['type'] != 'wg') return null;
  final own = _ownExtensions(j);
  return WarpAccount.fromJson({
    'priv_key': j['private_key'],
    'peer_pub': j['peer_public'],
    'client_v4': j['client_v4'],
    'client_v6': j['client_v6'],
    'client_id': j['client_id'],
    'account_id': j['account_id'],
    'device_id': j['device_id'],
    'token': j['token'],
    // Канон endpoint не переносит — он вернулся из нашего расширения либо
    // берётся дефолтный (`engage.cloudflareclient.com:2408`).
    'endpoint': own['endpoint'] ?? WarpAccount.defaultEndpoint,
    'created_at': j['created_at'],
    'license': j['license'],
    'warp_plus': j['warp_plus'],
    'awg': ?_awgFrom(own['awg']),
  });
}

/// §393 B8 — каноническая запись → [MasqueAccount]; `null` = не разобралось.
MasqueAccount? masqueAccountFromBackup(Map<String, dynamic> j) {
  if (j['type'] != 'masque') return null;
  final own = _ownExtensions(j);
  return MasqueAccount.fromJson({
    'priv_key_der': j['private_key_der'],
    'server_pub_der': j['server_pub_der'],
    'client_v4': j['client_v4'],
    'client_v6': j['client_v6'],
    'server': j['server'],
    'port': j['port'],
    'device_id': j['device_id'],
    'token': j['token'],
    'created_at': j['created_at'],
    'sni': own['sni'],
    'idle_timeout': own['idle_timeout'],
    'keep_alive': own['keep_alive'],
  });
}

Map<String, dynamic> _ownExtensions(Map<String, dynamic> j) {
  final ext = (j['extensions'] as Map?)?[_kLxBox];
  return ext is Map ? ext.cast<String, dynamic>() : const {};
}

/// AWG-поля из своего расширения. Не-Map → `null` (обфускации нет), а не
/// пустой [Awg]: пустой набор полей — это «AWG включён без параметров», и
/// ядро собрало бы из него другой узел.
Map<String, dynamic>? _awgFrom(Object? raw) =>
    raw is Map && raw.isNotEmpty ? raw.cast<String, dynamic>() : null;
