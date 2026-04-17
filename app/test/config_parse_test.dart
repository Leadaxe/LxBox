import 'dart:convert';

import 'package:lxbox/config/config_parse.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalJsonForSingbox accepts JSON5 comments', () {
    const input = '''
{
  // line comment
  "a": 1,
  "b": [2, 3,], /* block */
}
''';
    final out = canonicalJsonForSingbox(input);
    final map = jsonDecode(out) as Map<String, dynamic>;
    expect(map['a'], 1);
    expect(map['b'], [2, 3]);
  });
}
