import 'package:collection/collection.dart';

/// §454 — ключи `OutboundTLSOptions` ядра (sing-box `option/tls.go`), о
/// которых LxBox не рассуждает гейтами: хранятся в [TlsSpec.passthrough] в
/// форме прибытия и эмитятся как есть. Порядок списка = порядок полей
/// структуры ядра = порядок эмита. Всё, чего тут нет и что не типизировано
/// в [TlsSpec], парсер отбрасывает: ядро отвергает unknown field на ВСЁМ
/// конфиге, а карта tls приходит и из чужого JSON.
///
/// Не в списке намеренно: `ech` (ядро без `with_ech`, D-006/§320 — вычистка
/// с кодом `ech_ignored`). `kernel_tx`/`kernel_rx` ядро принимает только на
/// Linux — Android им и является.
const kTlsPassthroughKeys = <String>[
  'disable_sni',
  'min_version',
  'max_version',
  'cipher_suites',
  'curve_preferences',
  'certificate',
  'certificate_path',
  'client_certificate',
  'client_certificate_path',
  'client_key',
  'client_key_path',
  'fragment',
  'fragment_fallback_delay',
  'record_fragment',
  'kernel_tx',
  'kernel_rx',
];

/// §454 — `Listable[string]` ядра: строка ИЛИ массив строк.
const kTlsListableKeys = <String>{
  'cipher_suites',
  'curve_preferences',
  'certificate',
  'client_certificate',
  'client_key',
};

/// §454 — булевы поля: хранятся только при `true` (omitempty ядра).
const kTlsBoolKeys = <String>{
  'disable_sni',
  'fragment',
  'record_fragment',
  'kernel_tx',
  'kernel_rx',
};

/// §454 — что из allowlist'а принимает naive (`protocol/naive/outbound.go`):
/// остальное ядро отвергает фаталом при создании outbound'а.
const kNaiveTlsPassthroughKeys = <String>{'certificate', 'certificate_path'};

/// §454 — эмит: типизированные поля и сквозные ключи в одном порядке.
/// Для узлов без сквозных ключей совпадает с прежним байт в байт (parity):
/// среди типизированных `alpn` стоит перед `insecure`, как и раньше (в
/// структуре ядра наоборот; identity-хеш §283 сортирует ключи, ему всё
/// равно). Сквозные — на местах структуры ядра относительно соседей.
const _kTlsEmitOrder = <String>[
  'enabled',
  'server_name',
  'alpn',
  'insecure',
  'disable_sni',
  'min_version',
  'max_version',
  'cipher_suites',
  'curve_preferences',
  'certificate',
  'certificate_path',
  'certificate_public_key_sha256',
  'client_certificate',
  'client_certificate_path',
  'client_key',
  'client_key_path',
  'fragment',
  'fragment_fallback_delay',
  'record_fragment',
  'kernel_tx',
  'kernel_rx',
  'utls',
  'reality',
];

const _deepEq = DeepCollectionEquality();

/// TLS-параметры узла. Singleton для «TLS выключен» — `TlsSpec.disabled`.
///
/// `reality != null` — взаимоисключающе с uTLS fingerprint'ом в sing-box
/// (REALITY уже задаёт fingerprint через `utls`, но разные секции).
class TlsSpec {
  final bool enabled;
  final String? serverName;
  final List<String> alpn;
  final bool insecure;
  final String? fingerprint; // utls: chrome, firefox, safari, etc.
  final RealitySpec? reality;

  /// §103/D-078 — пиннинг сертификата (`pinSHA256=` в URI подписки →
  /// `tls.certificate_public_key_sha256`). Base64 SHA-256 публичного ключа;
  /// список — сервер вправе ротировать ключи. ЗАЩИТА ОТ ПОДМЕНЫ: молча
  /// терять параметр значило поднимать соединение слабее, чем обещала
  /// подписка (паритет с лаунчером, outbound_generator.go:496).
  /// В отличие от utls/reality, на QUIC валиден — не срезается.
  final List<String> certificatePublicKeySha256;

  /// §454 — сквозные ключи allowlist'а ядра ([kTlsPassthroughKeys]) в форме
  /// прибытия: `String`, `List<String>` (Listable) или `true`. Появилось из
  /// issue #140: `tls.certificate` (свой корневой CA) терялся на Save —
  /// модель его не знала, а узел на самоподписанном сертификате без него не
  /// поднимается (`insecure` naive отвергает). Ключи только из allowlist'а —
  /// инвариант парсера, конструктор не проверяет.
  final Map<String, Object> passthrough;

