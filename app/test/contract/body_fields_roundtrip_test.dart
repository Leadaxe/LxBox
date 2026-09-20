/// §476 — страж: каждое поле реестра переживает круг «тело → модель → emit».
///
/// `parseSingboxEntry` читает поля тела вручную, по одному. Поле, которое автор
/// ветки забыл прочитать, исчезает молча: ни ошибки, ни предупреждения, а
/// эмиттер писать его умеет — значит человек вписал поле в JSON-вкладке,
/// сохранил, и узел ушёл в ядро без него. За один день так нашлись `encryption`
/// (vless), `plugin`/`plugin_opts` (shadowsocks), `quic` (naive),
/// `host_key_algorithms` (ssh), `min_idle_session` строкой (anytls) — каждый раз
/// случайно, по ходу другой работы.
///
/// У лаунчера класса нет вовсе: тело идёт картой через реестр, списка читаемых
/// ключей не существует. У нас он есть — это и есть `parseSingboxEntry`, — и
/// стережёт его полноту этот тест.
///
/// **Круг идёт ТЕМ ЖЕ путём, что конвейер** (`mappers/uri_pipeline.dart`):
/// санитайзер по реестру с выключенными гейтами ядра, затем
/// `parseSingboxEntry`, затем `emit()`. Сравнение — с телом ПОСЛЕ санитайзера:
/// канонизацию (`normalize`, listable → список, `default_when`) объявляет сам
/// реестр, и спорить с ней тесту нечем.
///
/// **Узел `origin.kind: json` сюда не относится** (§455): он идёт в ядро
/// ДОСЛОВНО, мимо модели, и терять ему нечего. Искать здесь его правила не надо.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

import 'body_field_generator.dart';

/// Реестр — из ЗЕРКАЛА в git (`assets/contract`), а не из вендоренной копии
/// `app/contract`: страж обязан работать на CI и у того, кто репозиторий
/// лаунчера в глаза не видел. Гейта «контракт не синхронизирован» здесь нет
/// намеренно — пропущенный страж не стережёт.
const _registryRoot = 'assets/contract';

/// Версия ядра при разборе — как у конвейера: гейты `min_core` выключены.
const _kParseTimeCore = '0.0.0';

/// Протоколы, чей узел приложение строит из тела. `chain`, `group` и
/// `tailscale` сюда не входят: у первых двух тела узла нет (это селектор и
/// цепочка, их собирает приложение), `tailscale` — endpoint без сервера
/// (§435), и круга «тело → модель → emit» у него нет.
const _kSchemes = <String>[
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'hysteria2',
  'naive',
  'tuic',
  'anytls',
  'socks',
  'http',
  'ssh',
  'wireguard',
  'masque',
];

