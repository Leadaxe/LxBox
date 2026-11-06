import 'package:flutter_test/flutter_test.dart';

import 'engine_test_setup.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'parse_link_as.dart';
import 'package:lxbox/models/node_spec.dart';

/// Round-trip §4 спеки 026: `parseUri(spec.toUri()) ≈ spec`. Сравнение без
/// `id`, `rawSource`, `warnings` — это ephemeral поля, не связанные со значением
/// узла.
void main() {
  setUpAll(loadEngineSections);

  group('Round-trip URI → Spec → URI → Spec', () {
    test('§151 F2 — Trojan ALPN double-encoded (http%252F1.1) → чистый http/1.1', () {
      // Нода из реальной подписки-агрегатора: alpn=http%252F1.1 (двойное
      // percent-кодирование). Uri.queryParameters декодит один раз → 'http%2F1.1';
      // _normalizeAlpn снимает остаточный %2F → 'http/1.1'.
      final a = parseLinkAs<TrojanSpec>(
        'trojan://p@h.example:443?type=ws&security=tls&alpn=http%252F1.1&sni=h.example#N',
      )!;
      expect(a.tls.alpn, ['http/1.1']);
    });

    test('§151 F2 — Trojan ALPN список h2,http/1.1 не ломается', () {
      final a = parseLinkAs<TrojanSpec>(
        'trojan://p@h.example:443?type=ws&security=tls&alpn=h2,http/1.1&sni=h.example#N',
      )!;
      expect(a.tls.alpn, ['h2', 'http/1.1']);
    });

    // SPEC 103 D-016(в)/п.4 — канонический URI-ключ БЕЗ подчёркивания
    // (`upmbps`/`downmbps`): единственная форма, которую понимает и читает,
    // и пишет обратно референсный парсер (Go node_parser_hysteria2.go /
    // shareuri_hysteria2.go — точное совпадение ключа, без queryGetFold).
    // Было закреплено чтение `up_mbps` (с подчёркиванием) — то был неканоничный
    // алиас: `up_mbps`/`down_mbps` это имя ПОЛЯ sing-box outbound JSON, не
    // query-параметр URI; тест обновлён на канон.
    test('§084 H3 — Hysteria2 upmbps/downmbps round-trip', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?upmbps=100&downmbps=200&sni=h#H',
      )!;
      expect(a.upMbps, 100);
      expect(a.downMbps, 200);
      final b = parseLinkAs<Hysteria2Spec>(a.toUri())!;
      expect(b.upMbps, 100, reason: 'upmbps должен пережить toUri round-trip');
      expect(b.downMbps, 200);
    });

    test('§084 H3 — Hysteria2 без Mbps: остаются null', () {
      final a = parseLinkAs<Hysteria2Spec>('hysteria2://secret@h:443?sni=h#H')!;
      expect(a.upMbps, isNull);
      expect(a.downMbps, isNull);
      final b = parseLinkAs<Hysteria2Spec>(a.toUri())!;
      expect(b.upMbps, isNull);
      expect(b.downMbps, isNull);
    });

    // §358 — obfs=gecko молча терялся на эмите: URI-round-trip его сохранял,
    // а emitRaw писал секцию только для salamander. Инвариант ниже —
    // parse → emitRaw, а не только parse → toUri → parse.
    test('§358 — Hysteria2 gecko: тип и размеры пакета доезжают до JSON', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?obfs=gecko&obfs-password=op'
        '&obfs-min-packet-size=100&obfs-max-packet-size=1200&sni=h#H',
      )!;
      expect(a.obfs, 'gecko');
      expect(a.obfsMinPacketSize, 100);
      expect(a.obfsMaxPacketSize, 1200);

      final obfs =
          a.emitRaw(const TemplateVars()).map['obfs'] as Map<String, dynamic>;
      expect(obfs['type'], 'gecko');
      expect(obfs['password'], 'op');
      expect(obfs['min_packet_size'], 100);
      expect(obfs['max_packet_size'], 1200);
    });

    test('§358 — Hysteria2 gecko: round-trip через URI', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?obfs=gecko&obfs-password=op'
        '&obfs-min-packet-size=100&obfs-max-packet-size=1200&sni=h#H',
      )!;
      final b = parseLinkAs<Hysteria2Spec>(a.toUri())!;
      expect(b.obfs, 'gecko');
      expect(b.obfsPassword, 'op');
      expect(b.obfsMinPacketSize, 100);
      expect(b.obfsMaxPacketSize, 1200);
    });

    // §543 — ссылка 3x-ui (genHysteriaLink): security=tls в каждой ссылке,
    // gecko-размеры парой minPacketSize/maxPacketSize (написание v2rayN).
    // Контракт 1.1.54: алиасы читаются, security=tls молчит.
    test('§543 — Hysteria2 gecko из 3x-ui: camelCase-размеры и security=tls',
        () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@example.com:443?security=tls&alpn=h3'
        '&sni=example.com&obfs=gecko&obfs-password=op'
        '&minPacketSize=512&maxPacketSize=1200#3x-ui',
      )!;
      expect(a.obfs, 'gecko');
      expect(a.obfsMinPacketSize, 512);
      expect(a.obfsMaxPacketSize, 1200);
      expect(a.warnings, isEmpty);

      final obfs =
          a.emitRaw(const TemplateVars()).map['obfs'] as Map<String, dynamic>;
      expect(obfs['type'], 'gecko');
      expect(obfs['password'], 'op');
      expect(obfs['min_packet_size'], 512);
      expect(obfs['max_packet_size'], 1200);
    });

    test('§358 — salamander: gecko-размеры в JSON не попадают', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?obfs=salamander&obfs-password=op'
        '&obfs-min-packet-size=100&sni=h#H',
      )!;
      final obfs =
          a.emitRaw(const TemplateVars()).map['obfs'] as Map<String, dynamic>;
      expect(obfs['type'], 'salamander');
      expect(obfs.containsKey('min_packet_size'), isFalse);
      expect(obfs.containsKey('max_packet_size'), isFalse);
    });

    test('§358 — неизвестный тип отброшен: варнинг, в JSON нет obfs', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?obfs=xyz&obfs-password=op&sni=h#H',
      )!;
      expect(a.obfs, isEmpty);
      // §480 — отбраковку объявляет РЕЕСТР, и код приезжает `RegistryWarning`
      // с тем же именем, под которым рукописный класс зарегистрирован в
      // `warning_codes.dart`. Проверяется код, а не класс: классов у кодов
      // реестра не бывает, а исход (obfs пуст, в теле ключа нет) прежний.
      expect(
        a.warnings.whereType<RegistryWarning>().map((w) => w.code),
        contains('obfs_unknown'),
      );
      expect(
        a.emitRaw(const TemplateVars()).map.containsKey('obfs'),
        isFalse,
        reason: 'unknown obfs type = fatal ВСЕГО конфига при старте ядра',
      );
    });

    test('§358 — obfs без пароля отброшен: варнинг, в JSON нет obfs', () {
      final a = parseLinkAs<Hysteria2Spec>(
        'hysteria2://secret@h:443?obfs=gecko&sni=h#H',
      )!;
      expect(a.obfs, isEmpty);
      // §480 — см. выше: код реестра вместо рукописного класса.
      expect(
        a.warnings.whereType<RegistryWarning>().map((w) => w.code),
        contains('obfs_password_missing'),
      );
      expect(
        a.emitRaw(const TemplateVars()).map.containsKey('obfs'),
        isFalse,
        reason: 'missing obfs password = fatal ВСЕГО конфига при старте ядра',
      );
    });

    test('parseUri dispatches — unknown scheme → null', () {
      expect(parseUri('ftp://x'), isNull);
      expect(parseUri('bogus://y'), isNull);
      expect(parseUri(''), isNull);
    });

    test('parseUri — malformed URIs never throw', () {
      expect(parseUri('vless://'), isNull);
      expect(parseUri('vmess://not-base64'), isNull);
      expect(parseUri('ss://@'), isNull);
    });
  });
}
