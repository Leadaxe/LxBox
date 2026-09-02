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
/// MASQUE-узла), лежат в записи ПЛОСКО, рядом с полями регистрации. Карман
/// `extensions.lxbox` для них упразднён контрактом 0.12.2: секция `warp[]`
/// объявлена открытой (`additionalProperties: true`, «поля записи, кроме
/// объявленных, — snake_case поля самой регистрации»), а `sni` и
/// `idle_timeout` схема объявляет поимённо с пометкой `extension: mobile`.
/// Лаунчер их не применяет, но провозит сырым JSON — чужое ОБЪЯВЛЕННОЕ
/// игнорируется молча, без предупреждения (§1/§2 BACKUP.md).
library;

import 'masque_account.dart';
import 'warp_account.dart';

/// §393 B8 — [WarpAccount] → каноническая запись `warp[]` (`type: wg`).
Map<String, dynamic> warpAccountToBackup(WarpAccount acc) {
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
    // §126 — AWG-обфускация: у лаунчера в снимке регистрации её нет
    // (там она свойство узла), а у нас лежит на аккаунте.
    if (acc.awg != null) 'awg': Map<String, Object>.from(acc.awg!.fields),
    // Endpoint у канона тоже отсутствует: лаунчер держит его в URI источника.
    if (acc.endpoint.isNotEmpty && acc.endpoint != WarpAccount.defaultEndpoint)
      'endpoint': acc.endpoint,
  };
}

/// §393 B8 — [MasqueAccount] → каноническая запись `warp[]` (`type: masque`).
Map<String, dynamic> masqueAccountToBackup(MasqueAccount acc) {
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
    // sni/idle_timeout — параметры УЗЛА, а не регистрации: `WarpMasqueAccount`
    // их не хранит. Схема 0.12.2 объявляет оба поимённо (`extension: mobile`)
    // ПЛОСКО в записи — необязательные, пишутся только когда заданы.
    if (acc.sni.isNotEmpty) 'sni': acc.sni,
    if (acc.idleTimeout.isNotEmpty) 'idle_timeout': acc.idleTimeout,
    if (acc.keepAlive.isNotEmpty) 'keep_alive': acc.keepAlive,
  };
}

/// §393 B8 — каноническая запись → [WarpAccount]; `null` = не разобралось.
///
/// Регистрация без приватного ключа или без публичного ключа пира узел не
/// соберёт (эталон `import.go:601` — `acc.PrivateKey == ""` → skip): такая
/// запись не «частично применяется», она бесполезна целиком.
WarpAccount? warpAccountFromBackup(Map<String, dynamic> j) {
  if (j['type'] != 'wg') return null;
  return WarpAccount.fromJson({
    'priv_key': j['private_key'],
    'peer_pub': j['peer_public'],
    'client_v4': j['client_v4'],
    'client_v6': j['client_v6'],
    'client_id': j['client_id'],
    'account_id': j['account_id'],
    'device_id': j['device_id'],
    'token': j['token'],
    // Канон endpoint не переносит — он либо приехал полем записи, либо
    // берётся дефолтный (`engage.cloudflareclient.com:2408`).
    'endpoint': j['endpoint'] ?? WarpAccount.defaultEndpoint,
    'created_at': j['created_at'],
    'license': j['license'],
    'warp_plus': j['warp_plus'],
    'awg': ?_awgFrom(j['awg']),
  });
}

/// §393 B8 — каноническая запись → [MasqueAccount]; `null` = не разобралось.
MasqueAccount? masqueAccountFromBackup(Map<String, dynamic> j) {
  if (j['type'] != 'masque') return null;
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
    'sni': j['sni'],
    'idle_timeout': j['idle_timeout'],
    'keep_alive': j['keep_alive'],
  });
}

/// AWG-поля записи. Не-Map → `null` (обфускации нет), а не
/// пустой [Awg]: пустой набор полей — это «AWG включён без параметров», и
/// ядро собрало бы из него другой узел.
Map<String, dynamic>? _awgFrom(Object? raw) =>
    raw is Map && raw.isNotEmpty ? raw.cast<String, dynamic>() : null;
