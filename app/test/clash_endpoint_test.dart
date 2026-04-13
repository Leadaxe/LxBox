import 'package:boxvpn_app/config/clash_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromConfigJson parses JSON5 with comments (same as saved display config)', () {
    const raw = '''
{
  // experimental
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": ""
    }
  },
  "route": {
    "final": "proxy"  // tail
  }
}
''';
    final ep = ClashEndpoint.fromConfigJson(raw);
    expect(ep, isNotNull);
    expect(ep!.baseUri.toString(), 'http://127.0.0.1:9090');
    expect(ClashEndpoint.routeFinalTag(raw), 'proxy');
  });
}