/// Поля, которые круг НЕ переживает осознанно: `«схема.путь» → причина`.
///
/// Ключ — `«схема.путь»`, либо `«*.путь»` для правила, общего всем схемам,
/// либо голый путь. Запись без причины — падение. Запись, ставшая лишней
/// (поле уже переживает круг), — тоже падение: список не протухает.
///
/// Три рода записей, и путать их нельзя:
///
/// 1. **приложение выставляет ключ само** — тело автора его не несёт;
/// 2. **поля нет в модели И в эмиттере** — это не потеря круга, а
///    неподдержанная возможность ядра. Такое поле не «теряется на Save»: его
///    не было и не будет, пока кто-то не заведёт его осознанно. Страж их
///    числит здесь, чтобы отличать от настоящего класса §472 — поля, которое
///    эмиттер ПИШЕТ, а разбор не читает;
/// 3. **ждёт другой задачи** — §475 у `socks.version`, шаг 7 фичи 472 у
///    wireguard и masque.
const kNotModelled = <String, String>{
  // --- 1. приложение выставляет ключ само -------------------------------
  '*.detour': 'ставит сборка конфига из Направлений и цепочек, не тело узла',
  '*.domain_resolver': 'ставит сборка конфига (§263: два резолвера), не тело',

  // --- 2. ядро принимает, приложение не поддерживает --------------------
  //
  // Общие dial-поля ядра (`dialer.json`). Модель несёт из них ровно один
  // `tcp_keep_alive` (§453) — остальные не читаются и не эмитятся.
  '*.bind_interface': 'dial-поле ядра: ни в модели, ни в эмиттере (не §453)',
  '*.inet4_bind_address': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.inet6_bind_address': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.connect_timeout': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.tcp_fast_open': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.udp_fragment': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.network_strategy': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.network_type': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.fallback_network_type': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.fallback_delay': 'dial-поле ядра: ни в модели, ни в эмиттере',
  '*.disable_tcp_keep_alive': 'dial-поле ядра: ни в модели, ни в эмиттере',
  // §453 завёл TCP keep-alive только НОСИТЕЛЯМ TCP: у hysteria2, tuic,
  // wireguard и masque конструктор его не принимает вовсе — соединение у них
  // QUIC/UDP, и TCP-таймеров там нет. Значит поле не «теряется», а не
  // относится к узлу.
  'hysteria2.tcp_keep_alive': '§453: не-носитель TCP (QUIC), поля нет в модели',
  'hysteria2.tcp_keep_alive_interval': '§453: не-носитель TCP (QUIC)',
  'tuic.tcp_keep_alive': '§453: не-носитель TCP (QUIC), поля нет в модели',
  'tuic.tcp_keep_alive_interval': '§453: не-носитель TCP (QUIC)',
  '*.network': 'tcp/udp-ограничение узла: ни в модели, ни в эмиттере',

  // kTLS ядро принимает только на Linux; Android им не является в смысле
  // этого поля — ядро LxBox его не строит.
  'tls.kernel_tx': 'kTLS: ядро LxBox на Android не поддерживает',
  'tls.kernel_rx': 'kTLS: ядро LxBox на Android не поддерживает',

  // Мультиплекс (`multiplex.json`) приложение не поддерживает целиком: ни
  // модели, ни эмиссии. Заводить его — отдельная задача с UI.
  '*.multiplex': 'мультиплекс не поддержан: ни модели, ни эмиссии',

  // Поля транспортов, которых нет в `TransportSpec`. Ключ БЕЗ сегмента
  // варианта: в теле узла транспорт лежит одной картой (`transport.path`), и
  // имя варианта в путь не входит — оно только дискриминатор `transport.type`.
  'transport.idle_timeout': 'поля нет в Grpc/HttpTransport и в эмиссии',
  'transport.ping_timeout': 'поля нет в Grpc/HttpTransport и в эмиссии',
  'transport.permit_without_stream': 'поля нет в GrpcTransport и в эмиссии',
  'transport.method': 'поля нет в HttpTransport и в эмиссии',
  'transport.session_table': 'поля нет в XhttpTransport и в эмиссии',
  'transport.session_length': 'поля нет в XhttpTransport и в эмиссии',
  'transport.sc_max_concurrent_posts': 'поля нет в XhttpTransport',
  'transport.server_max_header_bytes': 'поля нет в XhttpTransport',
  // QUIC-транспорт ядро знает, приложение его не строит вовсе: `TransportSpec`
  // такого варианта не имеет, и `_transportFromSingbox` отдаёт `null`, отчего
  // пропадает и сам дискриминатор `transport.type`.
  'transport.type': 'вариант quic не поддержан: его нет в TransportSpec, '
      'и вместе с ним пропадает сам дискриминатор',

  // Тюнинг QUIC у hysteria2/tuic/naive — ни модели, ни эмиссии.
  '*.connection_receive_window': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.stream_receive_window': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.quic_session_receive_window': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.max_concurrent_streams': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.disable_path_mtu_discovery': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.initial_packet_size': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.keep_alive_period': 'тюнинг QUIC: ни модели, ни эмиссии',
  '*.idle_timeout': 'тюнинг QUIC: ни модели, ни эмиссии',
  'hysteria2.bbr_profile': 'профиль BBR: ни модели, ни эмиссии',
  'hysteria2.brutal_debug': 'отладка Brutal: ни модели, ни эмиссии',
  'hysteria2.disable_chrome_parrot': 'мимикрия Chrome: ни модели, ни эмиссии',
  'hysteria2.hop_interval': 'port hopping: интервала нет в модели',
  'hysteria2.hop_interval_max': 'port hopping: интервала нет в модели',
  'naive.insecure_concurrency': 'поля нет в NaiveSpec и в эмиссии',
  'tuic.udp_over_stream': 'поля нет в TuicSpec и в эмиссии',

  // UDP-over-TCP (`udp_over_tcp`) — ни модели, ни эмиссии ни у одной схемы.
  '*.udp_over_tcp': 'UDP-over-TCP не поддержан: ни модели, ни эмиссии',

  // Прочее по схемам.
  'vmess.packet_encoding': 'у VmessSpec поля нет (есть только у VlessSpec), '
      'эмиттер vmess его не пишет',
  'vmess.authenticated_length': 'поля нет в VmessSpec и в эмиссии',
  'vmess.global_padding': 'поля нет в VmessSpec и в эмиссии',
  'anytls.client_metadata': 'поля нет в AnyTlsSpec и в эмиссии',
  'ssh.client_version': 'поля нет в SshSpec и в эмиссии',
  'ssh.cipher': 'список шифров: поля нет в SshSpec и в эмиссии',
  'ssh.kex_algorithm': 'список KEX: поля нет в SshSpec и в эмиссии',
  'ssh.mac': 'список MAC: поля нет в SshSpec и в эмиссии',
  'ssh.private_key_path': 'путь к ключу: поля нет в SshSpec и в эмиссии',
  // `private_key` у ssh реестр числит `listable_string` — модель держит
  // строку, и списочная форма схлопывается. Значение не теряется, но круг
  // сравнивает форму, а не смысл.
  'ssh.private_key': 'реестр зовёт поле listable_string, модель держит строку',

  // --- 3. ждёт другой задачи --------------------------------------------
  // §475 ЗАКРЫТ: записи `socks.version` здесь больше нет — ветка socks
  // `parseSingboxEntry` поле читает, модель хранит, `emitSocks` пишет. Страж
  // это и требовал: запись, ставшая лишней, роняет тест.

  // Шаг 7 фичи 472 переводит wireguard и masque на единый конвейер; их ветки
  // разбора сейчас правит соседний заход, и трогать их здесь нельзя.
  // ПОСЛЕ шага 7 список пересмотреть: что он починил — отсюда снять (страж
  // сам скажет, лишняя запись = падение).
  'wireguard.system': 'шаг 7 фичи 472, сверить после',
  'wireguard.name': 'шаг 7 фичи 472, сверить после',
  'wireguard.listen_port': 'шаг 7 фичи 472, сверить после',
  'wireguard.workers': 'шаг 7 фичи 472, сверить после',
  'wireguard.udp_timeout': 'шаг 7 фичи 472, сверить после',
  'wireguard.udp_mapping': 'шаг 7 фичи 472, сверить после',
  'wireguard.udp_filtering': 'шаг 7 фичи 472, сверить после',
  'wireguard.udp_nat_max': 'шаг 7 фичи 472, сверить после',
  'wireguard.tcp_keep_alive': '§453: не-носитель TCP (UDP-туннель)',
  'wireguard.tcp_keep_alive_interval': '§453: не-носитель TCP (UDP-туннель)',
  // Ключи WG (private_key, header_protection_key, ключи пира) отсюда СНЯТЫ
  // контрактом 1.1.22: нормализация `base64_std` переехала из маппера в
  // `body.fields` (D133-22), и канон теперь ставит САНИТАЙЗЕР — на всех
  // входах, а не только там, где значение пришло ссылкой. Обе стороны круга
  // канонизируются одинаково, и поле переживает круг как любое другое.

  'masque.tls': 'шаг 7 фичи 472, сверить после',
  'masque.sni': 'шаг 7 фичи 472: плоские legacy-ключи не принимаем (§393)',
  'masque.skip_cert_verify': 'шаг 7 фичи 472: плоский legacy-ключ (§393)',
  'masque.network': 'шаг 7 фичи 472: плоский legacy-ключ (§393)',
  'masque.network_list': 'шаг 7 фичи 472, сверить после',
  'masque.fragment': 'шаг 7 фичи 472, сверить после',
  'masque.fragment_fallback_delay': 'шаг 7 фичи 472, сверить после',
  'masque.record_fragment': 'шаг 7 фичи 472, сверить после',
  'masque.ipv6': 'шаг 7 фичи 472: адрес едет через localAddresses',
  'masque.uri': 'шаг 7 фичи 472, сверить после',
  'masque.tcp_keep_alive': '§453: не-носитель TCP (QUIC)',
  'masque.tcp_keep_alive_interval': '§453: не-носитель TCP (QUIC)',
};

