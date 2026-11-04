import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §480 волна W4 — секции-мапперы hysteria2 / tuic / masque / wireguard и
/// INI, пока движок их ещё не исполняет.
///
/// Тест держит ФОРМУ секций: пока таблицы лежат данными, единственное, что
/// отличает «написано по замороженной грамматике» от «написано как
/// придумалось», — набор атрибутов и их значения. Когда движок придёт,
/// расхождение формы всплыло бы отказом загрузчика на старте разбора, то есть
/// у пользователя, а не здесь.
///
/// Эталон формы — исполняемые секции лаунчера (контракт 1.1.13, `trojan.json`
/// на `8cc6ac69`) и `PRIMITIVES.md` §0 (FROZEN-имена). Сверки по
/// `registry_mapper.schema.json` тут НЕТ намеренно: схема 1.1.13 отстаёт от
/// собственных данных — `trojan.json` лаунчера не проходит её на трёх местах
/// (`userinfo.impl`, `emit.param_order` строкой, `unknown_key.impl`).
/// Нормативны данные, и проверять секции схемой значило бы держать их в форме,
/// которой у эталона нет.
void main() {
  Map<String, dynamic> load(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

  Map<String, dynamic> section(String path, String kind) {
    final mappers = (load(path)['mappers'] as Map).cast<String, dynamic>();
    return (mappers[kind] as Map).cast<String, dynamic>();
  }

  /// Секции волны: имя → файл секции.
  ///
  /// Контракт 1.1.22 забрал hysteria2, tuic и masque В РЕЕСТР, и черновых
  /// копий у них больше нет: загрузчик при исполняемой секции реестра брал бы
  /// реестр, а копия молча протухала бы вторым источником правды. Форму тех же
  /// секций тест держит по ЗЕРКАЛУ реестра — проверять её не перестаём оттого,
  /// что файл переехал. У wireguard секции в реестре нет, черновик остаётся.
  const uriSections = <String, String>{
    'hysteria2': 'assets/contract/registry/protocols/hysteria2.json',
    'tuic': 'assets/contract/registry/protocols/tuic.json',
    'masque': 'assets/contract/registry/protocols/masque.json',
    // Секция wireguard приехала РЕЕСТРОМ (контракт 1.1.23+), и форму
    // проверяем у него: наш черновик стал тонким оверлеем и обязательных
    // атрибутов секции не несёт — он их и не должен нести.
    'wireguard': 'assets/contract/registry/protocols/wireguard.json',
  };

  group('§480 W4 — форма секций uri', () {
    test('ровно одна форма по умолчанию на секцию', () {
      for (final e in uriSections.entries) {
        final forms = (section(e.value, 'uri')['forms'] as List).cast<Map>();
        final defaults = forms.where(
          (f) => ((f['detect'] as Map?)?['default'] as bool?) ?? false,
        );
        expect(defaults.length, 1, reason: e.key);
      }
    });

    test('у каждой записи таблицы есть source — единственный способ получить '
        'значение (PRIMITIVES §1.1)', () {
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        for (final p in params.entries) {
          expect((p.value as Map)['source'], isNotNull,
              reason: '${e.key}.${p.key}');
        }
      }
    });

    test(r'служебная запись ($-префикс) не имеет maps_to (PRIMITIVES §0.7)',
        () {
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        for (final p in params.entries) {
          if (!p.key.startsWith(r'$')) continue;
          expect((p.value as Map)['maps_to'], isNull, reason: '${e.key}.${p.key}');
        }
      }
    });

    test('общие блоки берутся у лаунчера через include, своих копий нет', () {
      // TLS приходит include'ом у тех, кто его вообще разбирает. wireguard —
      // endpoint, TLS у него нет вовсе; masque несёт QUIC со своим набором
      // (`sni`/`disable_sni` и больше ничего), и общий блок ссылочного TLS
      // принёс бы ему поля, которых его диалект не знает.
      for (final k in const ['hysteria2', 'tuic']) {
        final s = section(uriSections[k]!, 'uri');
        expect((s['include'] as List), contains('tls#uri'), reason: k);
      }

      // Записи общего блока в секции схемы дублироваться не должны — они
      // приходят include'ом.
      //
      // `fp` из этого набора ИСКЛЮЧЁН, и это не послабление. У части схем
      // (anytls, vless) пустое написание отпечатка означает `random`, а не
      // дефолт ядра, и записать это значение в тело обязан МАППЕР
      // (`materialize_default`). Выразить «у меня иначе» можно только
      // собственной записью, перекрывающей блочную: перечислять `fp` среди
      // запрещённых значило бы запретить сам примитив переопределения,
      // которым блок и задуман пользоваться.
      //
      // Единственное исключение — `security` у hysteria2: схема не подключает
      // `tls#uri_security` (его ветка `none` сняла бы обязательный TLS) и
      // объявляет свою запись — маркер 3x-ui без записи в тело (контракт
      // 1.1.54). Это не копия блока.
      const allowed = {'hysteria2.security'};
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        for (final dup in const ['security', 'alpn', 'pbk', 'sid']) {
          if (allowed.contains('${e.key}.$dup')) continue;
          expect(params.containsKey(dup), isFalse, reason: '${e.key}.$dup');
        }
      }
    });

    // §480 — ПОЛНАЯ КОПИЯ исполняемой секции реестра в черновике запрещена.
    //
    // Загрузчик при исполняемой секции реестра берёт РЕЕСТР и копию молча
    // игнорирует (`_rawSection`): черновик-не-оверлей секцию не заменяет.
    // Пока стража не было, копия выглядела рабочей и протухала незаметно —
    // так пропала sni-эвристика anytls (`sni_heuristic_falls_back_to_server`
    // была написана в копии и не исполнялась НИ РАЗУ), а вместе с ней
    // разъехались ещё четыре файла. Молчаливое игнорирование и есть источник
    // регрессии, поэтому здесь оно красное.
    test('черновик при исполняемой секции реестра — только _overlay', () {
      final registry = Directory('assets/contract/registry/protocols');
      final executable = <String, Set<String>>{};
      for (final f in registry.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        final name = f.uri.pathSegments.last.replaceAll('.json', '');
        final mappers = (load(f.path)['mappers'] as Map?)?.cast<String, dynamic>();
        if (mappers == null) continue;
        executable[name] = mappers.keys.toSet();
      }

      for (final sub in const ['uri', 'xray', 'singbox', 'conf']) {
        final dir = Directory('assets/contract_draft/$sub');
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.json')) continue;
          final name = f.uri.pathSegments.last.replaceAll('.json', '');
          final file = load(f.path);
          final kinds = (file['mappers'] as Map?)?.keys.cast<String>() ?? const [];
          for (final kind in kinds) {
            if (!(executable[name]?.contains(kind) ?? false)) continue;
            expect(file['_overlay'], isTrue,
                reason: 'assets/contract_draft/$sub/$name.json: секция '
                    'mappers.$kind есть в реестре и исполняема, значит '
                    'черновик обязан быть оверлеем (_overlay: true) и нести '
                    'только отличия. Полную копию загрузчик игнорирует.');
          }
        }
      }
    });

    test('masque материализует дефолты profile/vhttp/mtu: default реестра в '
        'тело не едет (PARSING_PRINCIPLES §2.4), а identity живых узлов на них стоит', () {
      final p = (section(uriSections['masque']!, 'uri')['params'] as Map)
          .cast<String, dynamic>();
      for (final f in const ['profile', 'vhttp', 'mtu']) {
        expect((p[f] as Map)['materialize_default'], isTrue, reason: f);
      }
      expect(((p['vhttp'] as Map)['default_when'] as Map)['value'], 'h3');
      expect(((p['mtu'] as Map)['default_when'] as Map)['value'], 1280);
      expect(((p['profile'] as Map)['default_when'] as Map)['value'], 'cloudflare');
    });
  });

  group('§480 W4 — форма секции conf (INI)', () {
    // Секция `mappers.conf` приехала РЕЕСТРОМ (контракт 1.1.23+), а диалект
    // INI — контрактом 1.1.30. Черновика `conf/` больше нет вовсе: последнее
    // отличие (дефолтный порт пира) сняла ветка `endpoint.on_no_match`.
    const path = 'assets/contract/registry/protocols/wireguard.json';

    test('все записи адресуют ini.<Section>.<Key> (одно пространство на '
        'awg://<base64 .conf> и на файл)', () {
      final params = (section(path, 'conf')['params'] as Map).cast<String, dynamic>();
      for (final p in params.entries) {
        final src = (p.value as Map)['source'];
        // Источников у записи бывает НЕСКОЛЬКО (`reserved` читается и из
        // `Peer.Reserved`, и из `Peer.ClientId`) — пространство у всех одно.
        final all = src is List ? src : [src];
        for (final s in all) {
          expect(s, isA<String>(), reason: p.key);
          // Контракт 1.1.63 — источник `context.<путь>` (значение от
          // распаковщика контейнера: `mtu_container`) текста .conf не
          // адресует и пространству INI не подчиняется.
          final str = s as String;
          expect(str.startsWith('ini.') || str.startsWith('context.'), isTrue,
              reason: p.key);
        }
      }
    });

    // §480 — потеря `Interface.DNS` осознанная (у endpoint'а sing-box поля
    // DNS нет вовсе). Контракт 1.1.23+ код ВКЛЮЧИЛ: корпус его теперь ждёт
    // (`wgconf/ini_basic.expected.json` несёт `wgconf_dns_ignored`
    // единственным warning), и `$code_pending` снят. Запись обязана остаться
    // в любом случае — без неё `DNS` уехал бы в `uri_param_unknown`.
    test('Interface.DNS — лоссы by design, потеря названа кодом', () {
      final dns = ((section(path, 'conf')['params'] as Map)['dns'] as Map);
      expect(dns['maps_to'], isNull);
      final onPresent = dns['on_present'] as Map;
      expect(onPresent['code'], 'wgconf_dns_ignored');
    });
  });
}
