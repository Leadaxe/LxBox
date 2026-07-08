part of '../home_controller.dart';

// ===========================================================================
// §259 — детектор «DNS глушится на direct-маршруте».
//
// Первые [_dnsDetectWindow] секунд после подъёма туннеля пассивно слушаем
// §180 DNS-поток (CcChannel.dnsQueries) и по СТРУКТУРНЫМ признакам событий
// решаем: «живые DNS-запросы через direct массово не доходят». Если да —
// поднимаем флаг HomeState.dnsDirectBlocked → баннер + попап выбора резолвера.
//
// Формула (выверена по коду ядра sing-box-lx, см. spec/tasks/259):
//   is_direct = outbound пуст ИЛИ любой tag ~ "direct"
//               (server.Detour == "" → outbound пуст → это direct-дефолт)
//   is_glush  = source == "failed" && rcode == -1 &&
//               error НЕ содержит ("loopback" | "rejected")
//               (rcode == -1 = RcodeNoAnswer; два локальных отказа отсеяны)
//   fail_domains  = set{ domain : is_glush && is_direct }   // дедуп A/AAAA
//   total_direct  = fail_domains ∪ ok_direct-domains        // ТОЛЬКО direct
//   → blocked = |fail_domains| >= 3 && |fail_domains|/|total_direct| > 30%
//
// ВАЖНО (белые списки): оператор глушит НУЖНОЕ выборочно, разрешённые домены
// (yandex) резолвятся успешно — успехи и провалы вперемешку. Поэтому «есть
// успех → молчим» НЕ годится; разделитель — ПОРОГ + ДОЛЯ среди direct-доменов
// (VPN-домены в знаменатель не берём — баг только про direct-канал).
//
// Пассивно: НИ синтетических запросов, НИ правок ядра. Событий из ядра нет
// без поднятого profilerClient — детектор держит его через refcount
// (acquireProfiler/releaseProfiler), не оборвав активный traffic_profiler.
// Ранний выход: 20 живых успехов при 0 провалов → закрываем окно немедленно.
// ===========================================================================

/// §259 — минимум уникальных мёртвых direct-доменов для вердикта. Порог 3 (не
/// 1-2): 1-2 мёртвых домена — обычный фон (реклама/аналитика законно дохнет).
/// На белых списках оператор глушит нужное выборочно, разрешённые домены
/// (yandex и т.п.) резолвятся успешно — поэтому «есть успех → молчим» НЕ
/// подходит (успехи/провалы вперемешку). Разделитель фона от глушения —
/// ПОРОГ + ДОЛЯ среди direct-доменов (см. [evaluateDnsDirectBlocked]).
const int kDnsDirectFailThreshold = 3;

/// §259 — минимальная доля мёртвых direct-доменов (от всех direct-доменов) для
/// вердикта. Порог отсекает фоновый мусор (реклама/аналитика — законно дохнет),
/// но ловит «заметная часть нужного не резолвится».
const double kDnsDirectFailFraction = 0.30;

/// §259 — ранний выход по здоровью: столько живых успехов при НУЛЕ провалов =
/// сеть точно чистая, окно можно закрыть немедленно (не держать profiler зря).
const int kDnsHealthySuccessEarlyExit = 20;

/// §259 — потолок окна наблюдения. Ранний выход (успех/вердикт) закрывает
/// раньше; потолок — верхняя граница для неоднозначных случаев / простоя.
const Duration _dnsDetectWindow = Duration(seconds: 10);

/// §259 — агрегат наблюдений за окно. Копит уникальные direct-домены (мёртвые
/// и живые) + счётчики для раннего выхода. Мутируется по мере прихода событий;
/// вердикт и ранние выходы — чистые геттеры (тестируются без таймеров).
class DnsDirectStats {
  final Set<String> failDirectDomains = <String>{}; // мёртвые direct (is_glush)
  final Set<String> okDirectDomains = <String>{}; // живые direct (rcode==0)
  int successLiveCount = 0; // все живые успехи (для раннего health-exit)

  /// Все уникальные direct-домены (знаменатель доли). VPN-домены сюда НЕ
  /// входят — баг только про direct-канал.
  int get totalDirectDomains =>
      (failDirectDomains.union(okDirectDomains)).length;

  void ingest(CcDnsQuery q) {
    if (_isDnsSuccessLive(q)) {
      successLiveCount++;
      if (_isDnsDirect(q)) okDirectDomains.add(q.domain);
    }
    if (_isDnsGlushOnDirect(q)) {
      failDirectDomains.add(q.domain);
    }
  }

