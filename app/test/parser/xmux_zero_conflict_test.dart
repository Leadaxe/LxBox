import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../contract_paths.dart';

/// §597 — `conflicts` xmux судится по значению с ОБЕИХ сторон: декларант
/// `max_concurrency` в нулевой форме (`"0"`, `"0-0"`, `0`, `0.0`) — «не
/// задано», конфликта с `max_connections` нет.

/// Узел корпуса `73-github-full` (`path=/api/v2/session/open`,
/// `host=shprcdn.net`) дословно.
const _corpusLink =
    'vless://a0556b40-03f5-425a-8408-3dd07ab06129@94.139.255.254:5443?encryption=none&extra=%7B%22host%22%3A%22%22%2C%22path%22%3A%22%2Fx%22%2C%22mode%22%3A%22stream-one%22%2C%22headers%22%3Anull%2C%22xPaddingBytes%22%3A%220%22%2C%22xPaddingObfsMode%22%3Afalse%2C%22xPaddingKey%22%3A%22%22%2C%22xPaddingHeader%22%3A%22%22%2C%22xPaddingPlacement%22%3A%22%22%2C%22xPaddingMethod%22%3A%22%22%2C%22uplinkHTTPMethod%22%3A%22%22%2C%22sessionIDPlacement%22%3A%22%22%2C%22sessionIDKey%22%3A%22%22%2C%22sessionIDTable%22%3A%22%22%2C%22sessionIDLength%22%3A%220%22%2C%22seqPlacement%22%3A%22%22%2C%22seqKey%22%3A%22%22%2C%22uplinkDataPlacement%22%3A%22%22%2C%22uplinkDataKey%22%3A%22%22%2C%22uplinkChunkSize%22%3A%220%22%2C%22noGRPCHeader%22%3Afalse%2C%22noSSEHeader%22%3Afalse%2C%22scMaxEachPostBytes%22%3A%220%22%2C%22scMinPostsIntervalMs%22%3A%220%22%2C%22scMaxBufferedPosts%22%3A0%2C%22scStreamUpServerSecs%22%3A%220%22%2C%22serverMaxHeaderBytes%22%3A0%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%220%22%2C%22maxConnections%22%3A%224-8%22%2C%22cMaxReuseTimes%22%3A%22256-512%22%2C%22hMaxRequestTimes%22%3A%220%22%2C%22hMaxReusableSecs%22%3A%22900-1500%22%2C%22hKeepAlivePeriod%22%3A0%7D%2C%22downloadSettings%22%3Anull%2C%22extra%22%3Anull%7D&fp=firefox&host=shprcdn.net&mode=stream-one&path=%2Fapi%2Fv2%2Fsession%2Fopen&pbk=5hhzoP441DrGa2l5YlwizPSA5chdY2VjRP7CiEfLLA0&security=reality&sid=eea4ab7bddaeea39&sni=shprcdn.net&type=xhttp#t';

/// Тот же узел с подставляемым объектом `xmux` в `extra`.
String _link(String xmux) =>
    'vless://a0556b40-03f5-425a-8408-3dd07ab06129@94.139.255.254:5443'
    '?encryption=none&security=reality&sni=shprcdn.net&fp=firefox'
    '&pbk=5hhzoP441DrGa2l5YlwizPSA5chdY2VjRP7CiEfLLA0&sid=eea4ab7bddaeea39'
    '&type=xhttp&mode=stream-one&host=shprcdn.net&path=/api/v2/session/open'
    '&extra=${Uri.encodeQueryComponent('{"xmux":$xmux}')}#t';

List<RegistryWarning> _conflicts(NodeSpec n) => [
      for (final w in n.warnings.whereType<RegistryWarning>())
        if (w.code == 'field_conflict') w,
    ];

Map _xmux(NodeSpec n) =>
    (n.emit(TemplateVars.empty).map['transport'] as Map)['xmux'] as Map;

void main() {
  setUpAll(loadTestRegistry);

  test('узел корпуса: maxConcurrency "0" — конфликта нет, эмит прежний', () {
    final node = parseAll(decode(_corpusLink)).single;
    expect(_conflicts(node), isEmpty);
    final xmux = _xmux(node);
    expect(xmux['max_connections'], '4-8');
    expect(xmux.containsKey('max_concurrency'), isFalse);
  });

  for (final zero in ['"0"', '"0-0"', '"00"', '0', '0.0', '[0,0]']) {
    test('maxConcurrency $zero + maxConnections "4-8" — конфликта нет', () {
      final node = parseAll(decode(
              _link('{"maxConcurrency":$zero,"maxConnections":"4-8"}')))
          .single;
      expect(_conflicts(node), isEmpty);
      final xmux = _xmux(node);
      expect(xmux['max_connections'], '4-8');
      expect(xmux.containsKey('max_concurrency'), isFalse);
    });
  }

  test('настоящий конфликт "16-32" + "4-8" по-прежнему field_conflict', () {
    final node = parseAll(decode(
            _link('{"maxConcurrency":"16-32","maxConnections":"4-8"}')))
        .single;
    final c = _conflicts(node);
    expect(c, hasLength(1));
    expect(c.single.path, 'transport.xmux.max_concurrency');
    final xmux = _xmux(node);
    expect(xmux['max_connections'], '4-8');
    expect(xmux.containsKey('max_concurrency'), isFalse);
  });

  test('ноль у соседа: "16-32" + maxConnections "0" — конфликта нет', () {
    final node = parseAll(decode(
            _link('{"maxConcurrency":"16-32","maxConnections":"0"}')))
        .single;
    expect(_conflicts(node), isEmpty);
    expect(_xmux(node)['max_concurrency'], '16-32');
  });
}
