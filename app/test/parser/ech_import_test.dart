import 'package:flutter_test/flutter_test.dart';

import 'engine_test_setup.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — `ech` из подписки НЕ применяется, только предупреждение.
///
/// Xray-форма `ech=<name>+<resolver>` не несёт ключа: это имя для DNS
/// HTTPS-запроса. Подписки кладут туда публичные ECH-пробники — DEVICE-VERIFIED:
/// DNS отдаёт для `ip.gs` и `encryptedsni.com` ОДИН конфиг с
/// `public_name = cloudflare-ech.com`, тогда как SNI узла
/// `www.ignitelimit.com`. Ключ не от того сервера ⇒ рукопожатие падает.
///
/// Замер (узел 172.67.149.60 `/in-pdr`): с `ech` мёртв, без — 723 мс. NekoBox
/// параметр отбрасывает и держит тот же узел живым на 23 мс.
void main() {
  setUpAll(loadEngineSections);

  Map<String, dynamic> tlsOf(NodeSpec n) =>
      n.emitRaw(const TemplateVars()).map['tls'] as Map<String, dynamic>;

  /// Код предупреждения, а не класс: текст `ech_ignored` живёт в реестре
  /// (`warnings.json`), и на узле он обычным `RegistryWarning`.
  List<RegistryWarning> echWarnings(NodeSpec n) => n.warnings
      .whereType<RegistryWarning>()
      .where((w) => w.code == 'ech_ignored')
      .toList();

  group('ech не попадает в конфиг', () {
    test('name+resolver → ech-блока нет, warning есть', () {
      final n = parseUri(
        'trojan://c206d543-023d-46cc-9d5a-1f0f2fc16323@172.67.149.60:443'
        '?path=%2Fin-pdr&security=tls&insecure=0&host=space.byu.id.yxls.eu.cc'
        '&ech=encryptedsni.com%2Budp%3A%2F%2F8.8.8.8&type=ws'
        '&allowInsecure=0&sni=space.byu.id.yxls.eu.cc#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
      final w = echWarnings(n).single;
      expect(w.path, 'ech');
      expect(w.value, 'encryptedsni.com');
      expect(w.params['query_name'], 'ech');
      expect(w.severity, WarningSeverity.info);
      // Остальное разобрано как обычно — узел рабочий.
      expect(tlsOf(n)['server_name'], 'space.byu.id.yxls.eu.cc');
      expect((n.emitRaw(const TemplateVars()).map['transport'] as Map)['path'],
          '/in-pdr');
    });

    test('bare ech (без resolver) → тоже игнор + warning', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&ech=ip.gs&sni=example.com#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
      expect(echWarnings(n).single.value, 'ip.gs');
    });

    test('пустое / none → ни ech-блока, ни warning', () {
      for (final v in ['', 'none', 'NONE', '  ']) {
        final n = parseUri(
          'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
          '&ech=${Uri.encodeQueryComponent(v)}&sni=example.com#node',
        )!;
        expect(tlsOf(n).containsKey('ech'), isFalse, reason: 'ech=$v');
        expect(echWarnings(n), isEmpty, reason: 'ech=$v');
      }
    });

    test('ech отсутствует → warning не появляется', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx'
        '&security=tls&sni=example.com#node',
      )!;
      expect(echWarnings(n), isEmpty);
    });

    test('echfq не читается совсем (legacy pq-schemes роняет конфиг ядра)', () {
      final n = parseUri(
        'trojan://humanity@104.17.111.8:443?type=ws&host=www.ignitelimit.com'
        '&path=%2Fassignment&security=tls&sni=www.ignitelimit.com'
        '&fp=chrome&echfq=none#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
      expect(echWarnings(n), isEmpty);
    });

    test('vless: то же поведение', () {
      final n = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=ws&path=%2Fx&security=tls&ech=ip.gs&sni=example.com#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
      expect(echWarnings(n), hasLength(1));
    });

    test('REALITY-ветка: ech игнорируется, reality цел', () {
      const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      final n = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=reality&pbk=$pbk&sid=ab&ech=ip.gs&sni=example.com#node',
      )!;
      final tls = tlsOf(n);
      expect(tls.containsKey('ech'), isFalse);
      expect((tls['reality'] as Map)['public_key'], pbk);
      expect(echWarnings(n), hasLength(1));
    });
  });

  group('ALPN проносится дословно (§320 — фильтр по транспорту откачен)', () {
    test('ws + h3,h2,http/1.1 → список как в ссылке', () {
      final n = parseUri(
        'trojan://humanity@45.130.125.158:443?path=%2Fassignment'
        '&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&host=www.ignitelimit.com'
        '&type=ws&sni=www.ignitelimit.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['h3', 'h2', 'http/1.1']);
    });

    test('ws + только h2 → h2 остаётся', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&alpn=h2&sni=example.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['h2']);
    });
  });

  // §459 (контракт §24.2 п. 7.2) — посылка D-006 «ядро без with_ech» ложна:
  // ECH компилируется всегда (common/tls/ech_tag_stub.go), tls.ech{} проходит
  // sing-box check. Тело из JSON пропускается, URI-параметр `ech=` Xray-формы
  // по-прежнему снимается — он несёт имя чужого публичного пробника.
  group('§459 разделение: тело проходит, URI снимается', () {
    test('sing-box JSON: tls.ech{} доезжает до эмита, URI-ветка — нет', () {
      final fromJson = parseSingboxEntry({
        'type': 'vless',
        'tag': 'v',
        'server': 'b.example',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'tls': {
          'enabled': true,
          'server_name': 'b.example',
          'ech': {'enabled': true, 'config': ['pem-block']},
        },
      })!;
      expect(tlsOf(fromJson)['ech'],
          {'enabled': true, 'config': ['pem-block']});
      expect(echWarnings(fromJson), isEmpty,
          reason: 'тело узла — не URI-параметр, предупреждать не о чем');

      final fromUri = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@b.example:443'
        '?type=tcp&security=tls&sni=b.example'
        '&ech=ip.gs%2Budp%3A%2F%2F8.8.8.8#node',
      )!;
      expect(tlsOf(fromUri).containsKey('ech'), isFalse);
      expect(echWarnings(fromUri), hasLength(1));
    });
  });

  group('round-trip', () {
    test('toUri не изобретает ech', () {
      final uri = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&ech=ip.gs%2Budp%3A%2F%2F8.8.8.8&sni=example.com#node',
      )!
          .toUri();
      expect(Uri.parse(uri).queryParameters.containsKey('ech'), isFalse);
    });
  });
}
