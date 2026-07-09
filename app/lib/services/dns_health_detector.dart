// ===========================================================================
// §262 — детектор здоровья DNS внутри профайлера (чистая логика).
//
// Живёт в traffic_profiler (recording), скользящее окно [kDnsHealthWindow] по
// уже существующему _globalRollingBuffer событий. Критерий (согласовано):
//   fail_ratio >= 20%  &&  fail_count >= 3  &&  есть_активность_связи
// «DNS массово дохнет, а связь ЖИВА (соединения происходят)» → проблема именно
// в DNS, не в туннеле. При простое (нет conn-событий) — молчим.
//
// Отличие от вырезанного §259: не разовое окно 10с на старте (не ловило
// трафик), а ПОСТОЯННЫЙ детектор в профайлере — видит весь поток, пока идёт
// recording. DNS-события теперь неотделимы от профайлера (§261 — мультиплекс).
//
// Функция нейтральна к типам профайлера (принимает примитивы): kind как
// строка-дискриминатор + возраст события. Склейка с TrafficEvent — в
// traffic_profiler (там TrafficEventKind).
// ===========================================================================

/// §262 — окно наблюдения (скользящее).
const Duration kDnsHealthWindow = Duration(seconds: 30);

/// §262 — минимальная доля fail для вердикта.
const double kDnsHealthFailRatio = 0.20;

/// §262 — минимум fail-событий (страховка от шума: пара мёртвых реклам не в счёт).
const int kDnsHealthMinFails = 3;

/// §262 — класс события для детектора (нейтральный к профайлеру).
enum DnsHealthEventKind {
  dnsResolve, // успешный резолв (в total, не в fail)
  dnsFail, // провал резолва (в total И fail)
  connActivity, // tcp/udp open/close — признак живой связи
  other, // не учитывается
}

/// §262 — один сэмпл для окна: тип + возраст (мс от now).
class DnsHealthSample {
  const DnsHealthSample({required this.kind, required this.ageMs});
  final DnsHealthEventKind kind;
  final int ageMs; // сколько мс назад произошло (now - ts)
}

/// §262 — агрегат за окно. Чистый, тестируется без профайлера.
class DnsHealthStats {
  int _dnsTotal = 0;
  int _dnsFailed = 0;
  bool _connActivity = false;

  int get dnsTotal => _dnsTotal;
  int get dnsFailed => _dnsFailed;
  double get failRatio => _dnsTotal > 0 ? _dnsFailed / _dnsTotal : 0.0;
  bool get hasConnActivity => _connActivity;

  void add(DnsHealthSample s) {
    if (s.ageMs > kDnsHealthWindow.inMilliseconds) return; // вне окна
    switch (s.kind) {
      case DnsHealthEventKind.dnsResolve:
        _dnsTotal++;
      case DnsHealthEventKind.dnsFail:
        _dnsTotal++;
        _dnsFailed++;
      case DnsHealthEventKind.connActivity:
        _connActivity = true;
      case DnsHealthEventKind.other:
        break;
    }
  }

  /// Вердикт: DNS деградировал при живой связи.
  bool get unhealthy =>
      _connActivity &&
      _dnsFailed >= kDnsHealthMinFails &&
      failRatio >= kDnsHealthFailRatio;
}

/// §262 — чистая оценка по набору сэмплов. Вынесена для юнит-тестов.
bool evaluateDnsUnhealthy(Iterable<DnsHealthSample> samples) {
  final stats = DnsHealthStats();
  for (final s in samples) {
    stats.add(s);
  }
  return stats.unhealthy;
}