  /// Ранний выход «сеть здорова»: набрали достаточно живых успехов и НИ одного
  /// мёртвого direct-домена → можно закрыть окно, вердикт заведомо false.
  bool get healthyEarlyExit =>
      failDirectDomains.isEmpty &&
      successLiveCount >= kDnsHealthySuccessEarlyExit;

  /// Вердикт: заметная доля direct-доменов мертва (≥ порога И > доли). На белых
  /// списках срабатывает несмотря на параллельные успехи (yandex резолвится).
  bool get blocked {
    final fails = failDirectDomains.length;
    if (fails < kDnsDirectFailThreshold) return false;
    final total = totalDirectDomains;
    if (total == 0) return false; // защита от /0 (недостижимо при fails>0)
    return fails / total > kDnsDirectFailFraction;
  }
}

/// §259 — чистая оценка вердикта по набору DNS-событий за окно. Вынесена для
/// прямого юнит-тестирования (без CcChannel/таймеров).
///
/// Возвращает `true`, если direct-DNS считается заглушенным:
///   fail_domains >= [kDnsDirectFailThreshold]
///   && fail_domains / total_direct > [kDnsDirectFailFraction]
/// (знаменатель — только direct-домены; VPN-домены игнорируются).
bool evaluateDnsDirectBlocked(Iterable<CcDnsQuery> queries) {
  final stats = DnsDirectStats();
  for (final q in queries) {
    stats.ingest(q);
  }
  return stats.blocked;
}

/// is_direct && is_glush — событие «живой direct-запрос не дошёл (сетевой
/// облом), кроме локальных loopback/rejected».
bool _isDnsGlushOnDirect(CcDnsQuery q) {
  // is_glush: провал без ответа (rcode == -1 = RcodeNoAnswer), исключая
  // заведомо-локальные отказы (loopback / rejected-cached — наш конфиг, не сеть).
  if (q.source != 'failed') return false;
  if (q.rcode != -1) return false;
  final err = q.error.toLowerCase();
  if (err.contains('loopback') || err.contains('rejected')) return false;
  // is_direct: server.Detour == "" → outbound пуст (наш дефолт), ИЛИ явный
  // direct-тег в цепочке.
  return _isDnsDirect(q);
}

/// is_direct: пустой outbound (сервер без detour = direct-дефолт) ИЛИ любой
/// тег в цепочке содержит "direct".
bool _isDnsDirect(CcDnsQuery q) {
  if (q.outbound.isEmpty) return true;
  return q.outbound.any((t) => t.toLowerCase().contains('direct'));
}

/// is_live && rcode == 0 — живой сетевой успех. `is_live` = exchanged/refreshed
/// (НЕ cached/optimistic: старый кэш замаскировал бы живой провал).
bool _isDnsSuccessLive(CcDnsQuery q) {
  if (q.rcode != 0) return false;
  return q.source == 'exchanged' || q.source == 'refreshed';
}

