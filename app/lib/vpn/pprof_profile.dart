/// §207 — описание pprof-профиля: единый источник правды для native-вызова
/// (`pathAndQuery`), имени файла и UI-кнопки. Один libbox `PProfServer`
/// бесплатно отдаёт весь набор `/debug/pprof/*`, поэтому профили различаются
/// только path+query.
class PprofProfile {
  const PprofProfile({
    required this.id,
    required this.label,
    required this.pathAndQuery,
    required this.fileBase,
    required this.isText,
    required this.blockingSeconds,
  });

  /// Имя профиля до `?` (`goroutine`/`heap`/...). Сверяется с native allowlist.
  final String id;

  /// Подпись кнопки в UI.
  final String label;

  /// Готовый `<profile>?<query>` для GET `/debug/pprof/<pathAndQuery>`.
  final String pathAndQuery;

  /// База имени файла (без timestamp/расширения).
  final String fileBase;

  /// true → `.txt` (читаемый дамп), false → `.pb` (`go tool pprof`).
  final bool isText;

  /// >0 → блокирующий профиль (CPU): держит соединение N секунд. 0 = мгновенный.
  final int blockingSeconds;

  String get fileExt => isText ? 'txt' : 'pb';

  /// Набор кнопок Profiling. Порядок = порядок в UI.
  ///
  /// • goroutine `debug=1` — компактные агрегированные счётчики (сколько
  ///   горутин, какой набор растёт); `debug=2` — полные стеки.
  /// • heap `gc=1` — форсит GC перед снимком → в inuse_space только реально
  ///   живой объём (без ещё-не-собранного мусора).
  /// • CPU `profile` — 10s busy-spin; allocs — история аллокаций.
  static const all = <PprofProfile>[
    PprofProfile(
      id: 'goroutine',
      label: 'Goroutines (summary)',
      pathAndQuery: 'goroutine?debug=1',
      fileBase: 'goroutines-summary',
      isText: true,
      blockingSeconds: 0,
    ),
    PprofProfile(
      id: 'goroutine',
      label: 'Goroutines (full stacks)',
      pathAndQuery: 'goroutine?debug=2',
      fileBase: 'goroutines',
      isText: true,
      blockingSeconds: 0,
    ),
    PprofProfile(
      id: 'profile',
      label: 'CPU profile (10s)',
      pathAndQuery: 'profile?seconds=10',
      fileBase: 'cpu',
      isText: false,
      blockingSeconds: 10,
    ),
    PprofProfile(
      id: 'heap',
      label: 'Heap (inuse_space)',
      pathAndQuery: 'heap?gc=1',
      fileBase: 'heap',
      isText: false,
      blockingSeconds: 0,
    ),
    PprofProfile(
      id: 'allocs',
      label: 'Allocations',
      pathAndQuery: 'allocs',
      fileBase: 'allocs',
      isText: false,
      blockingSeconds: 0,
    ),
  ];
}
