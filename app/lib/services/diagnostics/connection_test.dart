/// §687 — модель активного теста соединения (kernel SPEC 139,
/// `StartConnectionTest`): стадии приходят потоком, стадия с тем же `id`
/// приходит повторно при завершении, последним — итог.
///
/// Словари `kind`, ключей атрибутов и кодов находок у ядра открыты: всё
/// неизвестное показывается как есть, модель ничего не отбрасывает.
library;

/// Глубина теста — значения `ConnectionTestDepth` ядра.
enum ConnectionTestDepth {
  http(0),
  dns(1),
  route(2),
  connect(3);

  const ConnectionTestDepth(this.wire);
  final int wire;
}

/// Исход стадии — значения `ConnectionTestStageResult` ядра.
enum StageResult {
  running,
  ok,
  failed,
  skipped,
  reused,
  noAck,
  notEvaluated;

  /// Неизвестное значение (ядро новее приложения) — как незавершённая стадия
  /// не показываем: считаем «не вычислено».
  static StageResult fromWire(int v) =>
      v >= 0 && v < values.length ? values[v] : StageResult.notEvaluated;
}

/// Уровень находки — значения `ConnectionTestFindingLevel` ядра.
enum FindingLevel {
  info,
  warning,
  problem;

  static FindingLevel fromWire(int v) =>
      v >= 0 && v < values.length ? values[v] : FindingLevel.info;
}

typedef TestAttr = ({String key, String value});

List<TestAttr> _attrs(Object? raw) => [
      if (raw is List)
        for (final a in raw)
          if (a is Map)
            (key: '${a['key'] ?? ''}', value: '${a['value'] ?? ''}'),
    ];

int _int(Object? v) => v is num ? v.toInt() : 0;

class TestStage {
  const TestStage({
    required this.id,
    this.parent = 0,
    this.kind = '',
    this.subject = '',
    this.startMs = 0,
    this.durationMs = 0,
    this.result = StageResult.running,
    this.error = '',
    this.attrs = const [],
  });

  final int id;
  final int parent;
  final String kind;
  final String subject;
  final int startMs;
  final int durationMs;
  final StageResult result;
  final String error;
  final List<TestAttr> attrs;

  /// Значение атрибута по ключу; пусто — нет такого.
  String attr(String key) {
    for (final a in attrs) {
      if (a.key == key) return a.value;
    }
    return '';
  }

  /// Все значения повторяемого атрибута (`answer`, `authority`) по порядку.
  List<String> attrsOf(String key) => [
        for (final a in attrs)
          if (a.key == key) a.value,
      ];

  factory TestStage.fromMap(Map<String, dynamic> m) => TestStage(
        id: _int(m['id']),
        parent: _int(m['parent']),
        kind: '${m['kind'] ?? ''}',
        subject: '${m['subject'] ?? ''}',
        startMs: _int(m['start_ms']),
        durationMs: _int(m['duration_ms']),
        result: StageResult.fromWire(_int(m['result'])),
        error: '${m['error'] ?? ''}',
        attrs: _attrs(m['attrs']),
      );
}

class TestFinding {
  const TestFinding({
    required this.code,
    this.level = FindingLevel.info,
    this.stages = const [],
    this.attrs = const [],
  });

  final String code;
  final FindingLevel level;
  final List<int> stages;
  final List<TestAttr> attrs;

  factory TestFinding.fromMap(Map<String, dynamic> m) => TestFinding(
        code: '${m['code'] ?? ''}',
        level: FindingLevel.fromWire(_int(m['level'])),
        stages: [
          if (m['stages'] is List)
            for (final s in m['stages'] as List) _int(s),
        ],
        attrs: _attrs(m['attrs']),
      );
}

class TestResult {
  const TestResult({
    this.error = '',
    this.rootCause = 0,
    this.findings = const [],
    this.httpStatus = 0,
    this.contentType = '',
    this.bodyBytes = 0,
    this.truncated = false,
    this.elapsedMs = 0,
    this.stagesTruncated = false,
  });

