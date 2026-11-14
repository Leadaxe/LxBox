import '../contract/body_sanitizer.dart' show coreAtLeast;

/// §729 — первая версия ядра с блоком `lx.sniff_guard` (FEATURE 019 форка).
/// Та же граница в `contract/registry/core_config.json`. Пре-релиз
/// `lx.34-rc.N` младше: если пин встанет на rc, границу двигать на `rc.1`.
const String kSniffGuardMinCore = '1.14.4-lx.34';

const _kTlsMethods = {'record_fragment', 'fragment', 'delay'};
const _kQuicMethods = {'decoy_first_byte', 'delay'};

/// §729 — гейт блока `lx.sniff_guard`, который пишет `config` шаблона: на ядре
/// ниже [kSniffGuardMinCore] неизвестный ключ `lx` валит загрузку конфига,
/// поэтому блок снимается (там разрез ClientHello под `detour` ядро делает
/// само). Версия неизвестна (пустая строка) — гейт не применяется. При обоих
/// методах `off` шаблон блок не пишет вовсе.
void applySniffGuardGate(
  Map<String, dynamic> config, {
  required String coreVersion,
}) {
  final lx = config['lx'];
  if (lx is! Map) return;
  final block = lx['sniff_guard'];
  if (block == null) return;
  if (!coreAtLeast(coreVersion, kSniffGuardMinCore)) {
    lx.remove('sniff_guard');
  }
}

/// §729 — блок `lx.sniff_guard` для probe-конфига по переменным шаблона
/// [vars]: те же методы, фильтр `nodes` и та же карта, что пишет `config` шаблона туннелю,
/// но без `persist` — у probe нет `experimental.cache_file`, а `persist: true`
/// без него ядро отвергает. `null` — писать нечего (оба метода `off` или ядро
/// ниже [kSniffGuardMinCore]).
Map<String, dynamic>? probeSniffGuard(
  Map<String, String> vars, {
  required String coreVersion,
}) {
  if (!coreAtLeast(coreVersion, kSniffGuardMinCore)) return null;
  final tls = vars['sniff_guard_tls'] ?? 'record_fragment';
  final quic = vars['sniff_guard_quic'] ?? 'decoy_first_byte';
  final hasTls = _kTlsMethods.contains(tls);
  final hasQuic = _kQuicMethods.contains(quic);
  if (!hasTls && !hasQuic) return null;
  return <String, dynamic>{
    // Пишется всегда: без ключа ядро (с lx.34) считает фильтр включённым.
    'nodes': {
      'sni_mismatch': (vars['sniff_guard_sni_mismatch'] ?? 'true') == 'true',
    },
    if (hasTls) 'tls': {'method': tls},
    if (hasQuic)
      'quic': {
        'method': quic,
        'detour_type': {'socks': 'never'},
      },
  };
}
