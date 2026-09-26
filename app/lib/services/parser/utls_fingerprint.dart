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

/// Имена словаря, чья utls-спека несёт key_share `X25519MLKEM768` перед
/// X25519. REALITY-сервер Xray ≥ v26.9.8 (`XTLS/REALITY@8cdf7bf`) без этого
/// шара молча проксирует соединение на камуфляжный сайт (`reality
/// verification failed`).
///
/// SPEC 083 (ядро) — гибрид был только у chrome-имён (`HelloChrome_133`,
/// все шесть ядро схлопывает в `HelloChrome_Auto`).
///
/// SPEC 086/087 (ядро, **с libbox v1.14.1-lx.3**) — форк utls `Leadaxe/utls-lx`
/// добавил пресеты `HelloFirefox_148` и `HelloSafari_26_3` с гибридом
/// (перенос из `refraction-networking/utls`), так что `firefox` и `safari`
/// на этом ядре проходят наравне с chrome. В апстримном `metacubex/utls`
/// гибрида у них нет — набор нормативен ТОЛЬКО для пина lx.3 и новее
/// (`app/android/libbox.version`); при откате ядра назад его надо сузить.
///
/// Остаются без гибрида и под предупреждением: `edge`, `ios`, `android`,
/// `360`, `qq`. Особый случай — `random`: это дефолт URI-парсера при пустом
/// `fp`, один из пяти профилей (гибрид несёт не всегда), в набор не входит и
/// под предупреждение не попадает по отдельному условию; `randomized` —
/// гибрид монетой.
///
/// Эталон Go — `realityHybridUTLSFingerprints` (`node_parser_transport.go`),
/// контракт: код `reality_fp_not_chrome` получают только пять имён выше.
const Set<String> kRealityHybridFingerprints = {
  'chrome',
  'chrome_psk',
  'chrome_psk_shuffle',
  'chrome_padding_psk_shuffle',
  'chrome_pq',
  'chrome_pq_psk',
  // SPEC 086 (ядро lx.2) — Firefox 148.
  'firefox',
  // SPEC 087 (ядро lx.3) — Safari 26.3.
  'safari',
};

/// `true`, если [fp] (уже канонизированный) даёт ClientHello, который
/// принимает REALITY-сервер Xray ≥ v26.9.8. Пустое значение = дефолт ядра
/// (chrome) — тоже `true`.
bool isRealityHybridFingerprint(String fp) =>
    fp.isEmpty || kRealityHybridFingerprints.contains(fp);

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
  // §463 / контракт §24.2 п. 7.1 — `hellorandom*` (включая
  // `hellorandomized`, `hellorandomizedalpn`, `hellorandomizednoalpn`) →
  // `random`.
  //
  // Раньше префикс был `hellorandomized` → `randomized`, а голый
  // `hellorandom` вообще не опознавался и подменялся на `chrome`: подписка
  // просила СЛУЧАЙНЫЙ отпечаток, а получала фиксированный, то есть ровно ту
  // узнаваемую сигнатуру, от которой уходила. Префикс укорочен до
  // `hellorandom`, значение — `random` (как в Go).
  'hellorandom': 'random',
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
  final value = n.value;
  // Контракт 1.1.61: REALITY без uTLS-блока чинит правило реестра
  // `requires[].set` в санитайзере (`{enabled: true}` без отпечатка, код
  // reality_utls_enabled) — своей подстановки `chrome` здесь нет.
  if (n.junk) warnings?.add(UnknownFingerprintWarning(fp));
  // SPEC 083/086/087 — REALITY + отпечаток без гибридного key share: Xray
  // ≥ v26.9.8 такое приветствие отвергает молча. §444 — только
  // предупреждение: значение не меняется ни в ноде, ни в конфиге (отпечаток
  // задаёт подписка, приложение её выбор не переписывает). `random` — дефолт
  // URI-парсера при пустом `fp` (transport.dart), от явного `fp=random`
  // неотличим → без предупреждения; post-step `healUnknownUtlsFingerprints`
  // пишет вместо него `chrome` (наш дефолт).
  if (tls.reality != null &&
      value.isNotEmpty &&
      value != 'random' &&
      !isRealityHybridFingerprint(value)) {
    warnings?.add(RealityFingerprintWarning(value));
  }
  if (value == fp) return tls;
  return tls.copyWith(fingerprint: value);
}
