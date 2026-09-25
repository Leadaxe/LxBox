import 'package:collection/collection.dart';

/// §454 — ключи `OutboundTLSOptions` ядра (sing-box `option/tls.go`), о
/// которых LxBox не рассуждает гейтами: хранятся в [TlsSpec.passthrough] в
/// форме прибытия и эмитятся как есть. Порядок списка = порядок полей
/// структуры ядра = порядок эмита. Всё, чего тут нет и что не типизировано
/// в [TlsSpec], парсер отбрасывает: ядро отвергает unknown field на ВСЁМ
/// конфиге, а карта tls приходит и из чужого JSON.
///
/// §459 (контракт §24.2 п. 7.2) — `ech` в списке ЕСТЬ: посылка D-006 «ядро
/// собрано без `with_ech`» была ложной. `common/tls/ech_tag_stub.go` объявляет
/// сам тег устаревшим (ECH переехал в stdlib и компилируется всегда), а
/// `tls.ech{}` проходит `sing-box check` на пине `v1.14.1-lx.4`. Снимается
/// только URI-параметр `ech=` Xray-формы (§320, `ech_ignored`): он несёт имя
/// чужого публичного пробника, а не ключ этого сервера.
///
/// `kernel_tx`/`kernel_rx` ядро принимает только на Linux — Android им и
/// является.
///
/// §476 — `engine`, `spoof`, `spoof_method` и `handshake_timeout` добавлены
/// стражем круга «тело → модель → emit»: реестр числит их полями
/// `OutboundTLSOptions` (`tls.json`), эмиттер писать их умел, а разбор не
/// читал — узел, сохранённый через JSON-вкладку, терял их молча. Тот же
/// класс, что `tls.certificate` в #140.
const kTlsPassthroughKeys = <String>[
  'disable_sni',
  'engine',
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
  'spoof',
  'spoof_method',
  'kernel_tx',
  'kernel_rx',
  'handshake_timeout',
  'ech',
];

/// §459 — сквозные ключи-ОБЪЕКТЫ: принимается `Map`, хранится и эмитится как
/// есть, приложение внутрь не смотрит (состав полей задаёт ядро:
/// `OutboundECHOptions` — `enabled`, `config` (Listable), `config_path`,
/// `query_server_name`). Не-Map → отброшен молча, как остальные guard'ы
/// allowlist'а.
const kTlsObjectKeys = <String>{'ech'};

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
/// §459 — `ech` naive читает целиком (`protocol/naive/outbound.go:139-155`:
/// `enabled`, `config`, `config_path`, `query_server_name`).
const kNaiveTlsPassthroughKeys = <String>{
  'certificate',
  'certificate_path',
  'ech',
};

/// §454 — эмит: типизированные поля и сквозные ключи в одном порядке.
/// Для узлов без сквозных ключей совпадает с прежним байт в байт (parity):
/// среди типизированных `alpn` стоит перед `insecure`, как и раньше (в
/// структуре ядра наоборот; identity-хеш §283 сортирует ключи, ему всё
/// равно). Сквозные — на местах структуры ядра относительно соседей.
const _kTlsEmitOrder = <String>[
  'enabled',
  // §476 — `engine` стоит в `OutboundTLSOptions` сразу за `enabled`, до
  // `disable_sni`; порядок списка = порядок полей структуры ядра.
  'engine',
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
  // §476 — `spoof`/`spoof_method` стоят в структуре ядра за
  // `record_fragment`, перед kTLS-парой.
  'spoof',
  'spoof_method',
  'kernel_tx',
  'kernel_rx',
  // §459 — в `OutboundTLSOptions` ECH стоит между `handshake_timeout` и
  // `utls`. §476 — `handshake_timeout` теперь сквозной, и ECH встал на своё
  // место структуры: сразу за ним.
  'handshake_timeout',
  'ech',
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

  /// §282 — uTLS и REALITY поверх QUIC (hysteria2/tuic) ядро не поднимает, но
  /// блоки снимает реестр (`tls.json` → `forbidden_for`,
  /// `tls_not_applicable_quic`) на разборе и гард сборки, а не этот метод:
  /// он один на все протоколы и пишет то, что есть в модели.
  Map<String, dynamic> toSingbox() {
    // Карта уходит в тело outbound, а телом после эмита владеет сборщик:
    // post-steps правят его на месте. `const {}` ронял сборку ВСЕГО конфига
    // на QUIC-узле с выключенным TLS («Cannot modify unmodifiable map»).
    if (!enabled) return <String, dynamic>{};
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
    if (fingerprint != null && fingerprint!.isNotEmpty) {
      typed['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (reality != null) {
      typed['reality'] = reality!.toSingbox();
    }
    // §454 — сквозные ключи в форме прибытия: человек, набравший certificate
    // строкой, увидит после Save строку.
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

/// §457 — допустимые значения `tls.reality.key_share` ядра (`option/tls.go`,
/// `common/tls/reality_client.go`). `hybrid` — требовать `X25519MLKEM768`
/// (ClientHello ~1,5–1,9 КБ, два TCP-сегмента), `classical` — вырезать гибрид
/// из `key_share`/`supported_groups` (~0,5 КБ, один сегмент). Любое другое
/// значение ядро не понимает и отвергает outbound целиком = отказ всего
/// конфига, поэтому парсеры отбрасывают поле молча, а не подгоняют.
/// Нормативно для пина ядра lx.4+.
const kRealityKeyShares = <String>{'hybrid', 'classical'};

class RealitySpec {
  final String publicKey;
  final String shortId;

  /// §457 — `null` = не задано: ключ не эмитится, ядро берёт как несёт
  /// отпечаток. Значение — только из [kRealityKeyShares].
  final String? keyShare;

  const RealitySpec({
    required this.publicKey,
    required this.shortId,
    this.keyShare,
  });

  Map<String, dynamic> toSingbox() => {
        'enabled': true,
        'public_key': publicKey,
        // §463 / контракт §24.6 — пустой short_id ядру эквивалентен
        // отсутствующему ключу (`omitempty` в структуре REALITY), и корпус
        // нормирует именно опущенный. Писать `""` значило бы расходиться с
        // лаунчером на ровном месте: REALITY без short_id легален.
        if (shortId.isNotEmpty) 'short_id': shortId,
        // §457 — порядок полей структуры ядра; omitempty: пусто = нет ключа.
        if (keyShare != null && keyShare!.isNotEmpty) 'key_share': keyShare,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RealitySpec &&
          publicKey == other.publicKey &&
          shortId == other.shortId &&
          keyShare == other.keyShare);

  @override
  int get hashCode => Object.hash(publicKey, shortId, keyShare);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