/// Круг одного тела: санитайзер → модель → emit. `null` — узел не построился.
({Map<String, dynamic> sanitized, Map<String, dynamic> emitted})? _roundTrip(
  Map<String, dynamic> body,
) {
  final res = RegistrySanitizer.sanitize(
    Map<String, dynamic>.from(body),
    scheme: body['type'] as String,
    coreVersion: _kParseTimeCore,
    applyCoreGates: false,
  );
  final clean = res.body;
  if (clean == null) return null;
  // `tag` ставит конвейер перед вызовом модели — иначе узел безымянен.
  final withTag = <String, dynamic>{...clean, 'tag': 'roundtrip'};
  final node = parseSingboxEntry(withTag);
  if (node == null) return null;
  return (sanitized: clean, emitted: node.emit(TemplateVars.empty).map);
}

/// Все пути-листья карты: `tls.reality.short_id`, `peers[0].address`.
Set<String> _leafPaths(Object? v, String prefix) {
  final out = <String>{};
  if (v is Map) {
    if (v.isEmpty) out.add(prefix);
    for (final e in v.entries) {
      final p = prefix.isEmpty ? '${e.key}' : '$prefix.${e.key}';
      out.addAll(_leafPaths(e.value, p));
    }
    return out;
  }
  if (v is List) {
    if (v.isEmpty) out.add(prefix);
    for (var i = 0; i < v.length; i++) {
      out.addAll(_leafPaths(v[i], '$prefix[$i]'));
    }
    return out;
  }
  out.add(prefix);
  return out;
}

