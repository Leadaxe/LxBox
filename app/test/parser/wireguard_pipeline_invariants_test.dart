import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/warp/warp_account.dart';

/// §472 шаг 7, раздел 3 спеки — инварианты переезда wireguard/AWG на конвейер.
///
/// Снимок охватывает ТРИ входа одной схемы: ссылку (включая `awg://<base64
/// .conf>`), текст INI и узлы, которые строит фабрика WARP
/// (`WarpAccount.toWireguardUri` / `toWireguardConf`) — у пользователей они
/// самые массовые.
/// §480 W4 — РЕЕСТР из ЗЕРКАЛА: вендоренной копии на CI нет, и под её гейтом
/// файл пропускался бы целиком. КОРПУС остаётся за копией — в зеркале его нет.
const _contractRoot = 'assets/contract';
const _corpusRoot = 'contract';

/// Снимок, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/wireguard/pipeline_identity_before.json';

const _priv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
const _pub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_corpusRoot/corpus/uri/wireguard')
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (!f.path.endsWith('.uri')) continue;
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      out.add(t);
    }
  }
  return out;
}

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

WarpAccount _warpAccount({Awg? awg, bool plus = false}) => WarpAccount(
      privKey: _priv,
      peerPub: _pub,
      clientV4: '172.16.0.2',
      clientV6: '2606:4700:110:8a1b:c0de:cafe:babe:1234',
      clientId: 'q4Ub',
      accountId: 'acc',
      deviceId: 'dev',
      token: 'tok',
      endpoint: 'engage.cloudflareclient.com:2408',
      createdAt: '2026-01-01T00:00:00Z',
      warpPlus: plus,
      awg: awg,
    );

