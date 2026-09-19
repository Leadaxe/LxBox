import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
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
/// §480 W2 — ЗЕРКАЛО реестра, а не вендоренная копия `app/contract`: второй
/// на CI нет вовсе, и под её гейтом тест молча пропускался бы ровно там, где
/// он нужен. Схема переехала на движок, и без секций она не разбирается.
const _contractRoot = 'assets/contract';

/// Правила, которые LxBox сегодня НЕ исполняет, с причиной. Пустая причина
/// недопустима: молчаливое расхождение и есть то, что страж ловит.
///
/// Ключ — `id` правила либо `id@схема`: одно и то же правило реестра у разных
/// схем может быть и реализовано, и нет. §472 шаг 5 сделал это различие
/// обязательным: `sni_heuristic_falls_back_to_server` у hysteria2 исполняется
/// (и всегда исполнялся), а у trojan/vless/vmess — нет.
const Map<String, String> _knownGaps = {
  // Не реализовано НИКОГДА (ни старым парсером, ни конвейером): у trojan,
  // vless и vmess `sni` без точки и двоеточия уезжает в `server_name` как
  // есть. Включение правила изменило бы тела и identity живых узлов, поэтому
  // оно требует отдельного решения владельца, а не попутной правки.
  'sni_heuristic_falls_back_to_server@trojan':
      'не реализовано в LxBox ни на одном входе trojan; включение меняет тела '
          'и identity — отдельное решение (спека 472, шаг 2)',
  'sni_heuristic_falls_back_to_server@vless':
      'не реализовано в LxBox ни на одном входе vless; включение меняет тела '
          'и identity — отдельное решение (спека 472, шаг 3)',
  'sni_heuristic_falls_back_to_server@vmess':
      'не реализовано в LxBox ни на одном входе vmess; включение меняет тела '
          'и identity — отдельное решение (спека 472, шаг 4)',
  // У tuic реализована только ПОЛОВИНА правила: пустой `sni` уступает адресу
  // сервера (так делал и прежний парсер), а проверки написания — точки,
  // двоеточия, значка `🔒` — нет. Реестр называет у tuic ту же эвристику, что
  // у hysteria2 («Go: эвристика точки/двоеточия»); включение её здесь сдвинуло
  // бы тела и identity живых узлов, у которых `sni` задан коротким именем.
  'sni_heuristic_falls_back_to_server@tuic':
      'реализован только откат пустого sni на адрес сервера; проверки '
          'написания нет — включение меняет тела и identity (спека 472, шаг 5)',
  // §475 — записи `security_none_no_tls@anytls` здесь БОЛЬШЕ НЕТ, и вернуть
  // её будет нечем: контракт 1.1.8 убрал anytls из `applies_to` самого
  // правила (`registry/tls.json`). Расхождения не осталось — реестр и
  // приложение говорят одно и то же: у AnyTLS TLS обязателен
  // (`C.ErrTLSRequired`, `protocol/anytls/outbound.go:45`), `security=none`
  // лишь игнорируется, а `sni`/`alpn`/`insecure` из той же ссылки остаются
  // (корпус: `uri/anytls/security_none_params_kept`). Правило стояло на нём
  // мёртвым: исполнись оно — узел ронял бы конфиг целиком.
  // §472 шаг 7 — у masque эвристики нет НИ ОДНОЙ её половины: прежний парсер
  // читал `sni` как есть и на адрес сервера пустое значение не откатывал. Это
  // не упущение, а свойство схемы: пустой `sni` у masque значит «дефолт
  // ПРОФИЛЯ ядра» (для cloudflare это `www.cloudflare.com`, lx.25-rc.4), а не
  // «имя не задано». Подставь маппер адрес сервера — узел поехал бы с SNI,
  // равным IP data-plane Cloudflare, то есть перестал бы подключаться; а у
  // WARP-узлов, которых больше всего, `sni` пуст ровно поэтому. Заодно
  // сдвинулись бы тела и identity всех живых MASQUE-узлов.
  'sni_heuristic_falls_back_to_server@masque':
      'у masque пустой sni означает дефолт ПРОФИЛЯ ядра, а не отсутствие '
          'имени: откат на адрес сервера дал бы SNI = IP и сломал бы узлы '
          'WARP; не реализовано ни на одном входе masque (спека 472, шаг 7)',
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
  // §472 шаг 4 — правило, которое добавил переезд vmess.
  'legacy_cleartext_fallback':
      'не-JSON payload читается как method:uuid@host:port',
  // §472 шаг 5 — правила, которые добавил переезд hysteria2 и tuic.
  'sni_heuristic_falls_back_to_server@hysteria2':
      'sni без точки/двоеточия и 🔒 уступают адресу сервера',
  'mport_range_spec': 'mport=1000-2000,3000 → server_ports [low:high]',
  'heartbeat_bare_number': 'heartbeat=10 → "10s"',
  // §472 шаг 6 — правило, которое добавил переезд anytls.
  'sni_heuristic_falls_back_to_server@anytls':
      'anytls: sni без точки/двоеточия и 🔒 уступают адресу сервера',
  // §472 шаг 6 — правила, которые добавил переезд naive. `applies_to` у них
  // нет (правила лежат в `protocols/naive.json` и относятся к схеме целиком),
  // и страж их не спрашивает, — но исполняет их маппер, и тесты написаны.
  'tls_block_kept_minimal': 'naive: в блоке TLS только enabled + server_name',
  'broken_header_pair_skipped':
      'naive: битая пара extra-headers пропускается, остальные живут',
  // §472 шаг 6 — правила http(s)-прокси. Оба уже покрыты общими записями
  // выше (`security_none_no_tls`, `utls_xray_hello_names` — без суффикса
  // схемы), но у http они проверяются на СВОЕЙ ссылке: у схемы TLS включает
  // суффикс схемы, а не параметр `security`.
  'security_none_no_tls@http':
      'http: security=none гасит TLS даже на https-схеме',
  'utls_xray_hello_names@http': 'http: fp в написании uTLS → имя семейства',
  // §472 шаг 7 — правила masque. `applies_to` у них нет (лежат в
  // `protocols/masque.json` и относятся к схеме целиком), и страж их не
  // спрашивает, — но исполняет их маппер, и тесты написаны.
  'vhttp_empty_defaults_to_h3': 'masque: без vhttp= → явный h3, а не auto ядра',
  'singbox_flat_fields_stripped':
      'masque: плоские network/sni/skip_cert_verify не переносятся',
  // §472 шаг 7 — единственное mapper-правило wireguard. `applies_to` у него
  // нет (лежит в `protocols/wireguard.json` и относится к схеме целиком).
  'bare_ip_gets_prefix':
      'wireguard: bare IP в address/allowed_ips получает /32 или /128',
  // §475 — единственное mapper-правило socks. `applies_to` у него нет (лежит
  // в `protocols/socks.json` и относится к схеме целиком).
  'socks_scheme_is_version': 'socks: схема ссылки → version тела',
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

/// Коды узла: текст предупреждения живёт в реестре, и проверять тут нужно
/// код, а не класс.
List<String> _codes(NodeSpec n) =>
    [for (final w in n.warnings.whereType<RegistryWarning>()) w.code];

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§472 — секция mapper реестра покрыта для переехавших схем', () {
    test('у каждой переехавшей схемы каждое mapper-правило названо', () {
      for (final scheme in kPipelineSchemes) {
        for (final id in _mapperRuleIds(scheme)) {
          // Сначала запись ДЛЯ ЭТОЙ СХЕМЫ, потом общая: одно правило реестра
          // у разных схем бывает и реализовано, и нет (§472 шаг 5).
          final qualified = '$id@$scheme';
          final known = _covered.containsKey(qualified) ||
              _knownGaps.containsKey(qualified) ||
              _covered.containsKey(id) ||
              _knownGaps.containsKey(id);
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
      expect(_codes(spec), contains('ech_ignored'));
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

  group('§472 — правила mapper на живых ссылках (hysteria2)', () {
    test('sni без точки/двоеточия и 🔒 уступают адресу сервера', () {
      // `sni_heuristic_falls_back_to_server` — у hysteria2 правило ЕСТЬ на
      // обоих проектах, в отличие от trojan/vless/vmess (см. _knownGaps).
      for (final bad in ['localhost', '🔒']) {
        final spec = parseUri(
            'hysteria2://p@h.example:443?sni=${Uri.encodeComponent(bad)}#n')!;
        expect((spec.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
            'h.example',
            reason: 'sni=$bad');
      }
      final ok = parseUri('hysteria2://p@h.example:443?sni=a.b#n')!;
      expect((ok.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'a.b');
    }, skip: skip);

    test('mport=1000-2000,3000 → server_ports [low:high]', () {
      // `mport_range_spec` — форма записи диапазона: дефис ссылки становится
      // двоеточием ядра, одиночный порт — парой `N:N`.
      final spec =
          parseUri('hysteria2://p@h.example:443?mport=1000-2000,3000#n')!;
      expect(spec.emit(TemplateVars.empty).map['server_ports'],
          ['1000:2000', '3000:3000']);
      // Тот же конвейер принимает диапазон прямо из authority, где его не
      // читает даже `Uri.parse`.
      final auth = parseUri('hysteria2://p@h.example:20000-30000/#n')!;
      expect(auth.emit(TemplateVars.empty).map['server_ports'],
          ['20000:30000']);
      expect(auth.emit(TemplateVars.empty).map['server_port'], 20000);
    }, skip: skip);

    test('fp в написании uTLS → имя семейства (и снимается как QUIC-блок)', () {
      // `utls_xray_hello_names` работает и здесь: перевод написания делает
      // маппер, а снимает блок правило `forbidden_for` — уже переведённым,
      // поэтому `value` кода называет семейство.
      final spec = parseUri(
          'hysteria2://p@h.example:443?sni=x.com&fp=hellofirefox_auto#n')!;
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'tls_not_applicable_quic');
      expect(w.value, 'map[enabled:true fingerprint:firefox]');
    }, skip: skip);

    test('alpn одной строкой → список тела', () {
      final spec =
          parseUri('hysteria2://p@h.example:443?sni=x.com&alpn=h3,h3-29#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls['alpn'], ['h3', 'h3-29']);
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (tuic)', () {
    const uuid = '11111111-1111-1111-1111-111111111111';

    test('heartbeat=10 → "10s"', () {
      // `heartbeat_bare_number` — форма записи: голое число это секунды, а
      // поле ядра duration-строка (`type: duration` реестра).
      final spec = parseUri('tuic://$uuid:p@h.example:443?heartbeat=10#n')!;
      expect(spec.emit(TemplateVars.empty).map['heartbeat'], '10s');
      // Явную duration маппер не трогает.
      final explicit =
          parseUri('tuic://$uuid:p@h.example:443?heartbeat=30s#n')!;
      expect(explicit.emit(TemplateVars.empty).map['heartbeat'], '30s');
    }, skip: skip);

    test('пустой sni уступает адресу сервера', () {
      final spec = parseUri('tuic://$uuid:p@h.example:443?alpn=h3#n')!;
      expect((spec.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'h.example');
    }, skip: skip);

    test('alpn одной строкой → список тела', () {
      final spec =
          parseUri('tuic://$uuid:p@h.example:443?alpn=h3,h3-29#n')!;
      expect((spec.emit(TemplateVars.empty).map['tls'] as Map)['alpn'],
          ['h3', 'h3-29']);
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (anytls)', () {
    test('anytls: sni без точки/двоеточия и 🔒 уступают адресу сервера', () {
      // `sni_heuristic_falls_back_to_server` — у anytls правило ЕСТЬ на обоих
      // проектах, как у hysteria2 (см. _knownGaps по trojan/vless/vmess).
      for (final bad in ['localhost', '🔒']) {
        final spec = parseUri(
            'anytls://pw@h.example:443?sni=${Uri.encodeComponent(bad)}#n')!;
        expect((spec.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
            'h.example',
            reason: 'sni=$bad');
      }
    }, skip: skip);

    test('anytls: pbk= создаёт блок REALITY, годность судит реестр', () {
      const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      final ok = parseUri('anytls://pw@h.example:443?pbk=$pbk&sid=abcd#n')!;
      final tls = ok.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['reality'] as Map)['public_key'], pbk);
    }, skip: skip);

    test('anytls: без fp= → random, fp в написании uTLS → семейство', () {
      // `fp_empty_defaults_to_random` и `utls_xray_hello_names` на одной схеме.
      final bare = parseUri('anytls://pw@h.example:443?sni=a.b#n')!;
      expect(
          ((bare.emit(TemplateVars.empty).map['tls'] as Map)['utls']
              as Map)['fingerprint'],
          'random');
      final alias =
          parseUri('anytls://pw@h.example:443?sni=a.b&fp=hellofirefox_auto#n')!;
      expect(
          ((alias.emit(TemplateVars.empty).map['tls'] as Map)['utls']
              as Map)['fingerprint'],
          'firefox');
    }, skip: skip);

    test('anytls: alpn одной строкой → список, ech= не переносится', () {
      // `alpn_comma_list` и `ech_param_dropped_with_code`.
      final spec = parseUri('anytls://pw@h.example:443?sni=a.b'
          '&alpn=h2,http/1.1&ech=ip.gs+1.1.1.1#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls['alpn'], ['h2', 'http/1.1']);
      expect(tls.containsKey('ech'), isFalse);
      expect(_codes(spec), contains('ech_ignored'));
    }, skip: skip);
  });

  group('§475 — правила mapper на живых ссылках (socks)', () {
    test('socks: схема ссылки → version тела', () {
      // `socks_scheme_is_version`. Своего query-параметра под версию у схемы
      // нет ни в одном диалекте — дискриминатором работает схема.
      for (final (uri, want) in const [
        ('socks://h.example:1080#n', '5'),
        ('socks5://h.example:1080#n', '5'),
        ('socks4://h.example:1080#n', '4'),
        ('socks4a://h.example:1080#n', '4a'),
      ]) {
        final spec = parseUri(uri)!;
        expect(spec.emit(TemplateVars.empty).map['version'], want,
            reason: uri);
      }
    }, skip: skip);

    test('socks: та же таблица работает обратно — узел эмитит свою схему', () {
      // Маппер и эмиттер обязаны читать ОДНУ таблицу: иначе узел версии 4
      // перестал бы переживать круг своей же ссылки, и притом молча.
      for (final uri in const [
        'socks4://user@h.example:1080#n',
        'socks4a://h.example:1080#n',
        'socks5://user:pass@h.example:1080#n',
      ]) {
        final spec = parseUri(uri)!;
        final again = parseUri(spec.toUri())!;
        expect(again.emit(TemplateVars.empty).map['version'],
            spec.emit(TemplateVars.empty).map['version'],
            reason: uri);
        expect(spec.toUri(), startsWith(uri.split('://').first),
            reason: '$uri: схема ссылки обязана называть версию узла');
      }
    }, skip: skip);

    test('socks4: пароль из ссылки переносится КАК ЕСТЬ', () {
      // У версии 4 пароля нет вовсе (userinfo — это userid), но маппер
      // значения не судит: годность пары судит ядро.
      final spec = parseUri('socks4://user:pass@h.example:1080#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['version'], '4');
      expect(body['username'], 'user');
      expect(body['password'], 'pass');
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (naive)', () {
    test('naive: в блоке TLS только enabled + server_name', () {
      // `tls_block_kept_minimal` — naive-outbound ядра отвергает остальные
      // опции TLS при создании (fatal всего конфига). Диалект ссылки их и не
      // знает: у схемы всего два query-параметра.
      final spec = parseUri('naive+https://u:p@h.example:443#n')!;
      expect(spec.emit(TemplateVars.empty).map['tls'],
          {'enabled': true, 'server_name': 'h.example'});
    }, skip: skip);

    test('naive: битая пара extra-headers пропускается, остальные живут', () {
      // `broken_header_pair_skipped` — одна битая пара не стоит узлу
      // остальных заголовков.
      final spec = parseUri('naive+https://u:p@h.example'
          '?extra-headers=X%20User%3Abad%0D%0AX-Good%3Aok#n')!;
      expect(spec.emit(TemplateVars.empty).map['extra_headers'],
          {'X-Good': 'ok'});
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (http)', () {
    test('http: security=none гасит TLS даже на https-схеме', () {
      final off = parseUri('proxy-https://u@h.example:443?security=none#n')!;
      expect(off.emit(TemplateVars.empty).map.containsKey('tls'), isFalse);
      // Без параметра https-схема блок даёт.
      final on = parseUri('proxy-https://u@h.example:443#n')!;
      expect((on.emit(TemplateVars.empty).map['tls'] as Map)['enabled'],
          isTrue);
    }, skip: skip);

    test('http: fp в написании uTLS → имя семейства', () {
      final spec = parseUri(
          'proxy-https://u@h.example:443?sni=a.b&fp=hellofirefox_auto#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
      // Перевод написания — не деградация: кода за него нет.
      expect(
        spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
        isNot(contains('utls_fp_unknown')),
      );
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (masque)', () {
    /// Канонический masque-узел корпуса, без `vhttp`.
    const bare = 'masque://PRIVDER%3D%3D@192.0.2.44:443'
        '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32#n';

    test('masque: без vhttp= → явный h3, а не auto ядра', () {
      // `vhttp_empty_defaults_to_h3` — КОНВЕНЦИЯ обеих сторон, не дефолт
      // ядра (у ядра `auto`). Значение входит в identity живых MASQUE-узлов,
      // поэтому маппер пишет его явно, а не полагается на `default` реестра
      // (тот по CANON §2.4 в тело не материализуется).
      final spec = parseUri(bare)!;
      expect(spec.emit(TemplateVars.empty).map['vhttp'], 'h3');
      // Явный `auto` при этом уезжает как написан: «нет параметра» и «оператор
      // выбрал auto» — не одно и то же.
      final auto = parseUri(bare.replaceAll('#n', '&vhttp=auto#n'))!;
      expect(auto.emit(TemplateVars.empty).map['vhttp'], 'auto');
      expect(auto.warnings, isEmpty);
    }, skip: skip);

    test('masque: плоские network/sni/skip_cert_verify не переносятся', () {
      // `singbox_flat_fields_stripped` — чужой диалект. Плоский `sni` рядом с
      // `tls.server_name` роняет ядро fail-fast'ом на весь конфиг, поэтому
      // ключи снимаются БЕЗ переноса значений (контракт 0.8.0, D-078).
      final spec = parseUri(bare.replaceAll(
          '#n', '&network=h2&server_name=legacy.example&skip_cert_verify=1#n'))!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['vhttp'], 'h3', reason: 'legacy network= не влияет ни на что');
      expect(body.containsKey('network'), isFalse);
      expect(body.containsKey('sni'), isFalse);
      expect(body.containsKey('skip_cert_verify'), isFalse);
      expect(body.containsKey('tls'), isFalse,
          reason: 'legacy server_name= не создаёт блок tls');
    }, skip: skip);

    test('masque: address списком → пара ip/ipv6, bare IP получает префикс', () {
      final spec = parseUri(bare.replaceAll(
          'address=172.16.0.2%2F32', 'address=172.16.0.2%2C2001%3Adb8%3A%3A2'))!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['ip'], '172.16.0.2/32');
      expect(body['ipv6'], '2001:db8::2/128');
    }, skip: skip);

    test('masque: sni и disable_sni уезжают во вложенный tls{}', () {
      final spec = parseUri(
          bare.replaceAll('#n', '&sni=a.example&disable_sni=1#n'))!;
      expect(spec.emit(TemplateVars.empty).map['tls'],
          {'server_name': 'a.example', 'disable_sni': true});
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (wireguard)', () {
    const priv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
    const pub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

    test('wireguard: bare IP в address/allowed_ips получает /32 или /128', () {
      // `bare_ip_gets_prefix` — файлы wg-quick пишут одиночные адреса без
      // длины префикса, а поле ядра это CIDR.
      final spec = parseUri('wireguard://$priv@h.example:51820'
          '?publickey=$pub&address=10.0.0.2,fd00::2'
          '&allowedips=192.168.1.1,2001:db8::1#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['address'], ['10.0.0.2/32', 'fd00::2/128']);
      expect((body['peers'] as List).first['allowed_ips'],
          ['192.168.1.1/32', '2001:db8::1/128']);
      // Уже-с-префиксом не трогается.
      final kept = parseUri('wireguard://$priv@h.example:51820'
          '?publickey=$pub&address=10.0.0.0/8#n')!;
      expect(kept.emit(TemplateVars.empty).map['address'], ['10.0.0.0/8']);
    }, skip: skip);
  });

  group('§472 — правила mapper на живых ссылках (vmess)', () {
    /// `vmess://base64(<json>)` — основная форма контейнера.
    String jsonLink(Map<String, dynamic> cfg) =>
        'vmess://${base64.encode(utf8.encode(jsonEncode(cfg)))}';

    const base = <String, dynamic>{
      'v': '2',
      'ps': 'n',
      'add': 'h.example',
      'port': '443',
      'id': '11111111-1111-1111-1111-111111111111',
    };

    test('не-JSON payload читается как method:uuid@host:port', () {
      // `legacy_cleartext_fallback` — откат, а не равноправная форма: JSON
      // пробуется первым. Транспорт и TLS у этой формы в query-хвосте.
      final spec = parseUri('vmess://${base64.encode(utf8.encode(
        'aes-128-gcm:11111111-1111-1111-1111-111111111111@203.0.113.7:8443'
        '?type=ws&path=%2Fws&tls=1',
      ))}#Legacy');
      expect(spec, isNotNull);
      final body = spec!.emit(TemplateVars.empty).map;
      expect(body['security'], 'aes-128-gcm');
      expect(body['server_port'], 8443);
      expect((body['transport'] as Map)['type'], 'ws');
      expect((body['tls'] as Map)['enabled'], isTrue);
      // Фрагмент читает ТОЛЬКО эта форма (`uri.userinfo.impl`).
      expect(spec.label, 'Legacy');
    }, skip: skip);

    test('JSON-форма фрагмент ссылки не читает', () {
      // Так у обеих сторон: имя узла берётся из ключа `ps`, а `#…` после
      // base64 выбрасывается (`protocols/vmess.json` → `uri.userinfo.impl`).
      final spec = parseUri('${jsonLink({...base, 'ps': 'изPS'})}#изФрагмента');
      expect(spec!.label, 'изPS');
    }, skip: skip);

    test('net=h2 включает TLS и даёт транспорт http', () {
      // `transport_name_dialect` в диалекте контейнера: `net=h2` → `http`,
      // и TLS включается принудительно, без ключа `tls` (`uri.query.tls`).
      final spec = parseUri(jsonLink({...base, 'net': 'h2'}))!;
      final body = spec.emit(TemplateVars.empty).map;
      expect((body['transport'] as Map)['type'], 'http');
      expect((body['tls'] as Map)['enabled'], isTrue);
      // Хост транспорта откатывается на адрес сервера.
      expect((body['transport'] as Map)['host'], ['h.example']);
    }, skip: skip);

    test('без tls=tls блока TLS нет вовсе', () {
      // Тот же вопрос СТРУКТУРЫ, что `security_none_no_tls` у прочих схем:
      // явный `tls:{enabled:false}` ронял ядра lx.5..lx.18 (SPEC 045).
      final spec = parseUri(jsonLink({...base, 'net': 'tcp'}))!;
      expect(spec.emit(TemplateVars.empty).map.containsKey('tls'), isFalse);
    }, skip: skip);

    test('SNI контейнера: sni → host → сервер', () {
      // Цепочка у контейнера СВОЯ — среднее звено `host`, а не `peer`
      // (`uri.query.sni.impl`). Ключ `host` при этом адресует и транспорт.
      final byHost = parseUri(jsonLink(
          {...base, 'net': 'tcp', 'tls': 'tls', 'host': 'cdn.example'}))!;
      expect((byHost.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'cdn.example');

      final bySni = parseUri(jsonLink({
        ...base,
        'net': 'tcp',
        'tls': 'tls',
        'host': 'cdn.example',
        'sni': 'sni.example',
      }))!;
      expect((bySni.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'sni.example');

      final byServer =
          parseUri(jsonLink({...base, 'net': 'tcp', 'tls': 'tls'}))!;
      expect(
          (byServer.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'h.example');
    }, skip: skip);

    test('fp в написании uTLS → имя семейства, alpn одной строкой → список',
        () {
      // `utls_xray_hello_names` и `alpn_comma_list` — те же общие части, что
      // у trojan и vless: диалект контейнера подаёт им те же имена ключей.
      final spec = parseUri(jsonLink({
        ...base,
        'net': 'tcp',
        'tls': 'tls',
        'fp': 'hellofirefox_auto',
        'alpn': 'h2,http/1.1',
      }))!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
      expect(tls['alpn'], ['h2', 'http/1.1']);
    }, skip: skip);

    test('?ed=N хвостом пути → два поля тела', () {
      // `ws_early_data_path_suffix` — путь у контейнера лежит ключом `path`.
      final spec = parseUri(
          jsonLink({...base, 'net': 'ws', 'path': '/x?ed=2560'}))!;
      final tr = spec.emit(TemplateVars.empty).map['transport'] as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    }, skip: skip);

    test('ech= не переносится, узел получает код', () {
      final spec = parseUri(jsonLink({
        ...base,
        'net': 'tcp',
        'tls': 'tls',
        'ech': 'ip.gs+1.1.1.1',
      }))!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('ech'), isFalse);
      expect(_codes(spec), contains('ech_ignored'));
    }, skip: skip);
  });
}