  const TlsSpec({
    required this.enabled,
    this.serverName,
    this.alpn = const [],
    this.insecure = false,
    this.fingerprint,
    this.reality,
    this.certificatePublicKeySha256 = const [],
    this.passthrough = const {},
  });

  static const disabled = TlsSpec(enabled: false);

  Map<String, dynamic> toSingbox() => _toSingbox(quic: false);

  /// §282 — uTLS И REALITY поверх QUIC (hysteria2/tuic) в ядре не работают
  /// вообще: их `STDConfig()` возвращает ошибку («unsupported usage for
  /// uTLS»/«…for reality»), а QUIC-путь фолбэчит именно на `STDConfig()`
  /// (аудит ядра SPECS/027-UTLS_OVER_QUIC). Оба блока на QUIC = мёртвая
  /// нода, и `fp`/reality на hy2/tuic — мусор xray-подписок. Для QUIC-эмита
  /// срезаем `utls` и `reality`; server_name/alpn/insecure цел.
  Map<String, dynamic> toSingboxForQuic() => _toSingbox(quic: true);

  Map<String, dynamic> _toSingbox({required bool quic}) {
    if (!enabled) return const {};
    final typed = <String, dynamic>{'enabled': true};
    if (serverName != null && serverName!.isNotEmpty) {
      typed['server_name'] = serverName;
    }
    if (alpn.isNotEmpty) typed['alpn'] = List<String>.from(alpn);
    if (insecure) typed['insecure'] = true;
    if (certificatePublicKeySha256.isNotEmpty) {
      typed['certificate_public_key_sha256'] =
          List<String>.from(certificatePublicKeySha256);
    }
    if (!quic && fingerprint != null && fingerprint!.isNotEmpty) {
      typed['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (!quic && reality != null) {
      typed['reality'] = reality!.toSingbox();
    }
    // §454 — сквозные ключи на QUIC валидны (сертификаты, версии) — в
    // отличие от utls/reality не срезаются. Форма прибытия сохраняется:
    // человек, набравший certificate строкой, увидит после Save строку.
    final m = <String, dynamic>{};
    for (final k in _kTlsEmitOrder) {
      final v = typed[k] ?? passthrough[k];
      if (v == null) continue;
      m[k] = v is List ? List<Object>.from(v) : v;
    }
    return m;
  }

  TlsSpec copyWith({
    bool? enabled,
    String? serverName,
    List<String>? alpn,
    bool? insecure,
    String? fingerprint,
    RealitySpec? reality,
    List<String>? certificatePublicKeySha256,
    Map<String, Object>? passthrough,
  }) =>
      TlsSpec(
        enabled: enabled ?? this.enabled,
        serverName: serverName ?? this.serverName,
        alpn: alpn ?? this.alpn,
        insecure: insecure ?? this.insecure,
        fingerprint: fingerprint ?? this.fingerprint,
        reality: reality ?? this.reality,
        certificatePublicKeySha256:
            certificatePublicKeySha256 ?? this.certificatePublicKeySha256,
        passthrough: passthrough ?? this.passthrough,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TlsSpec &&
          enabled == other.enabled &&
          serverName == other.serverName &&
          _listEq(alpn, other.alpn) &&
          insecure == other.insecure &&
          fingerprint == other.fingerprint &&
          reality == other.reality &&
          // §454 — пин (D-078) и сквозные ключи входят в равенство: два узла
          // с разными сертификатами — разные узлы.
          _listEq(certificatePublicKeySha256,
              other.certificatePublicKeySha256) &&
          _deepEq.equals(passthrough, other.passthrough));

  @override
  int get hashCode => Object.hash(
      enabled,
      serverName,
      Object.hashAll(alpn),
      insecure,
      fingerprint,
      reality,
      Object.hashAll(certificatePublicKeySha256),
      _deepEq.hash(passthrough));
}

class RealitySpec {
  final String publicKey;
  final String shortId;

  const RealitySpec({required this.publicKey, required this.shortId});

  Map<String, dynamic> toSingbox() => {
        'enabled': true,
        'public_key': publicKey,
        'short_id': shortId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RealitySpec &&
          publicKey == other.publicKey &&
          shortId == other.shortId);

  @override
  int get hashCode => Object.hash(publicKey, shortId);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