/// §259 — оркестрация окна детектора внутри HomeController.
///
/// Ревью-фиксы (adversarial): двойной `connected` без промежуточного
/// disconnect (cold-reopen swipe-keep: live Started-broadcast + pull через
/// `getVpnStatus`) мог запустить окно ДВАЖДЫ. Старая реализация ставила
/// `_dnsDetectProfilerHeld = true` ПОСЛЕ `await acquireProfiler()` → второй
/// запуск не видел held первого → утечка profiler-ref + осиротевшие sub/timer.
///
/// Здесь — **generation-токен**: каждый `_scheduleDnsDirectDetector` инкремент
/// `_dnsDetectGen` и захватывает свой `gen`. Любой async-continuation (после
/// await) и таймер-callback выполняются, ТОЛЬКО если их `gen == _dnsDetectGen`.
/// Устаревший запуск освобождает свой профайлер-ref и выходит, не трогая
/// актуальные sub/timer. Ровно один активный window в любой момент.
mixin _DnsDirectDetectorMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController / другими частями ---
  HomeState get _state;
  CcChannel get _cc;
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);

  Timer? _dnsDetectTimer;
  StreamSubscription<List<CcDnsQuery>>? _dnsDetectSub;
  final DnsDirectStats _dnsDetectStats = DnsDirectStats();
  int _dnsDetectGen = 0; // ++ на каждый запуск; активен только последний
  int _dnsDetectHeldRefs = 0; // сколько profiler-ref держит детектор (0/1)

  /// Запустить окно детектора после `connected`. Гасит предыдущее окно
  /// (реконнект / двойной connected). No-op, если туннель уже упал.
  Future<void> _scheduleDnsDirectDetector() async {
    _cancelDnsDirectDetector(); // рвёт старый sub/timer, освобождает старый ref
    if (!_state.tunnelUp) return;
    final gen = ++_dnsDetectGen; // наш токен; любой более новый запуск нас гасит
    _resetDnsDetectStats();
    // Держим profilerClient на время окна — иначе §180-события не идут. Через
    // refcount (не оборвём traffic_profiler). Считаем СВОЙ ref для симметрии.
    await _cc.acquireProfiler();
    _dnsDetectHeldRefs++;
    // Устарели, пока ждали acquire (новый запуск / отмена / упал туннель) →
    // откатываем ровно наш ref и выходим, не трогая актуальное окно.
    if (gen != _dnsDetectGen || !_state.tunnelUp) {
      _releaseOwnProfilerRef();
      return;
    }
    _dnsDetectSub = _cc.dnsQueries.listen(
      (batch) {
        if (gen != _dnsDetectGen) return; // stale-стрим (перестраховка)
        for (final q in batch) {
          _dnsDetectStats.ingest(q);
        }
        // Ранний выход «сеть здорова» — закрываем окно, не держим profiler зря.
        if (_dnsDetectStats.healthyEarlyExit) {
          _finishDnsDirectDetector(gen);
        }
      },
      onError: (Object e, StackTrace _) =>
          _addDebug(DebugSource.app, '[dns-detect] stream error: $e'),
    );
    _dnsDetectTimer = Timer(_dnsDetectWindow, () => _finishDnsDirectDetector(gen));
  }

  /// Закрытие окна: оценить, поднять флаг при вердикте, освободить ресурсы.
  /// `gen`-гейт — не даём устаревшему таймеру/раннему-выходу закрыть чужое окно.
  void _finishDnsDirectDetector(int gen) {
    if (gen != _dnsDetectGen) return; // окно уже сменилось/отменено
    final blocked = _dnsDetectStats.blocked;
    _addDebug(
      DebugSource.app,
      '[dns-detect] window closed: fail=${_dnsDetectStats.failDirectDomains.length} '
      'total_direct=${_dnsDetectStats.totalDirectDomains} '
      'success=${_dnsDetectStats.successLiveCount} blocked=$blocked',
    );
    _cancelDnsDirectDetector(); // ++gen внутри → повторный вход невозможен
    if (!_state.tunnelUp) return; // сессия умерла — вердикт не эмитим
    if (blocked && !_state.dnsDirectBlocked) {
      _emit(_state.copyWith(dnsDirectBlocked: true));
    }
  }

  /// Отмена окна (disconnect / реконнект / dispose / смена gen). Инвалидирует
  /// текущий gen, рвёт sub/timer, освобождает удержанный profiler-ref. Флаг
  /// `dnsDirectBlocked` сбрасывается вызывающим (disconnect/connected copyWith).
  void _cancelDnsDirectDetector() {
    _dnsDetectGen++; // инвалидируем все in-flight continuation'ы/таймеры
    _dnsDetectTimer?.cancel();
    _dnsDetectTimer = null;
    _dnsDetectSub?.cancel();
    _dnsDetectSub = null;
    _releaseOwnProfilerRef();
    _resetDnsDetectStats();
  }

  /// Освобождает РОВНО тот profiler-ref, что удержал детектор (0 или 1). Не
  /// уходит в минус — симметрично acquire.
  void _releaseOwnProfilerRef() {
    if (_dnsDetectHeldRefs > 0) {
      _dnsDetectHeldRefs--;
      unawaited(_cc.releaseProfiler());
    }
  }

  void _resetDnsDetectStats() {
    _dnsDetectStats.failDirectDomains.clear();
    _dnsDetectStats.okDirectDomains.clear();
    _dnsDetectStats.successLiveCount = 0;
  }

  /// §259 — «потребить» вердикт: UI показал разовый баннер → гасим флаг, чтобы
  /// он не переподнимался (баннер одноразовый на сессию). Делает флаг
  /// триггер-событием, а не долгоживущим состоянием — попутно закрывает
  /// «флаг застрял true при reloadVpn/смене сети» (ревью §259): состояние
  /// живёт от вердикта до показа, а не бессрочно.
  void consumeDnsDirectBlocked() {
    if (_state.dnsDirectBlocked) {
      _emit(_state.copyWith(dnsDirectBlocked: false));
    }
  }
}
