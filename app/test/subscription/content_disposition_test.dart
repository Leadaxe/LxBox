import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/sources.dart';

// content-disposition служит fallback'ом для имени подписки, когда провайдер
// не ставит кастомный profile-title — многие стандартные админки (Marzban,
// 3x-ui, XrayR) кладут имя именно туда. Проверяем через inline-whitelist.
void main() {
  test('content-disposition with quoted filename → profileTitle', () async {
    const body = '''
# content-disposition: attachment; filename="My VPN Premium.txt"

vless://u@h:443?type=tcp#A
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta?.profileTitle, 'My VPN Premium');
  });

  test('content-disposition with unquoted filename → profileTitle', () async {
    const body = '''
# content-disposition: inline; filename=simple.conf

vless://u@h:443?type=tcp#A
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta?.profileTitle, 'simple');
  });

  test('RFC 5987 filename*=UTF-8 percent-encoded → decoded', () async {
    // filename*=UTF-8''%D0%9C%D0%BE%D0%B8%20VPN  →  "Мои VPN"
    const body = '''
# content-disposition: attachment; filename*=UTF-8''%D0%9C%D0%BE%D0%B8%20VPN

vless://u@h:443?type=tcp#A
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta?.profileTitle, 'Мои VPN');
  });

  test('profile-title имеет приоритет над content-disposition', () async {
    const body = '''
# profile-title: Liberty EU
# content-disposition: attachment; filename="Fallback Name.txt"

vless://u@h:443?type=tcp#A
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta?.profileTitle, 'Liberty EU');
  });

  test('content-disposition без filename → title не выставляется', () async {
    const body = '''
# content-disposition: attachment

vless://u@h:443?type=tcp#A
''';
    final r = await parseFromSource(const InlineSource(body));
    expect(r.meta?.profileTitle, isNull);
  });

  test('.yaml / .yml / .json / .conf extensions стрипаются', () async {
    for (final filename in ['sub.yaml', 'sub.yml', 'sub.json', 'sub.conf']) {
      final body = '''
# content-disposition: attachment; filename="$filename"

vless://u@h:443?type=tcp#A
''';
      final r = await parseFromSource(InlineSource(body));
      expect(r.meta?.profileTitle, 'sub', reason: 'failed for $filename');
    }
  });
}