  /// Ошибка самого теста (неверный запрос, `busy`); пусто — тест прошёл.
  final String error;

  /// id стадии корневой причины; 0 — путь пройден.
  final int rootCause;
  final List<TestFinding> findings;
  final int httpStatus;
  final String contentType;
  final int bodyBytes;
  final bool truncated;
  final int elapsedMs;
  final bool stagesTruncated;

  factory TestResult.fromMap(Map<String, dynamic> m) => TestResult(
        error: '${m['error'] ?? ''}',
        rootCause: _int(m['root_cause']),
        findings: [
          if (m['findings'] is List)
            for (final f in m['findings'] as List)
              if (f is Map) TestFinding.fromMap(Map<String, dynamic>.from(f)),
        ],
        httpStatus: _int(m['http_status']),
        contentType: '${m['content_type'] ?? ''}',
        bodyBytes: _int(m['body_bytes']),
        truncated: m['truncated'] == true,
        elapsedMs: _int(m['elapsed_ms']),
        stagesTruncated: m['stages_truncated'] == true,
      );
}

/// Событие потока с нативной стороны: ровно одно из полей заполнено.
class ConnectionTestEvent {
  const ConnectionTestEvent({this.stage, this.result, this.error});

  final TestStage? stage;
  final TestResult? result;

  /// Транспортная ошибка потока или отказ старта.
  final String? error;

  factory ConnectionTestEvent.fromMap(Map<String, dynamic> m) =>
      switch (m['event']) {
        'stage' => ConnectionTestEvent(stage: TestStage.fromMap(m)),
        'result' => ConnectionTestEvent(result: TestResult.fromMap(m)),
        _ => ConnectionTestEvent(error: '${m['message'] ?? 'failed'}'),
      };
}

/// Строка дерева: стадия и её глубина (0 — верхний уровень).
/// `lastPath[i]` — последний ли среди братьев предок на уровне `i`
/// (последний элемент — сама стадия); нужен для линий дерева.
typedef TraceRow = ({TestStage stage, int depth, List<bool> lastPath});

/// Накопитель одного теста. События применяются по порядку прихода.
class ConnectionTestTrace {
  final Map<int, TestStage> _stages = {};
  final List<int> _order = [];
  TestResult? result;

  /// Транспортная ошибка потока (`OnError`): итога не будет.
  String transportError = '';

  bool get finished => result != null || transportError.isNotEmpty;
  bool get isEmpty => _stages.isEmpty && !finished;

  TestStage? stage(int id) => _stages[id];

  void applyStage(TestStage s) {
    if (!_stages.containsKey(s.id)) _order.add(s.id);
    _stages[s.id] = s;
  }

  /// Применить событие потока. После итога события игнорируются.
  void apply(ConnectionTestEvent e) {
    if (finished) return;
    if (e.stage != null) {
      applyStage(e.stage!);
    } else if (e.result != null) {
      result = e.result;
    } else {
      transportError = e.error ?? 'failed';
    }
  }

  /// Дерево в порядке обхода: дети под родителем, внутри уровня — по
  /// `startMs`, при равенстве — по `id` (порядок прихода не годится: стадия
  /// уровня запроса открывается раньше, чем роутер выбирает путь).
  /// Стадия с неизвестным родителем — на верхний уровень.
  List<TraceRow> rows() {
    final children = <int, List<int>>{};
    final roots = <int>[];
    for (final id in _order) {
      final p = _stages[id]!.parent;
      if (p != 0 && _stages.containsKey(p) && p != id) {
        (children[p] ??= []).add(id);
      } else {
        roots.add(id);
      }
    }
    int byStart(int a, int b) {
      final c = _stages[a]!.startMs.compareTo(_stages[b]!.startMs);
      return c != 0 ? c : a.compareTo(b);
    }

    roots.sort(byStart);
    for (final l in children.values) {
      l.sort(byStart);
    }
    final out = <TraceRow>[];
    final seen = <int>{};
    void walk(int id, List<bool> path) {
      if (!seen.add(id)) return;
      out.add((stage: _stages[id]!, depth: path.length - 1, lastPath: path));
      final kids = children[id] ?? const <int>[];
      for (var i = 0; i < kids.length; i++) {
        walk(kids[i], [...path, i == kids.length - 1]);
      }
    }

    for (var i = 0; i < roots.length; i++) {
      walk(roots[i], [i == roots.length - 1]);
    }
    return out;
  }