Object? _at(Object? root, String path) {
  Object? cur = root;
  for (final seg in path.split('.')) {
    final m = RegExp(r'^(.*?)\[(\d+)\]$').firstMatch(seg);
    if (m != null) {
      if (cur is! Map) return null;
      cur = cur[m.group(1)];
      if (cur is! List) return null;
      final i = int.parse(m.group(2)!);
      if (i >= cur.length) return null;
      cur = cur[i];
      continue;
    }
    if (cur is! Map || !cur.containsKey(seg)) return null;
    cur = cur[seg];
  }
  return cur;
}

/// Запрещает ли реестр поле этой схеме — тогда его отсутствие в теле есть
/// исполнение правила, а не пробел покрытия.
bool _forbiddenByRegistry(String scheme, String path) =>
    forbiddenByRegistry(scheme, path);

/// Причина, по которой поле числится немоделируемым; `null` — не числится.
///
/// Запись покрывает и ВЕТКУ: `*.multiplex` отвечает за весь блок вместе с
/// `multiplex.brutal.up_mbps`. Иначе список пришлось бы вести полем в поле —
/// а не поддержан там весь блок целиком, и дробить причину не на чем.
///
/// Ключ ищется от самого точного к самому общему: `«схема.путь»`, `«*.путь»`,
/// голый путь — и то же для каждого родителя пути.
String? _notModelledReason(String scheme, String path) {
  var probe = path;
  while (true) {
    final hit = kNotModelled['$scheme.$probe'] ??
        kNotModelled['*.$probe'] ??
        kNotModelled[probe];
    if (hit != null) return hit;
    final cut = probe.lastIndexOf('.');
    if (cut < 0) return null;
    probe = probe.substring(0, cut);
  }
}

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
  });

  test('зеркало реестра на месте — страж не имеет права молчать', () {
    expect(Directory('$_registryRoot/registry').existsSync(), isTrue,
        reason: 'страж §476 работает от зеркала в git, без копии app/contract');
    expect(ContractRegistry.I.isLoaded, isTrue);
  });

  group('§476 — каждое поле схемы попадает хотя бы в одно тело', () {
    for (final scheme in _kSchemes) {
      test(scheme, () {
        final variants = generateBodies(scheme);
        expect(variants, isNotEmpty, reason: 'схемы $scheme нет в реестре');
        final covered = <String>{};
        for (final v in variants) {
          covered.addAll(v.covered);
        }
        final all = allFieldPaths(scheme);
        // Поля, которые в тело этой схемы не кладутся осознанно:
        //   • запрещённые самим реестром (`forbidden_for`/`allowed_for`) —
        //     у naive это почти весь блок TLS, у QUIC-схем `utls`/`reality`;
        //     их отсутствие и есть исполнение правила, а не пробел стража;
        //   • числящиеся в [kNotModelled] с причиной.
        final missing = all
            .where((p) => !covered.contains(p))
            .where((p) => !_forbiddenByRegistry(scheme, p))
            .where((p) => _notModelledReason(scheme, p) == null)
            .toList()
          ..sort();
        expect(missing, isEmpty,
            reason: 'поля $scheme не попали ни в одно тело — круг их не '
                'проверяет: ${missing.join(', ')}');
      });
    }
  });

  group('§476 — поле тела переживает круг «тело → модель → emit»', () {
    for (final scheme in _kSchemes) {
      test(scheme, () {
        final variants = generateBodies(scheme);
        final losses = <String>[];
        for (final v in variants) {
          final r = _roundTrip(v.body);
          if (r == null) {
            fail('${v.scheme}/${v.name}: узел не построился из ПОЛНОГО тела — '
                'это либо потерянное required-поле, либо ошибка генератора');
          }
          for (final path in _leafPaths(r.sanitized, '')) {
            if (path.isEmpty || path == 'type' || path == 'tag') continue;
            final want = _at(r.sanitized, path);
            final got = _at(r.emitted, path);
            if (got == want) continue;
            final field = path.replaceAll(RegExp(r'\[\d+\]'), '');
            if (_notModelledReason(scheme, field) != null) continue;
            losses.add('$path: было ${_show(want)}, стало ${_show(got)} '
                '(тело ${v.name})');
          }
        }
        expect(losses, isEmpty,
            reason: 'разбор $scheme теряет поля тела:\n  ${losses.join('\n  ')}');
      });
    }
  });

  test('§476 — kNotModelled: причины на месте, лишних записей нет', () {
    for (final e in kNotModelled.entries) {
      expect(e.value.trim(), isNotEmpty,
          reason: 'запись ${e.key} без причины');
    }

    // Лишняя запись: поле уже переживает круг. Список обязан не протухать —
    // иначе он прикроет починенный дефект от следующей потери в том же поле.
    final used = <String>{};

    /// Отметить запись, ОПРАВДАВШУЮ себя на этом поле — тем же поиском от
    /// точного к общему, что и [_notModelledReason].
    void markUsed(String scheme, String path) {
      var probe = path;
      while (true) {
        for (final key in ['$scheme.$probe', '*.$probe', probe]) {
          if (kNotModelled.containsKey(key)) {
            used.add(key);
            return;
          }
        }
        final cut = probe.lastIndexOf('.');
        if (cut < 0) return;
        probe = probe.substring(0, cut);
      }
    }

    for (final scheme in _kSchemes) {
      final all = allFieldPaths(scheme);
      final covered = <String>{};
      for (final v in generateBodies(scheme)) {
        covered.addAll(v.covered);
        final r = _roundTrip(v.body);
        if (r == null) continue;
        for (final path in _leafPaths(r.sanitized, '')) {
          if (path.isEmpty) continue;
          if (_at(r.emitted, path) == _at(r.sanitized, path)) continue;
          markUsed(scheme, path.replaceAll(RegExp(r'\[\d+\]'), ''));
        }
      }
      // Поле, которого генератор не кладёт вовсе (запрещено схемой), тоже
      // оправдывает запись: круг его не проверяет.
      for (final p in all.difference(covered)) {
        markUsed(scheme, p);
      }
    }
    final stale = kNotModelled.keys.where((k) => !used.contains(k)).toList()
      ..sort();
    expect(stale, isEmpty,
        reason: 'записи kNotModelled стали лишними — поле переживает круг, '
            'запись пора снять: ${stale.join(', ')}');
  });
}

String _show(Object? v) => v == null ? '<нет>' : '$v';
