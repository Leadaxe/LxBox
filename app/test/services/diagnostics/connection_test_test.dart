import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/diagnostics/connection_test.dart';

ConnectionTestEvent _stage(int id, int parent, String kind, int result,
        {String subject = '', String error = '', int dur = 0}) =>
    ConnectionTestEvent.fromMap({
      'event': 'stage',
      'id': id,
      'parent': parent,
      'kind': kind,
      'subject': subject,
      'start_ms': id,
      'duration_ms': dur,
      'result': result,
      'error': error,
      'attrs': [
        {'key': 'rule', 'value': 'route[1]'},
      ],
    });

void main() {
  test('stages build a tree; completion replaces the running stage', () {
    final t = ConnectionTestTrace()
      ..apply(_stage(1, 0, 'route', 0))
      ..apply(_stage(2, 0, 'dial', 0, subject: 'vless-nl'))
      ..apply(_stage(3, 2, 'lookup', 1, subject: 'nl.example.net'))
      ..apply(_stage(4, 3, 'dns', 1))
      ..apply(_stage(5, 2, 'tcp_connect', 2, error: 'timeout'))
      ..apply(_stage(1, 0, 'route', 1, dur: 3));

    final rows = t.rows();
    expect(rows.map((r) => (r.stage.id, r.depth)).toList(),
        [(1, 0), (2, 0), (3, 1), (4, 2), (5, 1)]);
    expect(t.stage(1)!.result, StageResult.ok);
    expect(t.stage(1)!.durationMs, 3);
    expect(t.stage(5)!.result, StageResult.failed);
    expect(t.finished, isFalse);
  });

  test('result finishes the trace; later events are ignored', () {
    final t = ConnectionTestTrace()
      ..apply(_stage(1, 0, 'tcp_connect', 2, error: 'refused'))
      ..apply(ConnectionTestEvent.fromMap({
        'event': 'result',
        'root_cause': 1,
        'findings': [
          {
            'code': 'failed_after_no_ack',
            'level': 2,
            'stages': [1],
            'attrs': <Map>[],
          },
        ],
      }))
      ..apply(_stage(2, 0, 'http', 1));

    expect(t.finished, isTrue);
    expect(t.rows(), hasLength(1));
    expect(t.rootStage!.kind, 'tcp_connect');
    expect(t.result!.findings.single.level, FindingLevel.problem);
    final text = traceToText(t,
        link: 'https://a.example/', depth: ConnectionTestDepth.http);
    expect(text, contains('✗ tcp_connect'));
    expect(text, contains('error: refused'));
    expect(text, contains('failed at tcp_connect: refused'));
    expect(text, contains('finding problem: failed_after_no_ack'));
  });

  test('unknown parent goes to the top level; unknown result is tolerated',
      () {
    final t = ConnectionTestTrace()..apply(_stage(7, 99, 'wake', 42));
    expect(t.rows().single.depth, 0);
    expect(t.stage(7)!.result, StageResult.notEvaluated);
  });

  test('siblings are ordered by start time, not by arrival', () {
    ConnectionTestEvent at(int id, int start) => ConnectionTestEvent.fromMap(
        {'event': 'stage', 'id': id, 'kind': 'k$id', 'start_ms': start});
    final t = ConnectionTestTrace()
      ..apply(at(1, 90)) // target_tls открылась раньше по приходу
      ..apply(at(2, 10))
      ..apply(at(3, 10));
    expect(t.rows().map((r) => r.stage.id).toList(), [2, 3, 1]);
  });

  test('stream error ends the trace', () {
    final t = ConnectionTestTrace()
      ..apply(ConnectionTestEvent.fromMap({'event': 'error', 'message': 'x'}));
    expect(t.finished, isTrue);
    expect(t.transportError, 'x');
  });

  test('normalizeCheckUrl', () {
    expect(normalizeCheckUrl('example.com'), 'https://example.com/');
    expect(normalizeCheckUrl(' http://a.b/c?d=1 '), 'http://a.b/c?d=1');
    expect(normalizeCheckUrl('https://a.b'), 'https://a.b/');
    expect(normalizeCheckUrl('ftp://a.b/'), isNull);
    expect(normalizeCheckUrl(''), isNull);
    expect(normalizeCheckUrl('a b'), isNull);
  });

  test('lastPath marks the last sibling at every level', () {
    final t = ConnectionTestTrace()
      ..apply(_stage(1, 0, 'route', 1))
      ..apply(_stage(2, 0, 'dial', 1))
      ..apply(_stage(3, 2, 'lookup', 1))
      ..apply(_stage(4, 3, 'dns', 1))
      ..apply(_stage(5, 2, 'tcp_connect', 1));

    String mark(List<bool> p) => p.map((l) => l ? 'L' : '+').join();
    expect(t.rows().map((r) => '${r.stage.id}:${mark(r.lastPath)}').toList(),
        ['1:+', '2:L', '3:L+', '4:L+L', '5:LL']);
  });

  test('attrsOf returns every repeated attribute in order', () {
    final s = TestStage.fromMap({
      'id': 1,
      'kind': 'app_dns',
      'attrs': [
        {'key': 'type', 'value': 'A'},
        {'key': 'answer', 'value': 'CNAME 300 a.example.'},
        {'key': 'answer', 'value': 'a.example. A 300 192.0.2.1'},
        {'key': 'source', 'value': 'cache'},
      ],
    });
    expect(s.attrsOf('answer'),
        ['CNAME 300 a.example.', 'a.example. A 300 192.0.2.1']);
    expect(s.attrsOf('authority'), isEmpty);
    expect(s.attr('source'), 'cache');
  });
}
