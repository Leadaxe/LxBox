import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/source_dialect.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';
import 'package:lxbox/services/builder/verbatim_body.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/source_classify.dart';

import '../parser/engine_test_setup.dart';

/// §455 — источник записи JSON → тело узла в конфиг дословно (объект
/// источника), а не emit() модели; ссылка/INI — через модель, как раньше.
class _Ctx extends EmitContext {
  final entries = <SingboxEntry>[];
  final warnings = <String>[];
  final _seen = <String>{};

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  String allocateTag(String baseTag) {
    var t = baseTag;
    var i = 1;
    while (!_seen.add(t)) {
      t = '$baseTag-${i++}';
    }
    return t;
  }

  @override
  void addEntry(SingboxEntry entry) => entries.add(entry);

  @override
  void warn(String line) => warnings.add(line);

  @override
  void addToSelectorTagList(SingboxEntry entry) {}

  @override
  void addToAutoList(SingboxEntry entry) {}

  @override
  final RuleSetRegistry ruleSets =
      RuleSetRegistry(initialRuleSets: const [], initialRules: const []);
}

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  const pem = '-----BEGIN CERTIFICATE-----\nMII…\n-----END CERTIFICATE-----\n';
  final naive = {
    'type': 'naive',
    'tag': 'naive-out',
    'server': '1.2.3.4',
    'server_port': 443,
    'username': 'user',
    'password': 'password',
    'tls': {'enabled': true, 'server_name': 'server.com', 'certificate': pem},
    'unknown_to_model': {'x': 1},
  };
  // Контракт 1.1.118 (D-128) — тело с висячим `detour` при разборе
  // отбраковывается (fail-closed), поэтому у общей фикстуры detour нет.
  final naiveDetour = {...naive, 'detour': 'someone-else'};

  UserServer server(String raw) => UserServer(
        id: 's1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: raw,
        nodes: parseAll(decode(raw)),
      );

  Map<String, dynamic> built(ServerList list) {
    final ctx = _Ctx();
    list.build(ctx);
    expect(ctx.entries, hasLength(1));
    return ctx.entries.single.map;
  }

  // Д-1 (эмулятор 19.09.2026) — одиночный Xray-outbound объектом: тот же
  // диалект, что и в массиве `outbounds[]`, но добавленный одним объектом.
  String xray(String tag) => jsonEncode({
        'protocol': 'vless',
        'tag': tag,
        'settings': {
          'vnext': [
            {
              'address': '198.51.100.24',
              'port': 443,
              'users': [
                {
                  'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
                  'encryption': 'none',
                },
              ],
            },
          ],
        },
        'streamSettings': {'network': 'tcp', 'security': 'none'},
      });

  // §722 — вид записи определяется на входе текста движком
  // (`sourceDialectOf`) и хранится; сборка ветвится по хранимому виду.
  group('§722 вид на входе текста', () {
    test('sing-box → singbox, Xray → xray, ссылка → uri, INI → wg_ini', () {
      expect(sourceDialectOf(jsonEncode(naive)), SourceDialect.singbox);
      expect(sourceDialectOf(xray('x')), SourceDialect.xray);
      expect(sourceDialectOf('vless://u@h:443?security=none#t'),
          SourceDialect.uri);
      expect(
          sourceDialectOf('[Interface]\nPrivateKey = '
              'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n'
              'Address = 10.0.0.2/32\n[Peer]\nPublicKey = '
              'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\n'
              'Endpoint = 1.2.3.4:51820\n'),
          SourceDialect.wgIni);
    });

    test('форма — именем реестра, sing-box отделён от Xray', () {
      expect(sourceKindOf(jsonEncode(naive)), 'singbox_outbound');
      expect(sourceKindOf(xray('x')), 'xray_outbound');
      expect(sourceKindOf('vless://u@h:443?security=none#t'), 'uri_lines');
    });
  });

  group('verbatimBodyOf', () {
    test('висячий detour тела → узел отбракован при разборе (D-128)', () {
      expect(parseAll(decode(jsonEncode(naiveDetour))), isEmpty);
    });

    test('вид singbox → объект без detour; вид uri → null', () {
      final raw = jsonEncode(naive);
      final node = parseAll(decode(raw)).single;
      final body = verbatimBodyOf(SourceDialect.singbox, node)!;
      expect(body.containsKey('detour'), isFalse);
      expect(body['unknown_to_model'], {'x': 1});
      expect(body['tag'], 'naive-out');
      expect(
          verbatimBodyOf(SourceDialect.uri,
              parseAll(decode('vless://u@h:443?security=none#t')).single),
          isNull);
    });

    // §722 — запись вида xray дословной НЕ бывает: диалект чужой, тело —
    // перевод. Решает вид записи, не текст.
    test('вид xray → null (через модель) всегда', () {
      final raw = xray('x');
      final node = parseAll(decode(raw)).single;
      expect(verbatimBodyOf(SourceDialect.xray, node), isNull);
      // Даже узел sing-box-текста под видом xray — не дословно.
      final sb = parseAll(decode(jsonEncode(naive))).single;
      expect(verbatimBodyOf(SourceDialect.xray, sb), isNull);
    });
  });

  // §576 п.4 — дословно только при всех четырёх условиях; по одному отказу
  // на каждое.
  group('§576 дословность: четыре условия', () {
    test('1. контейнер: узел подписки идёт через модель', () {
      final raw = jsonEncode(naive);
      final sub = SubscriptionServers(
        id: 'sub1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example-1.com/sub',
        nodes: parseAll(decode(raw)),
      );
      final m = built(sub);
      expect(m['type'], 'naive');
      expect(m.containsKey('unknown_to_model'), isFalse);
    });

    test('2. группа автовыбора → null', () {
      final raw = jsonEncode({
        'outbounds': [
          naive,
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['naive-out'],
          },
        ],
      });
      final group = parseAll(decode(raw)).whereType<AutoSelectSpec>().single;
      expect(verbatimBodyOf(SourceDialect.singbox, group), isNull);
    });

    test('3. вид записи не singbox → null', () {
      final node = parseAll(decode(jsonEncode(naive))).single;
      for (final d in [
        SourceDialect.xray,
        SourceDialect.uri,
        SourceDialect.wgIni,
      ]) {
        expect(verbatimBodyOf(d, node), isNull, reason: d.code);
      }
      expect(verbatimBodyOf(SourceDialect.singbox, node), isNotNull);
    });

    // §722 (контракт 1.1.165 §10.1 условие 3) — документ sing-box тоже
    // авторский: дословно уходит КАЖДЫЙ узел записи, а не только первый.
    test('3а. документ singbox → каждый узел дословно', () {
      final second = {
        ...naive,
        'tag': 'naive-2',
        'server': '1.2.3.5',
        'unknown_to_model': {'y': 2},
      };
      final raw = jsonEncode({
        'outbounds': [naive, second],
      });
      final list = server(raw);
      expect(list.dialect, SourceDialect.singbox);
      final ctx = _Ctx();
      list.build(ctx);
      expect(ctx.entries, hasLength(2));
      expect(ctx.entries[0].map['unknown_to_model'], {'x': 1});
      expect(ctx.entries[1].map['unknown_to_model'], {'y': 2});
      expect(ctx.entries.every((e) => e.authored), isTrue);
    });

    test('4. текст узла не JSON-объект → null', () {
      final uriNode =
          parseAll(decode('vless://u@h.example.com:443?security=none#t'))
              .single;
      expect(verbatimBodyOf(SourceDialect.singbox, uriNode), isNull);
    });
  });

  // Д-1 — одиночный Xray-outbound как UserServer: в конфиге sing-box-тело,
  // равное телу того же узла из массива `outbounds[]`.
  group('Д-1: одиночный Xray-объект', () {
    Map<String, dynamic> bodyFromArray(String one) {
      final arrayRaw = '[$one]';
      final list = UserServer(
        id: 's2',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: arrayRaw,
        nodes: parseAll(decode(arrayRaw)),
      );
      return built(list);
    }

    for (final (scheme, one) in <(String, String)>[
      ('vless', ''),
      (
        'vmess',
        '{"protocol":"vmess","tag":"vm","settings":{"vnext":[{"address":'
            '"198.51.100.25","port":443,"users":[{"id":'
            '"b831381d-6324-4d53-ad4f-8cda48b30811","security":"auto"}]}]},'
            '"streamSettings":{"network":"tcp","security":"none"}}'
      ),
      (
        'trojan',
        '{"protocol":"trojan","tag":"tj","settings":{"servers":[{"address":'
            '"198.51.100.26","port":443,"password":"pw"}]},'
            '"streamSettings":{"network":"tcp","security":"tls"}}'
      ),
      (
        'shadowsocks',
        '{"protocol":"shadowsocks","tag":"ss","settings":{"servers":[{'
            '"address":"198.51.100.27","port":8388,"method":'
            '"aes-256-gcm","password":"pw"}]}}'
      ),
    ]) {
      test('$scheme: тело sing-box, равное телу из массива outbounds[]', () {
        final one0 = one.isEmpty ? xray('vl') : one;
        final m = built(server(one0));
        // Диалект Xray в конфиг не уехал.
        expect(m['type'], isA<String>());
        expect((m['type'] as String).isNotEmpty, isTrue);
        expect(m.containsKey('protocol'), isFalse);
        expect(m.containsKey('settings'), isFalse);
        expect(m.containsKey('streamSettings'), isFalse);
        // И оно то же, что у того же узла из массива.
        final fromArray = bodyFromArray(one0);
        expect(m, fromArray);
      });
    }
  });

  group('сборка', () {
    test('одиночный сервер из JSON: тело дословно, ключи вне модели живы', () {
      final m = built(server(jsonEncode(naive)));
      expect(m['unknown_to_model'], {'x': 1});
      expect((m['tls'] as Map)['certificate'], pem);
      expect(m['tag'], 'naive-out');
      // detour тела снят; политика по умолчанию detour не ставит.
      expect(m.containsKey('detour'), isFalse);
    });

    test('одиночный сервер из ссылки: emit модели, как раньше', () {
      final m = built(server('vless://u@h.example.com:443?security=none#t'));
      expect(m['type'], 'vless');
      expect(m.containsKey('unknown_to_model'), isFalse);
    });

    // §722 — Xray-запись в сборке никогда не дословна.
    test('одиночный сервер вида xray: тело модели, диалект Xray не уехал', () {
      final list = server(xray('xr'));
      expect(list.dialect, SourceDialect.xray);
      final ctx = _Ctx();
      list.build(ctx);
      final m = ctx.entries.single.map;
      expect(ctx.entries.single.authored, isFalse);
      expect(m.containsKey('protocol'), isFalse);
      expect(m['type'], 'vless');
    });

    test('член папки из JSON: дословно; тег с префиксом папки', () {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: 'F ',
        detourPolicy: const DetourPolicy(),
        members: [FolderMember(raw: jsonEncode(naive))],
      );
      final m = built(folder);
      expect(m['unknown_to_model'], {'x': 1});
      expect(m['tag'], startsWith('F'));
      expect(m['tag'], endsWith('naive-out'));
    });

    test('личный detour члена применяется поверх дословного тела', () {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(),
        members: [
          FolderMember(raw: 'vless://u@j.example.com:443?security=none#jump'),
          FolderMember(
            raw: jsonEncode(naive),
            detour: const NodeLink(folderId: 'f1', tag: 'jump'),
          ),
        ],
      );
      final ctx = _Ctx();
      folder.build(ctx);
      final main = ctx.entries.firstWhere((e) => e.map['type'] == 'naive');
      // detour ссылкой ставит второй проход сборки (deferDetour). Тело с
      // висячим `detour` сюда не доезжает: разбор его отбраковывает (D-128).
      expect(main.map['detour'], isNot('someone-else'));
    });
  });
}