/// Тот же набор AWG-полей, которым снимался эталон.
final _warpAwg = Awg(const {
  'jc': 4,
  'jmin': 40,
  'jmax': 70,
  's1': 50,
  's2': 100,
  'h1': 1234567,
  'h2': 2345678,
  'h3': 3456789,
  'h4': 4567890,
  'i1': '<b 0xdeadbeef><r 100>',
});

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'зеркало реестра не найдено';
  final hasCorpus =
      Directory('$_corpusRoot/corpus/uri/wireguard').existsSync();
  final skipCorpus = hasCorpus ? skip : 'корпус не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§472 инвариант 4 — identity wireguard/AWG не меняется', () {
    test('ссылки корпуса и app/test дают прежние хеш, тег и тело', () {
      final before = _identityBefore();
      final uriCases = {
        for (final e in before.entries)
          if (e.value.containsKey('uri')) e.key: e.value,
      };
      expect(uriCases, hasLength(greaterThan(70)),
          reason: 'снимок похудел — проверьте, не срезан ли корпус');
      for (final e in uriCases.entries) {
        final want = e.value['identity'] as String?;
        final spec = parseUri(e.value['uri'] as String);
        if (want == null) {
          expect(spec, isNull, reason: 'кейс ${e.key} стал разбираться');
          continue;
        }
        expect(spec, isNotNull, reason: 'кейс ${e.key} перестал разбираться');
        expect(legacyNodeIdentityHash(spec!), want,
            reason: 'identity кейса ${e.key} изменилась: у пользователей '
                'слетят выбор узла, отключения и цепочки');
        expect(spec.tag, e.value['tag'], reason: 'тег кейса ${e.key}');
        expect(jsonEncode(spec.emit(TemplateVars.empty).map),
            jsonEncode(e.value['body']),
            reason: 'тело кейса ${e.key} (эталоны сравниваются БАЙТ В БАЙТ, '
                'включая порядок ключей)');
      }
    }, skip: skip);

    test('INI-входы дают прежние хеш, тег и тело', () {
      // §456 — INI остаётся ИСТОЧНИКОМ: `rawSource` это текст файла байт в
      // байт, а тег берётся из комментария под `[Peer]`, затем из nameHint.
      final before = _identityBefore();
      final iniCases = {
        for (final e in before.entries)
          if (e.key.startsWith('ini:')) e.key: e.value,
      };
      expect(iniCases, hasLength(greaterThan(10)));
      for (final e in iniCases.entries) {
        final ini = e.value['ini'] as String;
        final hint = e.key.endsWith('/nohint') ? null : 'file-hint';
        final spec = parseWireguardIni(ini, nameHint: hint);
        expect(spec, isNotNull, reason: 'кейс ${e.key} перестал разбираться');
        expect(legacyNodeIdentityHash(spec!), e.value['identity'],
            reason: 'identity кейса ${e.key}');
        expect(spec.tag, e.value['tag'], reason: 'тег кейса ${e.key}');
        expect(spec.rawSource, ini,
            reason: '§456 — источник INI-узла это сам INI, байт в байт');
        expect(jsonEncode(spec.emit(TemplateVars.empty).map),
            jsonEncode(e.value['body']),
            reason: 'тело кейса ${e.key}');
      }
    }, skip: skip);

    test('узлы фабрик WARP не сдвинулись ни в одной комбинации', () {
      // WG-узлы WARP у пользователей самые массовые. Фабрик две: короткий
      // URI для plain WARP и `.conf` для обфусцированного (§126).
      final before = _identityBefore();
      var checked = 0;
      for (final plus in const [false, true]) {
        for (final res in const [true, false]) {
          for (final ka in const <int?>[null, 25]) {
            final uri = _warpAccount(plus: plus)
                .toWireguardUri(includeReserved: res, persistentKeepalive: ka);
            final byUri = parseUri(uri)!;
            final wantUri = before['warp_uri:$plus/$res/$ka']!;
            expect(legacyNodeIdentityHash(byUri), wantUri['identity'],
                reason: 'identity WARP-URI plus=$plus res=$res ka=$ka');
            expect(byUri.tag, wantUri['tag']);

            final conf = _warpAccount(plus: plus, awg: _warpAwg)
                .toWireguardConf(includeReserved: res, persistentKeepalive: ka);
            final byConf = parseWireguardIni(conf,
                nameHint: WarpAccount.nodeTag(warpPlus: plus, hasAwg: true))!;
            final wantConf = before['warp_conf:$plus/$res/$ka']!;
            expect(legacyNodeIdentityHash(byConf), wantConf['identity'],
                reason: 'identity WARP-.conf plus=$plus res=$res ka=$ka');
            expect(byConf.tag, wantConf['tag']);
            // Обфусцированный WARP это AmneziaWG: потолок MTU обязан стоять.
            expect(byConf.mtu, 1280);
            checked += 2;
          }
        }
      }
      expect(checked, 16);
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус wireguard переживает круг', () {
      var checked = 0;
      for (final u in _corpusUris()) {
        final a = parseUri(u);
        if (a == null) continue;
        // `awg://<base64 .conf>` (§450) — форма БЕЗ обратного эмиттера:
        // `toUriWireguard` всегда пишет каноническую `key@host:port?…`.
        // Круг при этом сохраняет и тело, и identity — расходится только
        // текст ссылки, и проверяется это ниже как свойство эмиссии.
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'круг потерял узел: $u');
        expect(b!.emit(TemplateVars.empty).map, a.emit(TemplateVars.empty).map,
            reason: 'круг изменил тело: $u');
        expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
            reason: 'круг изменил identity: $u');
        checked++;
      }
      // Круг проходят ВСЕ разбираемые кейсы, без исключений.
      expect(checked, greaterThan(35));
    }, skip: skipCorpus);

    test('INI переживает круг через toUri(), тело и identity те же', () {
      const ini = '[Interface]\nPrivateKey = $_priv\n'
          'Address = 10.2.0.2/32\nMTU = 1420\nJc = 4\nJmin = 40\nJmax = 70\n\n'
          '[Peer]\nPublicKey = $_pub\n'
          'AllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n';
      final a = parseWireguardIni(ini)!;
      final b = parseUri(a.toUri())!;
      expect(b.emit(TemplateVars.empty).map, a.emit(TemplateVars.empty).map);
      expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a));
      // Источник у INI-узла остаётся INI (§456), у пересобранного — ссылка.
      expect(a.rawSource, ini);
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 AWG-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'wireguard://$_priv@h$i.example:51820?publickey=$_pub'
              '&address=10.0.0.2/32&allowedips=0.0.0.0/0,::/0&mtu=1420'
              '&keepalive=25&jc=4&jmin=10&jmax=50&s1=55&s2=42'
              '&h1=1&h2=2&h3=3&h4=4#node$i',
      ];

      for (var i = 0; i < 200; i++) {
        parseUri(uris[i]);
      }

      final nodes = <NodeSpec>[];
      var best = 1 << 30;
      for (var rep = 0; rep < 3; rep++) {
        nodes.clear();
        final sw = Stopwatch()..start();
        for (final u in uris) {
          final s = parseUri(u);
          if (s != null) nodes.add(s);
        }
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      expect(nodes, hasLength(n));
      expect(best, lessThan(3000),
          reason: 'разбор $n AWG-узлов конвейером: $best мс (лучший из трёх)');
    }, skip: skip);
  });

  group('§473 — потолок и дефолт MTU исполняет РЕЕСТР', () {
    String wg(String extra) => 'wireguard://$_priv@h.example:51820'
        '?publickey=$_pub&address=10.0.0.2/32$extra#n';

    test('AWG с mtu=1420 → тело 1280, код awg_mtu_clamped со значением 1420',
        () {
      final spec = parseUri(wg('&jc=4&mtu=1420'))!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
      final w = _registry(spec).firstWhere((w) => w.code == 'awg_mtu_clamped',
          orElse: () => fail('нет кода: ${spec.warnings}'));
      expect(w.path, 'mtu');
      expect(w.value, '1420', reason: 'значение — то, что написал автор');
    }, skip: skip);

    test('AWG без mtu → тело 1280, кодов нет (подстановка — не замена)', () {
      final spec = parseUri(wg('&jc=4'))!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
      expect(_registry(spec), isEmpty);
    }, skip: skip);

    test('AWG с mtu=1200 → значение автора цело, кодов нет', () {
      final spec = parseUri(wg('&jc=4&mtu=1200'))!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1200);
      expect(_registry(spec), isEmpty);
    }, skip: skip);

    test('обычный WG с mtu=1420 — без замены и без кодов', () {
      // Условие `when.any_set` не выполнено: потолок диктует РОД узла.
      final spec = parseUri(wg('&mtu=1420'))!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1420);
      expect(_registry(spec), isEmpty);
    }, skip: skip);

    test('обычный WG без mtu — поля в теле нет вовсе', () {
      // Ядро берёт свой 1408; наш дефолт спорил бы с ним и ломал identity
      // (CANON §2.4).
      final spec = parseUri(wg(''))!;
      expect(spec.emit(TemplateVars.empty).map.containsKey('mtu'), isFalse);
    }, skip: skip);

    test('jc=0 — законный AWG: потолок действует (предикат `any_set`)', () {
      // §473 — `any_set` судит НАЛИЧИЕ КЛЮЧА, а не заданность значения:
      // `jc: 0` это «мусорные пакеты выключены» у настоящего AWG-узла.
      final spec = parseUri(wg('&jc=0&mtu=1420'))!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
      expect(_registry(spec).map((w) => w.code), contains('awg_mtu_clamped'));
    }, skip: skip);

    test('§463 — узел, у которого AWG-поля сняты ВСЕ, остаётся AmneziaWG', () {
      // `jc=abc` снимается молча (эталон Go), одинокий `jmin` — правилом
      // `requires`. В теле AWG-ключей не остаётся, и условие `any_set`
      // реестра по телу не выполнилось бы — а ссылка ПРОСИЛА AmneziaWG, и
      // потолок это свойство запрошенного протокола. Кейсы корпуса
      // `awg_bad_numeric_skipped`, `awg_jc_invalid_dropped`.
      final spec = parseUri(wg('&jc=abc&jmin=50'))!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['mtu'], 1280);
      expect(body.keys.where((k) => k.startsWith('j')), isEmpty,
          reason: 'ни одного AWG-поля в теле не осталось');
      // Код ровно один, и он про снятый `jmin` (§463).
      expect(_registry(spec).map((w) => '${w.code}@${w.path}'),
          ['awg_header_invalid@jmin']);
    }, skip: skip);

    test('§463 — awg_header_invalid ставится ПОФАКТОРНО', () {
      // Четыре битых заголовка — четыре сообщения человеку; конверт корпуса
      // при этом несёт одну запись без пути (`awg_ranged_h_broken_dropped`).
      final spec = parseUri(wg('&h1=10-&h2=a-b&h3=-5&h4=1-2-3&jc=4'))!;
      expect(spec.warnings.whereType<AwgHeaderInvalidWarning>(), hasLength(4));
      final body = spec.emit(TemplateVars.empty).map;
      for (final k in const ['h1', 'h2', 'h3', 'h4']) {
        expect(body.containsKey(k), isFalse, reason: 'битый $k снят');
      }
      expect(body['jc'], 4, reason: 'годное поле уцелело');
    }, skip: skip);
  });

  group('§472 — wireguard: перевод, который остаётся за маппером', () {
    test('ключи приводятся к КАНОНУ base64 (нормализация, не суждение)', () {
      // SPEC 103 D-030 — `…ccC=` и `…ccA=` это одни и те же 32 байта; без
      // нормализации одна нода давала бы два identity-хеша. Корпус нормирует
      // канон (`uri_psk_keepalive`).
      final spec = parseUri(
          'wireguard://ccccccccccccccccccccccccccccccccccccccccccC=@h.example'
          ':51820?publickey=ddddddddddddddddddddddddddddddddddddddddddD='
          '&address=10.0.0.3/32#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['private_key'], 'ccccccccccccccccccccccccccccccccccccccccccA=');
      expect((body['peers'] as List).first['public_key'],
          'ddddddddddddddddddddddddddddddddddddddddddA=');
    }, skip: skip);

    test('битый psk ОТБРАКОВЫВАЕТ узел (требование корпуса, не реестра)', () {
      // Реестр объявляет у `peers[].pre_shared_key` `on_invalid: drop` —
      // снял бы поле и оставил узел. Корпус нормирует обратное
      // (`junk_presharedkey_rejected` → `dropped: parse_error`): туннель к
      // серверу с psk без psk не поднимется. Запрос к лаунчеру — в спеке 472.
      expect(
          parseUri('wireguard://$_priv@h.example:51820?publickey=$_pub'
              '&presharedkey=*****&address=10.0.0.2/32#n'),
          isNull);
    }, skip: skip);

    test('allowed_ips по умолчанию 0.0.0.0/0,::/0; bare IP получает префикс',
        () {
      final def = parseUri('wireguard://$_priv@h.example:51820'
          '?publickey=$_pub&address=10.0.0.2#n')!;
      final body = def.emit(TemplateVars.empty).map;
      expect(body['address'], ['10.0.0.2/32'], reason: 'bare IPv4 → /32');
      expect((body['peers'] as List).first['allowed_ips'],
          ['0.0.0.0/0', '::/0']);

      final v6 = parseUri('wireguard://$_priv@h.example:51820'
          '?publickey=$_pub&address=fd00::2&allowedips=fd00::/8#n')!;
      expect(v6.emit(TemplateVars.empty).map['address'], ['fd00::2/128']);
    }, skip: skip);

    test('reserved: десятичная тройка и base64 client_id — одна форма тела',
        () {
      for (final q in const ['reserved=1,2,3', 'client_id=AQID']) {
        final spec = parseUri('wireguard://$_priv@h.example:51820'
            '?publickey=$_pub&address=10.0.0.2/32&$q#n')!;
        expect(
            ((spec.emit(TemplateVars.empty).map['peers'] as List)
                .first)['reserved'],
            [1, 2, 3],
            reason: q);
      }
    }, skip: skip);

    test('порт по умолчанию 51820; тег-фолбэк берёт адрес ПИРА', () {
      // У endpoint-схемы корневых `server`/`server_port` нет вовсе, и без
      // `UriMapping.tagAddress` безымянный узел получил бы `wireguard--0`.
      final spec = parseUri(
          'wireguard://$_priv@h.example?publickey=$_pub&address=10.0.0.2/32')!;
      expect(spec.tag, 'wireguard-h.example-51820');
      expect((spec.emit(TemplateVars.empty).map['peers'] as List).first['port'],
          51820);
    }, skip: skip);

    test('§421 — ключ защиты заголовка с сырым `+` переживает разбор', () {
      const hk = 'Bw4VHCMqMTg/Rk1UW2JpcHd+hYyTmqGor7a9xMvS2eA=';
      final spec = parseUri('wireguard://$_priv@h.example:51820'
          '?publickey=$_pub&address=10.0.0.2/32&s1=55&s2=42&s3=40&s4=12'
          '&headerprotectionkey=$hk#n')! as WireguardSpec;
      expect(spec.awg!.fields['header_protection_key'], hk);
    }, skip: skip);

    test('§450 — awg://<base64 .conf> распознаётся ДО конвейера', () {
      const conf = '[Interface]\nPrivateKey = $_priv\n'
          'Address = 10.0.0.2/32\nJc = 4\n\n'
          '[Peer]\nPublicKey = $_pub\n'
          'AllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n';
      final payload = base64.encode(utf8.encode(conf));
      final spec = parseUri('awg://$payload#AmneziaWG')!;
      expect(spec.tag, 'AmneziaWG');
      // §454 — источник узла это ССЫЛКА, а не INI из неё: узел пришёл ссылкой.
      expect(spec.rawSource, 'awg://$payload#AmneziaWG');
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
    }, skip: skip);
  });

  group('§472 шаг 7 / §456 — INI это ещё один МАППЕР конвейера', () {
    const proton = '[Interface]\n'
        '# Bouncing = 0\n'
        'PrivateKey = $_priv\n'
        'Address = 10.2.0.2/32\nDNS = 10.2.0.1\nMTU = 1420\n\n'
        '[Peer]\n# CH-FREE#11\nPublicKey = $_pub\n'
        'AllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n';

    test('источник узла — сам INI, байт в байт', () {
      // §456 — синтетического `wg://` наружу не выходит, и его больше нет
      // внутри вовсе: маппер читает INI напрямую.
      final spec = parseWireguardIni(proton, nameHint: 'file')!;
      expect(spec.rawSource, proton);
      expect(spec.rawSource, isNot(contains('wireguard://')));
    }, skip: skip);

    test('имя: комментарий под [Peer] сильнее nameHint, тот — сильнее фолбэка',
        () {
      expect(parseWireguardIni(proton, nameHint: 'file')!.tag, 'CH-FREE#11');
      final noComment = proton.replaceAll('# CH-FREE#11\n', '');
      expect(parseWireguardIni(noComment, nameHint: 'file')!.tag, 'file');
      expect(parseWireguardIni(noComment)!.tag, 'WireGuard');
      // `# Bouncing = 0` в `[Interface]` именем не считается — там `=`.
      expect(parseWireguardIni(noComment, nameHint: '   ')!.tag, 'WireGuard');
    }, skip: skip);

    test('узел INI разобран КОНВЕЙЕРОМ: коды реестра на нём уже стоят', () {
      // AWG-INI с завышенным MTU: потолок исполняет санитайзер, код приходит
      // из реестра — ровно как у ссылки.
      final ini = proton.replaceAll('MTU = 1420', 'MTU = 1420\nJc = 4');
      final spec = parseWireguardIni(ini)!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
      final w = _registry(spec).firstWhere((w) => w.code == 'awg_mtu_clamped',
          orElse: () => fail('нет кода: ${spec.warnings}'));
      expect(w.path, 'mtu');
      expect(w.value, '1420');
      // Второй проход по `emit()` такой узел не трогает (отметка конвейера).
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before));
    }, skip: skip);

    test('обычный WG из INI: MTU автора цел, кодов нет', () {
      final spec = parseWireguardIni(proton)!;
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1420);
      expect(_registry(spec), isEmpty);
    }, skip: skip);

    test('Endpoint: host:port, [IPv6]:port и голый IPv6 (§219)', () {
      String withEndpoint(String e) =>
          proton.replaceAll('Endpoint = 1.2.3.4:51820', 'Endpoint = $e');
      final v4 = parseWireguardIni(withEndpoint('h.example:1234'))!;
      expect(v4.server, 'h.example');
      expect(v4.port, 1234);

      final v6 = parseWireguardIni(withEndpoint('[2001:db8::1]:1234'))!;
      expect(v6.server, '2001:db8::1');
      expect(v6.port, 1234);

      // §219 — несколько `:` без скобок: порт от адреса неотличим.
      final bare = parseWireguardIni(withEndpoint('2001:db8::1'))!;
      expect(bare.server, '2001:db8::1');
      expect(bare.port, 51820);
    }, skip: skip);

    test('без Endpoint / PrivateKey / PublicKey узла нет', () {
      for (final drop in const ['Endpoint', 'PrivateKey', 'PublicKey']) {
        final ini = proton
            .split('\n')
            .where((l) => !l.trim().startsWith(drop))
            .join('\n');
        expect(parseWireguardIni(ini), isNull, reason: 'без $drop');
      }
    }, skip: skip);

    test('DNS из INI в тело не уезжает (у endpoint такого поля нет)', () {
      final body = parseWireguardIni(proton)!.emit(TemplateVars.empty).map;
      expect(body.containsKey('dns'), isFalse);
    }, skip: skip);

    test('AWG-ключи [Interface] и Reserved [Peer] переводятся как в ссылке',
        () {
      const ini = '[Interface]\nPrivateKey = $_priv\n'
          'Address = 10.2.0.2/32\nJc = 4\nJmin = 40\nJmax = 70\n'
          'H1 = 1234567\nI1 = <b 0xdeadbeef>\n\n'
          '[Peer]\nPublicKey = $_pub\nAllowedIPs = 0.0.0.0/0\n'
          'Endpoint = 1.2.3.4:51820\nReserved = 1,2,3\n'
          'PersistentKeepalive = 25\n';
      final body = parseWireguardIni(ini)!.emit(TemplateVars.empty).map;
      expect(body['jc'], 4);
      expect(body['h1'], 1234567);
      expect(body['i1'], '<b 0xdeadbeef>');
      final peer = (body['peers'] as List).first as Map;
      expect(peer['reserved'], [1, 2, 3]);
      expect(peer['persistent_keepalive_interval'], 25);
    }, skip: skip);

    test('§110 — Amnezia vpn:// остаётся КОНТЕЙНЕРОМ поверх того же маппера',
        () {
      // `vpn://` это не третий вход, а распаковщик: он достаёт из профиля
      // готовые INI-тексты и отдаёт их сюда же. Отдельного переезда ему не
      // нужно — он поехал конвейером вместе с INI.
      const ini = '[Interface]\nPrivateKey = $_priv\n'
          'Address = 10.2.0.2/32\nJc = 4\nMTU = 1420\n\n'
          '[Peer]\nPublicKey = $_pub\nAllowedIPs = 0.0.0.0/0\n'
          'Endpoint = 1.2.3.4:51820\n';
      final profile = jsonEncode({
        'containers': [
          {
            'container': 'amnezia-awg',
            'awg': {
              'last_config': jsonEncode({'config': ini}),
            },
          },
        ],
        'defaultContainer': 'amnezia-awg',
        'description': 'Профиль',
      });
      final spec = parseUri(
          'vpn://${base64Url.encode(utf8.encode(profile)).replaceAll('=', '')}')!;
      expect(spec.tag, 'Профиль');
      expect(spec.rawSource, ini, reason: '§456 — источник узла это его INI');
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280,
          reason: 'потолок AWG исполнил санитайзер — узел на конвейере');
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном AWG ничего не добавляет', () {
      final spec = parseUri('wireguard://$_priv@h.example:51820'
          '?publickey=$_pub&address=10.0.0.2/32&jc=4&mtu=1420#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });

  // БЕЗ ГЕЙТА: тест идёт через `parseSingboxEntry` напрямую, реестр ему не
  // нужен, а симметрию эмиттера и парсера тела он стережёт на любом прогоне.
  group('§472 — состав ветки json_parsers сверен с body.fields', () {
    test('всё, что пишет emitWireguard, парсер тела читает обратно', () {
      final body = <String, dynamic>{
        'type': 'wireguard',
        'tag': 'n',
        'mtu': 1280,
        'address': ['10.0.0.2/32', 'fd00::2/128'],
        'private_key': _priv,
        'peers': [
          {
            'address': 'h.example',
            'port': 51820,
            'public_key': _pub,
            'reserved': [1, 2, 3],
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'pre_shared_key': 'ccccccccccccccccccccccccccccccccccccccccccY=',
            'persistent_keepalive_interval': 25,
          },
        ],
        'header_protection_key': 'Bw4VHCMqMTg/Rk1UW2JpcHd+hYyTmqGor7a9xMvS2eA=',
        'content_padding_addition': '16-64',
        'random_trailers': true,
        's1': 50,
        's2': 100,
        's3': 20,
        's4': 20,
        'jc': 4,
        'jmin': 10,
        'jmax': 50,
        'h1': 1,
        'h2': 2,
        'h3': 3,
        'h4': 4,
        'i1': '<b 0xdeadbeef>',
      };
      final node = parseSingboxEntry(Map<String, dynamic>.from(body))!;
      expect(node.emit(TemplateVars.empty).map, body,
          reason: 'поле, которое эмиттер пишет, а парсер тела не читает, — '
              'молчаливая потеря на пересохранении через JSON; порядок ключей '
              'тоже нормативен (golden сравнивается байт в байт)');
    });
  });
}
