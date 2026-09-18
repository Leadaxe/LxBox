import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/mappers/uri_pipeline.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 2 — страж покрытия секции `mapper` реестра.
///
/// Маппер исполняет правила перевода, записанные реестром (`tls.json`,
/// `transports.json`, `protocols/*.json` → `mapper`). Реестр здесь норма, код
/// — исполнитель, и расходиться им нельзя молча: правило, появившееся у
/// лаунчера, обязано либо получить тест здесь, либо быть названным в
/// [_knownGaps] с причиной.
///
/// Страж намеренно не пытается «проверить правило по описанию»: описания
/// текстовые, автоматически из них тест не построить. Он держит СПИСОК —
/// падает, когда для уже переехавшей схемы в реестре появилось mapper-правило,
/// которого нет ни в тестах ниже, ни в списке известных расхождений. Это и
/// просили на шаге 2: без фанатизма, но без тихого расхождения.
const _contractRoot = 'contract';

/// Правила, которые LxBox сегодня НЕ исполняет, с причиной. Пустая причина
/// недопустима: молчаливое расхождение и есть то, что страж ловит.
const Map<String, String> _knownGaps = {
  // Не реализовано НИКОГДА (ни старым парсером, ни конвейером): у trojan и
  // vless `sni` без точки и двоеточия уезжает в `server_name` как есть.
  // Включение правила изменило бы тела и identity живых узлов, поэтому оно
  // требует отдельного решения владельца, а не попутной правки. У hysteria2 и
  // anytls та же эвристика реализована (их парсеры), у trojan и vless — нет.
  'sni_heuristic_falls_back_to_server':
      'не реализовано в LxBox ни на одном входе trojan/vless; включение меняет '
          'тела и identity — отдельное решение (спека 472, шаг 3+)',
};

/// Правила, покрытые тестами этого файла: id → имя теста.
const Map<String, String> _covered = {
  'security_none_no_tls': 'security=none — блока tls нет вовсе',
  'utls_xray_hello_names': 'fp в написании uTLS → имя семейства',
  'alpn_comma_list': 'alpn одной строкой → список тела',
  'ech_param_dropped_with_code': 'ech= не переносится, узел получает код',
  'ws_early_data_path_suffix': '?ed=N хвостом пути → два поля тела',
  'transport_name_dialect': 'headerType=http поверх tcp → транспорт http',
  // §472 шаг 3 — правила, которые добавил переезд vless.
  'plaintext_port_no_tls': 'vless без security на открытом порту — блока нет',
  'pbk_makes_reality_block': 'pbk= создаёт блок REALITY, годность судит реестр',
  'fp_empty_defaults_to_random': 'vless без fp= → random',
  'vision_udp443_is_a_compound_name':
      'flow=xtls-rprx-vision-udp443 → vision + packet_encoding=xudp',
  'packet_encoding_none_means_absent': 'packetEncoding=none — ключа нет вовсе',
};