  /// Стадия корневой причины, если путь оборван.
  TestStage? get rootStage {
    final r = result;
    if (r == null || r.rootCause == 0) return null;
    return _stages[r.rootCause];
  }
}

/// Значок исхода для текстовой выгрузки.
String stageMark(StageResult r) => switch (r) {
      StageResult.running => '…',
      StageResult.ok => '✓',
      StageResult.failed => '✗',
      StageResult.skipped => '-',
      StageResult.reused => '↺',
      StageResult.noAck => '?',
      StageResult.notEvaluated => '∅',
    };

/// Текстовая трасса для Copy: строка на стадию, затем итог и находки.
/// Машинный текст (для issue и поддержки), не переводится.
String traceToText(
  ConnectionTestTrace t, {
  required String link,
  String app = '',
  required ConnectionTestDepth depth,
}) {
  final b = StringBuffer()
    ..writeln('URL check: $link')
    ..writeln('depth: ${depth.name}${app.isEmpty ? '' : ' · app: $app'}')
    ..writeln();
  for (final row in t.rows()) {
    final s = row.stage;
    final pad = '  ' * row.depth;
    final type = s.attr('type');
    final subject = '${type.isEmpty ? '' : ' $type'}'
        '${s.subject.isEmpty ? '' : ' ${s.subject}'}';
    final dur = s.durationMs > 0 ? '  ${s.durationMs} ms' : '';
    b.writeln(
      '${'${s.startMs}'.padLeft(5)}  $pad${stageMark(s.result)} '
      '${s.kind}$subject$dur',
    );
    final attrPad = ' ' * 9 + pad;
    for (final a in s.attrs) {
      b.writeln('$attrPad${a.key}: ${a.value}');
    }
    if (s.error.isNotEmpty) b.writeln('${attrPad}error: ${s.error}');
  }
  b.writeln();
  final r = t.result;
  if (t.transportError.isNotEmpty) {
    b.writeln('stream error: ${t.transportError}');
  } else if (r == null) {
    b.writeln('not finished');
  } else if (r.error.isNotEmpty) {
    b.writeln('test error: ${r.error}');
  } else {
    final root = t.rootStage;
    if (root != null) {
      b.writeln(
        'failed at ${'${root.kind} ${root.subject}'.trim()}: ${root.error}',
      );
    } else if (depth == ConnectionTestDepth.http) {
      b.writeln('HTTP ${r.httpStatus} · ${r.elapsedMs} ms');
    } else {
      b.writeln('completed · ${r.elapsedMs} ms');
    }
    if (r.stagesTruncated) b.writeln('trace truncated');
    for (final f in r.findings) {
      final attrs = f.attrs.map((a) => '${a.key}=${a.value}').join(', ');
      b.writeln(
        'finding ${f.level.name}: ${f.code}'
        '${attrs.isEmpty ? '' : ' ($attrs)'}',
      );
    }
  }
  return b.toString();
}

/// `example.com` → `https://example.com/`; http/https — как есть; иначе null.
String? normalizeCheckUrl(String input) {
  final s = input.trim();
  if (s.isEmpty || s.contains(' ')) return null;
  final hasScheme = s.contains('://');
  final uri = Uri.tryParse(hasScheme ? s : 'https://$s');
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.path.isEmpty ? uri.replace(path: '/').toString() : uri.toString();
}
