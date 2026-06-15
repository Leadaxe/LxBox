import 'dart:math';

/// §127 — генератор псевдо-имён, псевдо-доменов и публичных IP.
///
/// Самостоятельный util, не привязанный к WARP. Назначение —
/// **правдоподобность без узнаваемости**: для junk-обфускации (§126, SIP-шаблон)
/// нужны произносимые user/host, которые НЕ являются захардкоженными
/// RFC-строками (`bob@biloxi.com` — публичный маяк, DPI его знает), не мусор
/// (`7f3a9c`) и не приватные IP (выдают подделку).
///
/// Каждый вызов уникален — [Random.secure] (не seeded → нет общей сигнатуры
/// между юзерами). Генератор НЕ криптографический (это junk, не секрет), но
/// secure-rng выбран чтобы последовательность была непредсказуемой.
class PseudoGen {
  PseudoGen._();

  static final Random _rng = Random.secure();

  /// Согласные без `q x y` (непроизносимые сочетания).
  static const List<String> _cons = [
    'b', 'c', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm',
    'n', 'p', 'r', 's', 't', 'v', 'w', 'z',
  ];

  static const List<String> _vow = ['a', 'e', 'i', 'o', 'u'];

  /// Кластеры в **начале** слога (перед гласной) — произносимые онсеты.
  static const List<String> _onset = [
    'br', 'tr', 'cr', 'dr', 'fr', 'gr', 'pr', 'st', 'sp', 'sk',
    'sl', 'sm', 'sn', 'bl', 'cl', 'fl', 'gl', 'pl', 'tw', 'sh',
  ];

  /// Кластеры в **конце** слова (после гласной) — произносимые коды:
  /// `silk`/`bank`/`song`. `lk` — ТОЛЬКО кода, НЕ онсет.
  static const List<String> _coda = [
    'lk', 'sk', 'st', 'nk', 'sh', 'nt', 'rk', 'ng',
  ];

  static const List<String> _tld = ['com', 'net', 'org', 'io', 'co'];

  static String _pick(List<String> seq) => seq[_rng.nextInt(seq.length)];

  /// `true` с вероятностью `pct`%.
  static bool _chance(int pct) => _rng.nextInt(100) < pct;

  /// Произносимое слоговое слово (6–11 букв), выглядит как реальное имя.
  ///
  /// `word = C + V + [ (60%: C | 40%: ONSET) + V ] × {2..3} + (50%: tail)`,
  /// `tail = 30%: CODA | 70%: C`. Старт всегда `C+V`, длина 6–11.
  static String word() {
    final buf = StringBuffer()
      ..write(_pick(_cons)) // C
      ..write(_pick(_vow)); // V
    final blocks = 2 + _rng.nextInt(2); // 2..3
    for (var i = 0; i < blocks; i++) {
      buf
        ..write(_chance(60) ? _pick(_cons) : _pick(_onset)) // (C|ONSET)
        ..write(_pick(_vow)); // V
    }
    if (_chance(50)) {
      buf.write(_chance(30) ? _pick(_coda) : _pick(_cons)); // tail
    }
    return buf.toString();
  }

  /// Псевдо-username: [word]; с вероятностью **30%** составной `word_word`.
  static String user() {
    final u = word();
    return _chance(30) ? '${u}_${word()}' : u;
  }

  /// `true` если `a.b.x.x` зарезервирован/приватен (не подходит как публичный
  /// VoIP-host — выдаёт подделку). См. §127 acceptance.
  static bool _isReserved(int a, int b) {
    if (a == 0 || a == 10 || a == 127) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a >= 224) return true; // multicast/reserved
    return false;
  }

  /// Публичный IPv4 (исключены приватные/зарезервированные диапазоны).
  static String publicIp() {
    while (true) {
      final a = 1 + _rng.nextInt(223); // 1..223
      final b = _rng.nextInt(256);
      if (_isReserved(a, b)) continue;
      final c = _rng.nextInt(256);
      final d = 1 + _rng.nextInt(254); // 1..254
      return '$a.$b.$c.$d';
    }
  }

  /// Псевдо-SIP-host: домен 2/3-уровневый, sip-поддомен или публичный IP.
  ///
  /// Доли: 30% 3-уровневый домен / 30% публичный IP / 30% 2-уровневый /
  /// 10% sip-поддомен.
  static String host() {
    final r = _rng.nextInt(100);
    if (r < 30) return '${word()}.${word()}.${_pick(_tld)}'; // 3-уровневый
    if (r < 60) return publicIp(); // IP
    if (r < 90) return '${word()}.${_pick(_tld)}'; // 2-уровневый
    return 'sip.${word()}.${_pick(_tld)}'; // sip-поддомен
  }
}