/// Все mapper-правила реестра, относящиеся к [scheme].
List<String> _mapperRuleIds(String scheme) {
  final dir = Directory('$_contractRoot/registry');
  final files = <File>[
    ...dir.listSync().whereType<File>(),
    ...Directory('$_contractRoot/registry/protocols')
        .listSync()
        .whereType<File>(),
  ];
  final out = <String>[];
  for (final f in files) {
    if (!f.path.endsWith('.json')) continue;
    final Object? raw;
    try {
      raw = jsonDecode(f.readAsStringSync());
    } catch (_) {
      continue;
    }
    if (raw is! Map) continue;
    final mapper = raw['mapper'];
    if (mapper is! List) continue;
    for (final rule in mapper) {
      if (rule is! Map) continue;
      final applies = rule['applies_to'];
      if (applies is! List || !applies.contains(scheme)) continue;
      final id = rule['id'];
      if (id is String) out.add(id);
    }
  }
  return out..sort();
}

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 — секция mapper реестра покрыта для переехавших схем', () {
    test('у каждой переехавшей схемы каждое mapper-правило названо', () {
      for (final scheme in kPipelineSchemes) {
        for (final id in _mapperRuleIds(scheme)) {
          final known = _covered.containsKey(id) || _knownGaps.containsKey(id);
          expect(
            known,
            isTrue,
            reason: 'схема $scheme переехала на конвейер, а mapper-правило '
                '`$id` из реестра не покрыто тестом и не названо в '
                '_knownGaps. Либо реализуйте его в mappers/, либо запишите '
                'расхождение с причиной.',
          );
        }
      }
    }, skip: skip);

    test('у каждого известного расхождения есть причина', () {
      for (final e in _knownGaps.entries) {
        expect(e.value.trim(), isNotEmpty,
            reason: 'расхождение ${e.key} без причины');
      }
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (trojan)', () {
    test('security=none — блока tls нет вовсе', () {
      // SPEC 045: явный `tls:{enabled:false}` ронял ядра lx.5..lx.18.
      final spec = parseUri('trojan://p@h.example:8080?security=none#n')!;
      expect(spec.emit(TemplateVars.empty).map.containsKey('tls'), isFalse);
    }, skip: skip);

    test('fp в написании uTLS → имя семейства', () {
      final spec = parseUri(
          'trojan://p@h.example:443?security=tls&fp=hellofirefox_auto#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
      // Псевдоним — не деградация: кода за перевод написания нет.
      expect(
        spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
        isNot(contains('utls_fp_unknown')),
      );
    }, skip: skip);

    test('alpn одной строкой → список тела', () {
      final spec = parseUri(
          'trojan://p@h.example:443?security=tls&alpn=h2,http/1.1#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls['alpn'], ['h2', 'http/1.1']);
    }, skip: skip);

    test('ech= не переносится, узел получает код', () {
      final spec = parseUri(
          'trojan://p@h.example:443?security=tls&ech=ip.gs+1.1.1.1#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('ech'), isFalse);
      expect(spec.warnings.whereType<EchIgnoredWarning>(), isNotEmpty);
    }, skip: skip);

    test('?ed=N хвостом пути → два поля тела', () {
      final spec = parseUri('trojan://p@h.example:443?security=tls&type=ws'
          '&path=%2Fx%3Fed%3D2560#n')!;
      final tr = spec.emit(TemplateVars.empty).map['transport'] as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
      // §103 D-008 — подставленный заголовок в ссылку не возвращается.
      expect(spec.toUri(), isNot(contains('eh=')));
      expect(
        ((spec as TrojanSpec).transport as WsTransport).earlyDataHeaderImplicit,
        isTrue,
      );
    }, skip: skip);

    test('headerType=http поверх tcp → транспорт http', () {
      final spec = parseUri('trojan://p@h.example:443?security=tls&type=tcp'
          '&headerType=http&path=%2Fc&host=cdn.example#n')!;
      final tr = spec.emit(TemplateVars.empty).map['transport'] as Map;
      expect(tr['type'], 'http');
      expect(tr['path'], '/c');
      expect(tr['host'], ['cdn.example']);
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (vless)', () {
    test('vless без security на открытом порту — блока нет', () {
      // Эвристики trojan не имеет: у него дефолт «TLS включён».
      final plain = parseUri('vless://u@h.example:8080#n')!;
      expect(plain.emit(TemplateVars.empty).map.containsKey('tls'), isFalse);
      final tls = parseUri('vless://u@h.example:8443#n')!;
      expect(tls.emit(TemplateVars.empty).map.containsKey('tls'), isTrue);
    }, skip: skip);

    test('pbk= создаёт блок REALITY, годность судит реестр', () {
      const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      // Блок есть и без `security=reality`: гейт — сам ключ, а не маркер.
      final ok = parseUri('vless://u@h.example:443?security=tls&pbk=$pbk#n')!;
      final tls = ok.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['reality'] as Map)['public_key'], pbk);

      // Мусор: блок создаёт маппер, а снимает его реестр по `base64_32`.
      final junk =
          parseUri('vless://u@h.example:443?security=reality&pbk=enabled#n')!;
      final junkTls = junk.emit(TemplateVars.empty).map['tls'] as Map;
      expect(junkTls.containsKey('reality'), isFalse);
      expect(
        junk.warnings.whereType<RegistryWarning>().map((w) => w.code),
        contains('reality_pbk_invalid'),
      );
    }, skip: skip);

    test('vless без fp= → random', () {
      // D-009: конвенция обеих сторон, не дефолт ядра (у ядра пустой fp =
      // chrome). Значение входит в identity-хеш живых узлов.
      final spec = parseUri('vless://u@h.example:443?security=tls#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'random');
      // У trojan дефолта нет — блок не появляется вовсе.
      final tr = parseUri('trojan://p@h.example:443?security=tls#n')!;
      expect((tr.emit(TemplateVars.empty).map['tls'] as Map).containsKey('utls'),
          isFalse);
    }, skip: skip);

    test('flow=xtls-rprx-vision-udp443 → vision + packet_encoding=xudp', () {
      final spec =
          parseUri('vless://u@h.example:443?security=tls&sni=x.com'
              '&flow=xtls-rprx-vision-udp443#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['flow'], 'xtls-rprx-vision');
      expect(body['packet_encoding'], 'xudp');
      // Порт НЕ переписывается (DRIFT §7.4, решение владельца).
      expect(body['server_port'], 443);
    }, skip: skip);

    test('packetEncoding=none — ключа нет вовсе', () {
      // `none` в диалекте подписок = «без особой инкапсуляции». Ядро такого
      // значения не знает и валится всем конфигом, поэтому кода за него нет:
      // это синоним отсутствия, а не мусор.
      final spec = parseUri('vless://u@h.example:443?security=tls&sni=x.com'
          '&packetEncoding=none#n')!;
      expect(spec.emit(TemplateVars.empty).map.containsKey('packet_encoding'),
          isFalse);
      expect(
        spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
        isNot(contains('packet_encoding_unknown')),
      );
    }, skip: skip);
  });
}
