import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';

/// §281 — нормализация uTLS fingerprint к словарю ядра.
///
/// КОРЕНЬ БАГА: публичные подписки генерятся под Xray, который принимает
/// сырые имена uTLS-библиотеки (`hellochrome_120`, `hellofirefox_auto`, …)
/// и любой регистр (`QQ`). sing-box матчит fingerprint СТРОГО по словарю
/// (`uTLSClientHelloID`, common/tls/utls_client.go, case-sensitive switch) —
/// неизвестное значение = «unknown uTLS fingerprint» при конструировании
/// outbound в box.New = fatal ВСЕГО конфига на старте. Одна битая нода из
/// подписки роняет весь VPN (тот же класс, что pbk у §169 / detour у §172).
///
/// Правило: известные xray-псевдонимы канонизируются МОЛЧА (синоним, не
/// деградация); неопознанный мусор → `chrome` + warning на ноде (fingerprint
/// — чисто клиентская маскировка, сервер про неё не знает: нода почти
/// наверняка рабочая, выкидывать = терять живой сервер).

/// Зеркало словаря ядра (`uTLSClientHelloID`). Единственный allow-list в
/// Dart-коде; при бампе ядра сверять с common/tls/utls_client.go.
const Set<String> kUtlsFingerprints = {
  'chrome',
  'chrome_psk',
  'chrome_psk_shuffle',
  'chrome_padding_psk_shuffle',
  'chrome_pq',
  'chrome_pq_psk',
  'firefox',
  'edge',
  'safari',
  '360',
  'qq',
  'ios',
  'android',
  'random',
  'randomized',
};

/// Xray-псевдонимы — сырые имена uTLS-библиотеки, матчим по префиксу
/// (`hellochrome_120`, `hellochrome_106_shuffle`, `hellorandomizedalpn` …).
const Map<String, String> _xrayAliasPrefixes = {
  'hellochrome': 'chrome',
  'hellofirefox': 'firefox',
  'helloedge': 'edge',
  'hellosafari': 'safari',
  'hello360': '360',
  'helloqq': 'qq',
  'helloios': 'ios',
  'helloandroid': 'android',
  'hellorandomized': 'randomized',
};

/// Канонизация сырого значения. `junk` = значение не опознано и заменено
/// на `chrome` (кандидат на warning). Пустая/пробельная строка → пустая
/// (не junk): семантику пустого fp решает вызывающий парсер.
({String value, bool junk}) normalizeUtlsFingerprintValue(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return (value: '', junk: false);
  if (kUtlsFingerprints.contains(s)) return (value: s, junk: false);
  for (final e in _xrayAliasPrefixes.entries) {
    if (s.startsWith(e.key)) return (value: e.value, junk: false);
  }
  return (value: 'chrome', junk: true);
}

/// Обёртка уровня [TlsSpec]: канонизирует fingerprint; мусор дополнительно
/// плюсует [UnknownFingerprintWarning] в аккумулятор ноды (`warnings == null`
/// — молчаливый режим, для путей без warnings-аккумулятора).
TlsSpec normalizeTlsFingerprint(TlsSpec tls, List<NodeWarning>? warnings) {
  if (!tls.enabled) return tls;
  final fp = tls.fingerprint ?? '';
  final n = normalizeUtlsFingerprintValue(fp);
  var value = n.value;
  // REALITY требует uTLS-блок («uTLS is required by reality client» — fatal
  // при создании outbound), а TlsSpec.toSingbox не эмитит utls при пустом
  // fingerprint. Пустое/пробельное значение при reality → chrome (дефолт
  // ядра для пустой строки).
  if (value.isEmpty && tls.reality != null) value = 'chrome';
  if (n.junk) warnings?.add(UnknownFingerprintWarning(fp));
  if (value == fp) return tls;
  return tls.copyWith(fingerprint: value);
}
