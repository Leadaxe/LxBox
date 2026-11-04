import 'package:flutter_test/flutter_test.dart';

import 'engine_test_setup.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — вторая форма WebSocket early data: плоские `ed`/`eh` в query, а не
/// хвостом пути (§303). Потеря `eh` ломает коннект: при пустом
/// `early_data_header_name` ядро дописывает base64 В ПУТЬ (conn.go:172), а
/// сервер с `eh=Sec-WebSocket-Protocol` ждёт данные в заголовке → 404.
void main() {
  setUpAll(loadEngineSections);

  Map<String, dynamic> wsMap(TransportSpec? t) =>
      t!.toSingbox(const TemplateVars()).$1;

  group('реальный узел подписки', () {
    test('trojan с ed/eh в query → оба поля в конфиге', () {
      final n = parseUri(
        'trojan://Aimer@167.68.4.199:2053?ed=2560'
        '&eh=Sec-WebSocket-Protocol&host=epge.muarua.filegear-sg.me'
        '&path=%2F&sni=epge.muarua.filegear-sg.me&type=ws#node',
      )!;
      final tr = n.emitRaw(const TemplateVars()).map['transport'] as Map;
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });
  });

  group('Xray JSON wsSettings.ed/.eh', () {
    TransportSpec? fromXray(Map<String, dynamic> ws) {
      final specs = parseXrayElement({
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'ws',
              'security': 'tls',
              'wsSettings': ws,
            },
          }
        ],
      });
      return (specs.first as VlessSpec).transport;
    }

    // §533 / контракт 1.1.53 (§49 п.5 TASKS_LXBOX) — ПЛОСКИЕ `ed`/`eh` у
    // `wsSettings` НЕ ЧИТАЮТСЯ. Прежде их читал оверлей
    // `contract_draft/uri/transports.json` (`blocks.xray.ws`), и ревизия
    // зеркала назвала это расхождением с корпусом: кейсы
    // `body/xray/ws_ed_flat_only` и `ws_eh_without_ed` ждут кода
    // `json_field_unknown`, то есть Xray таких полей у `wsSettings` не
    // объявляет вовсе — раннее чтение сочиняло early data узлу, у которого
    // её нет. Конвенцию даёт ТОЛЬКО хвост пути (`path: "/x?ed=N"`, тест
    // ниже) и query ссылки (группа выше).
    test('ed/eh полями объекта НЕ читаются (json_field_unknown)', () {
      final m = wsMap(fromXray({
        'path': '/x',
        'ed': 2560,
        'eh': 'Sec-WebSocket-Protocol',
      }));
      expect(m['path'], '/x');
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('ed строкой тоже НЕ читается', () {
      final m = wsMap(fromXray({'path': '/x', 'ed': '1500'}));
      expect(m.containsKey('max_early_data'), isFalse);
    });

    test('eh без ed игнорируется', () {
      final m = wsMap(fromXray({'path': '/x', 'eh': 'X-Early'}));
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('хвост пути в приоритете', () {
      final m = wsMap(fromXray({'path': '/x?ed=700', 'ed': 2560}));
      expect(m['path'], '/x');
      expect(m['max_early_data'], 700);
    });
  });

  group('round-trip', () {
    // §480 W7 — ВИД ССЫЛКИ ИЗМЕНИЛСЯ, тело — нет.
    //
    // Было: `path=/x` + `ed=2560` + `eh=Sec-WebSocket-Protocol` — три
    // параметра. Стало: один хвост `path=/x?ed=2560`, а имя заголовка
    // восстанавливается `implies` той же записи, которая хвост и читает.
    //
    // Почему так вышло и почему это не потеря: «заголовок задан явно» против
    // «подразумевается формой» — различие, которого В ТЕЛЕ НЕТ. Оно жило
    // флагом модели (`earlyDataHeaderImplicit`), а эмиттер движка получает
    // каноническое тело и ничего кроме. При совпадении значения с
    // подразумеваемым обе формы дают ОДНО тело, что здесь и проверяется;
    // значение, от подразумеваемого отличное, уезжает отдельной записью `eh`
    // как и прежде (кейс ниже).
    test('хвост пути несёт ed, имя заголовка восстанавливается implies', () {
      final src = 'trojan://pw@example.com:443?type=ws&path=%2Fx'
          '&ed=2560&eh=Sec-WebSocket-Protocol&security=tls&sni=example.com#n';
      final a = parseUri(src)!;
      final uri = a.toUri();
      final q = Uri.parse(uri).queryParameters;
      expect(q['path'], '/x?ed=2560');

      // Круг не теряет ни размер, ни режим: тело байт в байт.
      expect(
        parseUri(uri)!.emitRaw(const TemplateVars()).map,
        a.emitRaw(const TemplateVars()).map,
      );
      final tr = parseUri(uri)!.emitRaw(const TemplateVars()).map['transport']
          as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('НЕдефолтное имя заголовка уезжает отдельным eh=', () {
      final src = 'trojan://pw@example.com:443?type=ws&path=%2Fx'
          '&ed=2560&eh=X-Custom&security=tls&sni=example.com#n';
      final a = parseUri(src)!;
      final uri = a.toUri();
      expect(Uri.parse(uri).queryParameters['eh'], 'X-Custom',
          reason: 'значение, которого форма-хвост не подразумевает, обязано '
              'уехать записью — иначе круг потерял бы его: $uri');
      expect(
        parseUri(uri)!.emitRaw(const TemplateVars()).map,
        a.emitRaw(const TemplateVars()).map,
      );
    });

    test('path-режим: eh в ссылку не добавляется', () {
      final uri = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx%3Fed%3D2560'
        '&security=tls&sni=example.com#n',
      )!
          .toUri();
      final q = Uri.parse(uri).queryParameters;
      expect(q['path'], '/x?ed=2560');
      expect(q.containsKey('eh'), isFalse);
    });
  });
}
