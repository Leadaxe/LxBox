import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/transport.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §097 — XHTTP (Xray splithttp) нативный transport. По образцу
/// singbox-launcher SPEC 071: parse (URI camelCase + snake) → emit → round-trip,
/// httpupgrade остаётся отдельным типом.
void main() {
  group('XHTTP', () {
    test('parseTransport xhttp → все поля (Xray camelCase)', () {
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'stream-one',
        'path': '/x',
        'host': 'h',
        'xPaddingBytes': '100-1000',
        'noGRPCHeader': 'true',
      }) as XhttpTransport;
      expect(t.mode, 'stream-one');
      expect(t.path, '/x');
      expect(t.host, 'h');
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, true);
    });

    test('snake-case ключи (sing-box) тоже читаются', () {
      final t = parseTransport({
        'type': 'xhttp',
        'x_padding_bytes': '50-200',
        'no_grpc_header': '1',
      }) as XhttpTransport;
      expect(t.xPaddingBytes, '50-200');
      expect(t.noGrpcHeader, true);
    });

    test('toSingbox → нативный type:xhttp + поля, без fallback-warning', () {
      final (m, w) = const XhttpTransport(
        path: '/x',
        host: 'h',
        mode: 'auto',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        headers: {'User-Agent': 'x'},
      ).toSingbox(TemplateVars.empty);
      expect(m['type'], 'xhttp');
      expect(m['path'], '/x');
      expect(m['host'], 'h');
      expect(m['mode'], 'auto');
      expect(m['x_padding_bytes'], '100-1000');
      expect(m['no_grpc_header'], true);
      expect(m['headers'], {'User-Agent': 'x'});
      expect(w, isEmpty);
    });

    test('round-trip transportToQuery → parseTransport', () {
      const x = XhttpTransport(
        path: '/x',
        host: 'h',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
      );
      final q = transportToQuery(x);
      expect(q['type'], 'xhttp');
      final t = parseTransport(q) as XhttpTransport;
      expect(t.path, '/x');
      expect(t.host, 'h');
      expect(t.mode, 'packet-up');
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, true);
    });

    test('httpupgrade остаётся отдельным типом (регресс на путаницу)', () {
      final t =
          parseTransport({'type': 'httpupgrade', 'path': '/u', 'host': 'h'});
      expect(t, isA<HttpUpgradeTransport>());
      expect(transportToQuery(t!)['type'], 'httpupgrade');
    });

    test('mode-матрица парсится дословно', () {
      for (final mode in ['auto', 'packet-up', 'stream-up', 'stream-one']) {
        final t =
            parseTransport({'type': 'xhttp', 'mode': mode}) as XhttpTransport;
        expect(t.mode, mode);
      }
    });

    test('минимальный xhttp (только type) → дефолты, без лишних ключей', () {
      final (m, _) =
          (parseTransport({'type': 'xhttp'}) as XhttpTransport)
              .toSingbox(TemplateVars.empty);
      expect(m['type'], 'xhttp');
      expect(m.containsKey('mode'), false);
      expect(m.containsKey('x_padding_bytes'), false);
      expect(m.containsKey('no_grpc_header'), false);
      // §127 — расширенные поля тоже не текут в выхлоп при дефолтах.
      expect(m.containsKey('session_placement'), false);
      expect(m.containsKey('x_padding_obfs_mode'), false);
      expect(m.containsKey('sc_max_each_post_bytes'), false);
    });
  });

  // §127 — расширенные клиентские поля SPEC 002 v2: placement/keys/obfs/tuning,
  // парсинг `extra`-JSON, нормализация sc*, golden round-trip.
  group('XHTTP §127 full params', () {
    test('golden: все 15 полей camelCase → snake_case transport (§8.1)', () {
      final t = parseTransport({
        'type': 'xhttp',
        'host': 'www.example.com',
        'path': '/xhttp',
        'mode': 'packet-up',
        'xPaddingBytes': '100-1000',
        'noGRPCHeader': 'true',
        'sessionPlacement': 'header',
        'sessionKey': 'X-Session',
        'seqPlacement': 'query',
        'seqKey': 'x_seq',
        'uplinkDataPlacement': 'header',
        'uplinkDataKey': 'X-Data',
        'uplinkChunkSize': '3000-4000',
        'uplinkHTTPMethod': 'POST',
        'xPaddingObfsMode': 'true',
        'xPaddingKey': 'x_padding',
        'xPaddingHeader': 'X-Padding',
        'xPaddingPlacement': 'header',
        'xPaddingMethod': 'tokenish',
        'scMaxEachPostBytes': '1000000',
        'scMinPostsIntervalMs': '30',
      }) as XhttpTransport;
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m, {
        'type': 'xhttp',
        'host': 'www.example.com',
        'path': '/xhttp',
        'mode': 'packet-up',
        'x_padding_bytes': '100-1000',
        'no_grpc_header': true,
        'session_placement': 'header',
        'session_key': 'X-Session',
        'seq_placement': 'query',
        'seq_key': 'x_seq',
        'uplink_data_placement': 'header',
        'uplink_data_key': 'X-Data',
        'uplink_chunk_size': '3000-4000',
        'uplink_http_method': 'POST',
        'x_padding_obfs_mode': true,
        'x_padding_key': 'x_padding',
        'x_padding_header': 'X-Padding',
        'x_padding_placement': 'header',
        'x_padding_method': 'tokenish',
        'sc_max_each_post_bytes': '1000000',
        'sc_min_posts_interval_ms': '30',
      });
    });

    test('snake_case формы расширенных полей тоже читаются', () {
      // Парсинг дословный — поле читается как есть; нормализация в toSingbox.
      final t = parseTransport({
        'type': 'xhttp',
        'session_placement': 'cookie',
        'x_padding_obfs_mode': '1',
        'uplink_http_method': 'GET',
      }) as XhttpTransport;
      expect(t.sessionPlacement, 'cookie');
      expect(t.xPaddingObfsMode, true);
      expect(t.uplinkHttpMethod, 'GET');
    });

    // SPEC 103 vless/xhttp_uplink_get_without_packet_up_reset,
    // xhttp_uplink_header_placement_reset, xhttp_placement_bogus_reset —
    // session_placement/uplink_data_placement/uplink_http_method — pure
    // passthrough, эталон Go (registry/warnings.json xhttp_param_reset:
    // "go": null, Go пока не нормализует XHTTP-параметры — "normalization
    // is left to the core", xhttpBuildTransport). Раньше Dart сбрасывал их
    // на дефолт + warning; контрактный корпус показал расхождение с Go —
    // выровнено на pass-through (core сам роняет мусор, не парсер).
    test('session_placement/uplink_data_placement/uplink_http_method — pure passthrough (canon = Go)', () {
      // GET без packet-up → пишем как есть, без warning (было: сброс).
      final t1 = parseTransport(
          {'type': 'xhttp', 'uplink_http_method': 'GET', 'mode': 'auto'})!;
      final (m1, w1) = t1.toSingbox(TemplateVars.empty);
      expect(m1['uplink_http_method'], 'GET');
      expect(w1.whereType<XhttpParamResetWarning>(), isEmpty);

      // GET с packet-up → тоже пишем, без warning.
      final t2 = parseTransport(
          {'type': 'xhttp', 'uplink_http_method': 'GET', 'mode': 'packet-up'})!;
      final (m2, w2) = t2.toSingbox(TemplateVars.empty);
      expect(m2['uplink_http_method'], 'GET');
      expect(w2, isEmpty);

      // §416 отменил passthrough ИМЕННО для header-placement: ядро на нём
      // роняет весь конфиг, а не одну ноду. Не-header placement'ы (body,
      // cookie, auto) остаются pass-through, как канон Go и требует.
      final t3 = parseTransport({
        'type': 'xhttp',
        'uplink_data_placement': 'cookie',
        'mode': 'stream-up',
      })!;
      final (m3, w3) = t3.toSingbox(TemplateVars.empty);
      expect(m3['uplink_data_placement'], 'cookie');
      expect(w3.whereType<XhttpParamResetWarning>(), isEmpty);

      // "невалидный" enum session_placement → тоже pure passthrough.
      final t4 = parseTransport({'type': 'xhttp', 'session_placement': 'bogus'})!;
      final (m4, w4) = t4.toSingbox(TemplateVars.empty);
      expect(m4['session_placement'], 'bogus');
      expect(w4.whereType<XhttpParamResetWarning>(), isEmpty);
    });

    test('extra (URL-encoded JSON) вливается в transport', () {
      // {"scMaxEachPostBytes":"1000000","scMaxConcurrentPosts":100.0,
      //  "scMinPostsIntervalMs":30.0,"xPaddingBytes":"100-1000","noGRPCHeader":false}
      const extra =
          '%7B%22scMaxEachPostBytes%22%3A%221000000%22%2C%22scMaxConcurrentPosts%22'
          '%3A100.0%2C%22scMinPostsIntervalMs%22%3A30.0%2C%22xPaddingBytes%22%3A'
          '%22100-1000%22%2C%22noGRPCHeader%22%3Afalse%7D';
      // Uri.queryParameters сам percent-декодит — эмулируем декодированный extra.
      final decodedExtra = Uri.decodeComponent(extra);
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'packet-up',
        'extra': decodedExtra,
      }) as XhttpTransport;
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, false);
      // числа из extra нормализованы в строку
      expect(t.scMaxEachPostBytes, '1000000');
      expect(t.scMinPostsIntervalMs, '30'); // 30.0 → "30"
      // scMaxConcurrentPosts (legacy) не маппится
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m.containsKey('sc_max_concurrent_posts'), false);
    });

    test('битый extra игнорируется, плоские параметры выживают', () {
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'packet-up',
        'path': '/p',
        'extra': '{not valid json', // обрезанный
      }) as XhttpTransport;
      expect(t.mode, 'packet-up');
      expect(t.path, '/p');
    });

    test('path с ?-хвостом обрезается', () {
      final t = parseTransport({'type': 'xhttp', 'path': '/GaMeOpTiMiZeR?ed=2048'})
          as XhttpTransport;
      expect(t.path, '/GaMeOpTiMiZeR');
    });

    test('sc* float-хвост отбрасывается (30.0 → "30")', () {
      final t = parseTransport({
        'type': 'xhttp',
        'scMinPostsIntervalMs': '30.0',
        'scMaxEachPostBytes': '1000000',
      }) as XhttpTransport;
      expect(t.scMinPostsIntervalMs, '30');
      expect(t.scMaxEachPostBytes, '1000000');
    });

    test('round-trip: parseTransport(transportToQuery(golden)) ≈ golden', () {
      const golden = XhttpTransport(
        host: 'www.example.com',
        path: '/xhttp',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        sessionPlacement: 'header',
        sessionKey: 'X-Session',
        seqPlacement: 'query',
        seqKey: 'x_seq',
        uplinkDataPlacement: 'header',
        uplinkDataKey: 'X-Data',
        uplinkChunkSize: '3000-4000',
        uplinkHttpMethod: 'POST',
        xPaddingObfsMode: true,
        xPaddingKey: 'x_padding',
        xPaddingHeader: 'X-Padding',
        xPaddingPlacement: 'header',
        xPaddingMethod: 'tokenish',
        scMaxEachPostBytes: '1000000',
        scMinPostsIntervalMs: '30',
      );
      final q = transportToQuery(golden);
      final back = parseTransport(q) as XhttpTransport;
      // сравнение по выхлопу toSingbox (= по смыслу spec)
      expect(back.toSingbox(TemplateVars.empty).$1,
          golden.toSingbox(TemplateVars.empty).$1);
    });

    test('toUri пишет только не-дефолтные поля (§8.3 — без раздувания)', () {
      // дефолтная нода: эти значения == дефолт ядра → НЕ должны попасть в query.
      const x = XhttpTransport(
        path: '/',
        sessionPlacement: '', // дефолт path
        uplinkHttpMethod: '', // дефолт POST
        xPaddingObfsMode: false,
      );
      final q = transportToQuery(x);
      expect(q.containsKey('sessionPlacement'), false);
      expect(q.containsKey('uplinkHTTPMethod'), false);
      expect(q.containsKey('xPaddingObfsMode'), false);
    });
  });

  // §399 — состав полей XHTTP общий для трёх веток парсера. До фикса Xray-JSON
  // читала три поля (path/host/mode), sing-box-JSON — шесть, URI — все.
  group('§399 XHTTP: общий состав полей в JSON-ветках', () {
    /// Xray-элемент с одним VLESS-узлом на XHTTP.
    Map<String, dynamic> xrayElement(Map<String, dynamic> xhttpSettings) => {
          'remarks': 'x',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': '1.2.3.4',
                    'port': 443,
                    'users': [
                      {'id': 'u-1', 'encryption': 'none'}
                    ],
                  }
                ],
              },
              'streamSettings': {
                'network': 'xhttp',
                'security': 'none',
                'xhttpSettings': xhttpSettings,
              },
            },
            {'tag': 'direct', 'protocol': 'freedom'},
          ],
        };

    /// sing-box `transport`-объект → разобранный обратно XHTTP-транспорт.
    XhttpTransport singboxTransport(Map<String, dynamic> transport) {
      final node = parseSingboxEntry({
        'type': 'vless',
        'tag': 'n',
        'server': '1.2.3.4',
        'server_port': 443,
        'uuid': 'u-1',
        'transport': transport,
      })! as VlessSpec;
      return node.transport as XhttpTransport;
    }

    XhttpTransport xrayTransport(Map<String, dynamic> xhttpSettings) {
      final nodes = parseXrayElement(xrayElement(xhttpSettings));
      expect(nodes, hasLength(1));
      return (nodes.single as VlessSpec).transport as XhttpTransport;
    }

    // Критерий 1 — узел 188.72.103.4 из SPEC 102-B: сервер ждёт uplink GET'ом,
    // ядро без поля шлёт POST → `unexpected upload status: 400`.
    test('extra.uplinkHTTPMethod=GET + packet-up доезжает до конфига', () {
      final t = xrayTransport({
        'path': '/x',
        'mode': 'packet-up',
        'extra': {
          'uplinkHTTPMethod': 'GET',
          'scMaxBufferedPosts': 30,
          'scMaxEachPostBytes': '1000000',
          'xPaddingBytes': '0-0',
        },
      });
      final (m, w) = t.toSingbox(TemplateVars.empty);
      expect(m['uplink_http_method'], 'GET');
      expect(w, isEmpty);
    });

    // Критерий 2 — узлы 46.243.142.42 / 95.163.232.194: без x_padding_bytes
    // ядро подставляет свой padding, которого сервер не ждёт → 400.
    test('xPaddingBytes "50-150" и "0-0" доезжают дословно из обеих веток', () {
      for (final v in ['50-150', '0-0']) {
        expect(
          xrayTransport({
            'mode': 'stream-one',
            'extra': {'xPaddingBytes': v},
          }).xPaddingBytes,
          v,
        );
        expect(
          singboxTransport({'type': 'xhttp', 'x_padding_bytes': v})
              .xPaddingBytes,
          v,
        );
      }
    });

    // Критерий 3 — эмиттер кладёт значение в конфиг как есть; `1e+06` ядро
    // не разберёт, а число вместо строки ломает схему транспорта.
    test('числа из extra → строки, без экспоненциальной нотации', () {
      final t = xrayTransport({
        'mode': 'packet-up',
        'extra': {
          'scMaxEachPostBytes': 1000000,
          'scMinPostsIntervalMs': 30.0,
          'uplinkChunkSize': 0,
        },
      });
      expect(t.scMaxEachPostBytes, '1000000');
      expect(t.scMinPostsIntervalMs, '30');
      expect(t.uplinkChunkSize, '0');
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m['sc_max_each_post_bytes'], '1000000');
      expect(m['sc_max_each_post_bytes'], isA<String>());
    });

    // Критерий 4 — Xray допускает обе раскладки; при конфликте extra выигрывает.
    test('плоское поле читается; одноимённое в extra его перекрывает', () {
      expect(
        xrayTransport({'xPaddingBytes': '10-20'}).xPaddingBytes,
        '10-20',
      );
      expect(
        xrayTransport({
          'xPaddingBytes': '10-20',
          'extra': {'xPaddingBytes': '50-150'},
        }).xPaddingBytes,
        '50-150',
      );
    });

    // §410 — регрессия v2.21.0 (4PDA #1740…#1765): Xray кладёт в `extra`
    // весь объект транспорта с пустыми незаданными полями; `"mode": ""`
    // затирало плоский `mode=packet-up`, ядро брало `auto` и узел с
    // `uplinkDataPlacement=header` ронял конфиг целиком. Эталон Go —
    // `xhttpLookup`: пустое из extra → откат к плоскому значению.
    test('пустое значение в extra не перекрывает плоское поле (§410)', () {
      final t = xrayTransport({
        'mode': 'packet-up',
        'xPaddingBytes': '10-20',
        'extra': {'mode': '', 'xPaddingBytes': '', 'host': ''},
      });
      expect(t.mode, 'packet-up');
      expect(t.xPaddingBytes, '10-20');
      expect(t.host, '');
    });

    // Xray `SplitHTTPConfig.Build()`: при наличии extra host/path/mode
    // перезаписываются значениями внешнего объекта, даже непустые из extra
    // отбрасываются. Остальные поля extra по-прежнему в приоритете.
    test('extra.host/path/mode не перекрывают плоские даже непустыми (§410)',
        () {
      final t = xrayTransport({
        'mode': 'packet-up',
        'path': '/real',
        'host': 'real.example',
        'xPaddingBytes': '10-20',
        'extra': {
          'mode': 'stream-up',
          'path': '/fake',
          'host': 'fake.example',
          'xPaddingBytes': '500-600',
        },
      });
      expect(t.mode, 'packet-up');
      expect(t.path, '/real');
      expect(t.host, 'real.example');
      expect(t.xPaddingBytes, '500-600', reason: 'не host/path/mode — extra');
    });

    test('пустой член extra.xmux не затирает плоское поле (§410)', () {
      final t = xrayTransport({
        'mode': 'packet-up',
        'xmux': {'maxConcurrency': '16'},
        'extra': {
          'xmux': {'maxConcurrency': ''},
        },
      });
      expect(t.maxConcurrency, '16');
    });

    // Ссылка cumirum (#1755) дословно: mode=packet-up плоско, в extra
    // "mode":"" + uplinkDataPlacement=header + uplinkHTTPMethod=GET.
    test('ссылка из подписки с extra.mode="" → mode packet-up в конфиге (§410)',
        () {
      const uri =
          'vless://423b1d79-08c4-403f-9d5e-c541f791b55f@178.176.128.128:443'
          '?alpn=h2%2Chttp%2F1.1&encryption=none'
          '&extra=%7B%22host%22%3A%22%22%2C%22path%22%3A%22%2F%22%2C%22mode%22'
          '%3A%22%22%2C%22headers%22%3Anull%2C%22xPaddingBytes%22%3A%220%22%2C'
          '%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingKey%22%3A%22%22%2C'
          '%22xPaddingHeader%22%3A%22%22%2C%22xPaddingPlacement%22%3A%22%22%2C'
          '%22xPaddingMethod%22%3A%22%22%2C%22uplinkHTTPMethod%22%3A%22GET%22'
          '%2C%22sessionIDPlacement%22%3A%22cookie%22%2C%22sessionIDKey%22%3A'
          '%22media_sid%22%2C%22sessionIDTable%22%3A%22%22%2C%22sessionIDLength'
          '%22%3A%220%22%2C%22seqPlacement%22%3A%22query%22%2C%22seqKey%22%3A'
          '%22offset%22%2C%22uplinkDataPlacement%22%3A%22header%22%2C'
          '%22uplinkDataKey%22%3A%22X-Playback-Token%22%2C%22uplinkChunkSize'
          '%22%3A%220%22%2C%22noGRPCHeader%22%3Afalse%2C%22noSSEHeader%22%3A'
          'true%2C%22scMaxEachPostBytes%22%3A%22131072-262144%22%2C'
          '%22scMinPostsIntervalMs%22%3A%225-10%22%2C%22scMaxBufferedPosts%22'
          '%3A12%2C%22scStreamUpServerSecs%22%3A%221-2%22%2C'
          '%22serverMaxHeaderBytes%22%3A0%2C%22xmux%22%3A%7B%22maxConcurrency'
          '%22%3A%220%22%2C%22maxConnections%22%3A%220%22%2C%22cMaxReuseTimes'
          '%22%3A%220%22%2C%22hMaxRequestTimes%22%3A%220%22%2C'
          '%22hMaxReusableSecs%22%3A%220%22%2C%22hKeepAlivePeriod%22%3A0%7D%2C'
          '%22downloadSettings%22%3Anull%2C%22extra%22%3Anull%7D'
          '&fp=qq&host=media.morphai.cc&mode=packet-up'
          '&path=%2Fhls%2Fv2%2Ftrack%2F8e31c750%2F&security=tls'
          '&sni=media.morphai.cc&type=xhttp#t';
      final node = parseUri(uri);
      expect(node, isA<VlessSpec>());
      final t = (node! as VlessSpec).transport as XhttpTransport;
      expect(t.mode, 'packet-up');
      expect(t.host, 'media.morphai.cc');
      // path: в extra лежит "/", плоско — "/hls/…". Xray (SplitHTTPConfig
      // .Build) host/path/mode берёт только из внешнего объекта; с "/"
      // сервер отвечал 404 на uplink (device-verified на эмуляторе).
      expect(t.path, '/hls/v2/track/8e31c750/');
      final (m, w) = t.toSingbox(TemplateVars.empty);
      expect(m['mode'], 'packet-up');
      expect(m['uplink_data_placement'], 'header');
      expect(m['uplink_http_method'], 'GET');
      // sessionIDPlacement/sessionIDKey — ключи вне контракта (Go читает
      // только session_placement/sessionPlacement), сюда не доезжают.
      expect(m.containsKey('session_placement'), false);
      expect(w, isEmpty);
    });

    // Критерий 5 — R6: деградация вместо поломки.
    test('битый / не-объектный extra не роняет разбор узла', () {
      for (final bad in <Object>['не-json', <Object>[], 5, true]) {
        final t = xrayTransport({
          'path': '/p',
          'mode': 'packet-up',
          'extra': bad,
        });
        expect(t.path, '/p');
        expect(t.mode, 'packet-up');
        expect(t.toSingbox(TemplateVars.empty).$2, isEmpty);
      }
    });

    // Критерий 6 — round-trip через sing-box JSON. До фикса «открыл ноду в
    // JSON-редакторе → сохранил» молча срезало 15 полей §127.
    test('round-trip NodeSpec → sing-box JSON → NodeSpec не теряет полей', () {
      const golden = XhttpTransport(
        host: 'www.example.com',
        path: '/xhttp',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        headers: {'User-Agent': 'x'},
        sessionPlacement: 'header',
        sessionKey: 'X-Session',
        seqPlacement: 'query',
        seqKey: 'x_seq',
        uplinkDataPlacement: 'header',
        uplinkDataKey: 'X-Data',
        uplinkChunkSize: '3000-4000',
        uplinkHttpMethod: 'GET',
        xPaddingObfsMode: true,
        xPaddingKey: 'x_padding',
        xPaddingHeader: 'X-Padding',
        xPaddingPlacement: 'header',
        xPaddingMethod: 'tokenish',
        scMaxEachPostBytes: '1000000',
        scMinPostsIntervalMs: '30',
      );
      final node = VlessSpec(
        id: 'id-1',
        tag: 'n',
        label: 'n',
        server: '1.2.3.4',
        port: 443,
        rawUri: '',
        uuid: 'u-1',
        transport: golden,
      );
      final back = parseSingboxEntry(node.emit(TemplateVars.empty).map)!;
      final backTransport = (back as VlessSpec).transport as XhttpTransport;
      expect(
        backTransport.toSingbox(TemplateVars.empty).$1,
        golden.toSingbox(TemplateVars.empty).$1,
      );
    });

    // Критерий 7 — расхождение схем между ветками. Тест падает, когда поле
    // добавлено в модель/эмиттер, но какая-то ветка его не читает.
    test('три ветки читают один и тот же набор ключей', () {
      // Эталон — выхлоп эмиттера для ноды со всеми заполненными полями.
      const golden = XhttpTransport(
        host: 'h',
        path: '/p',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        sessionPlacement: 'header',
        sessionKey: 'X-Session',
        seqPlacement: 'query',
        seqKey: 'x_seq',
        uplinkDataPlacement: 'header',
        uplinkDataKey: 'X-Data',
        uplinkChunkSize: '3000-4000',
        uplinkHttpMethod: 'GET',
        xPaddingObfsMode: true,
        xPaddingKey: 'x_padding',
        xPaddingHeader: 'X-Padding',
        xPaddingPlacement: 'header',
        xPaddingMethod: 'tokenish',
        scMaxEachPostBytes: '1000000',
        scMinPostsIntervalMs: '30',
        scStreamUpServerSecs: '20-80',
        scMaxBufferedPosts: 30,
        noSseHeader: true,
        maxConnections: '1',
        maxConcurrency: '16-32',
        cMaxReuseTimes: '5',
        hMaxRequestTimes: '600',
        hMaxReusableSecs: '1800',
        hKeepAlivePeriod: 30,
      );
      final expected = golden.toSingbox(TemplateVars.empty).$1;

      // Ветка 1 — URI (camelCase query).
      final viaUri = parseTransport(transportToQuery(golden))!;
      expect(viaUri.toSingbox(TemplateVars.empty).$1, expected,
          reason: 'URI-ветка потеряла поле');

      // Ветка 2 — Xray-JSON: те же значения, но snake_case ключами в extra.
      final viaXray = xrayTransport({
        'host': 'h',
        'path': '/p',
        'mode': 'packet-up',
        'extra': Map<String, dynamic>.from(expected)..remove('type'),
      });
      expect(viaXray.toSingbox(TemplateVars.empty).$1, expected,
          reason: 'Xray-JSON-ветка потеряла поле');

      // Ветка 3 — sing-box JSON: выхлоп эмиттера, поданный обратно.
      expect(singboxTransport(expected).toSingbox(TemplateVars.empty).$1,
          expected,
          reason: 'sing-box-JSON-ветка потеряла поле');
    });

    // Паритет с Go (SPEC 102 R2): Xray пишет xmux в `extra` вложенным
    // объектом. Обе формы обязаны давать один и тот же транспорт — иначе один
    // и тот же узел читается по-разному в зависимости от формы записи.
    test('extra={"xmux":{…}} эквивалентен плоским ключам', () {
      final nested = parseTransport({
        'type': 'xhttp',
        'path': '/p',
        'extra':
            '{"xmux":{"maxConnections":1,"maxConcurrency":"16-32","hKeepAlivePeriod":30},"scMaxBufferedPosts":30}',
      })! as XhttpTransport;
      final flat = parseTransport({
        'type': 'xhttp',
        'path': '/p',
        'maxConnections': '1',
        'maxConcurrency': '16-32',
        'hKeepAlivePeriod': '30',
        'scMaxBufferedPosts': '30',
      })! as XhttpTransport;

      final want = {
        'type': 'xhttp',
        'path': '/p',
        'sc_max_buffered_posts': 30,
        'xmux': {
          'max_concurrency': '16-32',
          'max_connections': '1',
          'h_keep_alive_period': 30,
        },
      };
      expect(nested.toSingbox(TemplateVars.empty).$1, want);
      expect(flat.toSingbox(TemplateVars.empty).$1, want);
    });

    // Нуль у int-полей значащий: «не задано» кодируется как -1, поэтому
    // scMaxBufferedPosts=0 обязан доехать до конфига, а не исчезнуть.
    test('int-поля: 0 эмитится, отсутствие — нет', () {
      final zero = parseTransport({
        'type': 'xhttp',
        'scMaxBufferedPosts': '0',
        'hKeepAlivePeriod': '0',
      })! as XhttpTransport;
      final m = zero.toSingbox(TemplateVars.empty).$1;
      expect(m['sc_max_buffered_posts'], 0);
      expect((m['xmux'] as Map)['h_keep_alive_period'], 0);

      final absent = parseTransport({'type': 'xhttp'})! as XhttpTransport;
      final m2 = absent.toSingbox(TemplateVars.empty).$1;
      expect(m2.containsKey('sc_max_buffered_posts'), isFalse);
      expect(m2.containsKey('xmux'), isFalse,
          reason: 'пустой xmux не должен эмититься');
    });
  });

  // §416 — форумная жалоба 03.09: узел подписки несёт
  // uplink_data_placement=header БЕЗ mode, ядро отвергает ВЕСЬ конфиг
  // («uplink_data_placement can be header only in packet-up mode»), VPN не
  // поднимается. Guard стоит на эмиссии XhttpTransport — единственной точке,
  // общей для всех веток источника.
  group('§416 XHTTP: header-placement требует packet-up', () {
    test('placement=header без mode → дописан mode: packet-up + warning', () {
      final (m, w) = const XhttpTransport(
        path: '/hls/v2/track/8e31c750/',
        host: 'media.morphai.cc',
        uplinkDataPlacement: 'header',
      ).toSingbox(TemplateVars.empty);
      expect(m['mode'], 'packet-up');
      expect(m['uplink_data_placement'], 'header');
      expect(w, const [XhttpModeForcedPacketUpWarning()]);
    });

    test('регистр и пробелы нормализуются при сверке, значение — как есть',
        () {
      final (m, w) = const XhttpTransport(
        uplinkDataPlacement: ' Header ',
      ).toSingbox(TemplateVars.empty);
      expect(m['mode'], 'packet-up');
      expect(m['uplink_data_placement'], ' Header ',
          reason: 'placement уходит в ядро дословно, нормализация — только '
              'для сверки');
      expect(w, const [XhttpModeForcedPacketUpWarning()]);
    });

    test('placement=header + mode=packet-up → ничего не меняется, тихо', () {
      final (m, w) = const XhttpTransport(
        mode: 'packet-up',
        uplinkDataPlacement: 'header',
      ).toSingbox(TemplateVars.empty);
      expect(m['mode'], 'packet-up');
      expect(m['uplink_data_placement'], 'header');
      expect(w, isEmpty);
    });

    // §169 — отбрасывать, а не подгонять молча: явный чужой mode не
    // переписываем (это сменило бы wire-протокол узла), снимаем placement.
    test('placement=header + mode=stream-one → placement снят, mode цел', () {
      final (m, w) = const XhttpTransport(
        mode: 'stream-one',
        uplinkDataPlacement: 'header',
      ).toSingbox(TemplateVars.empty);
      expect(m['mode'], 'stream-one');
      expect(m.containsKey('uplink_data_placement'), isFalse);
      expect(w, const [
        XhttpParamResetWarning(
            'uplink_data_placement', XhttpResetReason.placementRequiresPacketUp)
      ]);
    });

    test('placement не header (body/cookie/auto) — узел не трогаем', () {
      for (final p in ['body', 'auto', 'cookie']) {
        final (m, w) = XhttpTransport(
          mode: 'stream-one',
          uplinkDataPlacement: p,
        ).toSingbox(TemplateVars.empty);
        expect(m['mode'], 'stream-one', reason: p);
        expect(m['uplink_data_placement'], p, reason: p);
        expect(w, isEmpty, reason: p);
      }
    });

    test('узла без placement guard не касается', () {
      final (m, w) = const XhttpTransport(path: '/x')
          .toSingbox(TemplateVars.empty);
      expect(m.containsKey('mode'), isFalse);
      expect(m.containsKey('uplink_data_placement'), isFalse);
      expect(w, isEmpty);
    });

    test('ссылка из жалобы: header без mode через URI-ветку', () {
      final t = parseTransport({
        'type': 'xhttp',
        'host': 'media.morphai.cc',
        'path': '/hls/v2/track/8e31c750/',
        'uplinkDataPlacement': 'header',
        'uplinkHTTPMethod': 'GET',
      })! as XhttpTransport;
      expect(t.mode, '', reason: 'парсер mode не выдумывает');
      final (m, w) = t.toSingbox(TemplateVars.empty);
      expect(m['mode'], 'packet-up');
      expect(m['uplink_data_placement'], 'header');
      expect(m['uplink_http_method'], 'GET');
      expect(w, const [XhttpModeForcedPacketUpWarning()]);
    });

    test('эмиссия детерминирована: два прогона байт в байт', () {
      const t = XhttpTransport(
        path: '/p',
        host: 'h',
        uplinkDataPlacement: 'header',
        uplinkHttpMethod: 'GET',
        maxConnections: '1',
      );
      final a = t.toSingbox(TemplateVars.empty);
      final b = t.toSingbox(TemplateVars.empty);
      expect(jsonEncode(a.$1), jsonEncode(b.$1));
      expect(a.$2, b.$2);
    });
  });
}
