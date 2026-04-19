import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/sources.dart';

void main() {
  test('inline profile-title from body comments → meta.profileTitle', () async {
    const body = '''
# profile-title: 🏴 ЧЕРНЫЕ СПИСКИ 🏴 BLACK LISTS | Mobile-150
# profile-update-interval: 5
# Date/Time: 2026-04-18 / 18:17 (Moscow)
# Количество: 150

vless://u@h:443?type=tcp#A
vless://u2@h2:443?type=tcp#B
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta, isNotNull);
    expect(r.meta!.profileTitle,
        '🏴 ЧЕРНЫЕ СПИСКИ 🏴 BLACK LISTS | Mobile-150');
    expect(r.meta!.updateIntervalHours, 5);
    expect(r.nodes, hasLength(2));
  });

  test('non-subscription comment keys ignored', () async {
    const body = '''
# Date/Time: 2026-04-18
# Random note: hello

vless://u@h:443?type=tcp#X
''';
    final r = await parseFromSource(const InlineSource(body));
    // meta должно быть null (ни одного подписочного ключа нет)
    expect(r.meta, isNull);
    expect(r.nodes, hasLength(1));
  });
}
