/// §472 шаг 7 — маппер masque.
///
/// Словарь ссылки — `registry/protocols/masque.json` → `uri`. Схема
/// QUIC-овая, но TLS-параметров её диалект почти не знает: у masque в query
/// всего `sni` и `disable_sni`, и оба уезжают во вложенный блок `tls{}`
/// (SPEC 062). Отпечатка uTLS и REALITY в диалекте нет вовсе — а вот в ТЕЛЕ,
/// написанном человеком, они вполне бывают, и там их снимает санитайзер
/// правилом `forbidden_for` (это работает с шага 1).
///
/// Что маппер переводит (и не судит):
///
/// - **приватный ключ в userinfo**, с фолбэком на `?private_key=` /
///   `?privatekey=` (обе стороны принимают оба написания). Сырой `/` внутри
///   base64(DER) percent-энкодится ДО `Uri.tryParse` общим помощником
///   [encodeUserInfoSlashes] — иначе платформа примет его за начало пути и
///   ключ пропадёт (§106);
/// - **`address=` списком через запятую → `ip` / `ipv6`.** Раскладка по
///   признаку `:`: первый v4 в `ip`, первый v6 в `ipv6`. Bare IP получает
///   префикс (`bare_ip_gets_prefix` по духу — у masque реестр пишет это в
///   `uri.query.address.impl`);
/// - **`vhttp` по умолчанию `h3`** — правило реестра
///   `vhttp_empty_defaults_to_h3`. Это КОНВЕНЦИЯ обеих сторон, а не дефолт
///   ядра (у ядра `auto`), и значение входит в identity-хеш живых
///   MASQUE-узлов. Поэтому маппер пишет `h3` ЯВНО: положись он на `default`
///   реестра, ключ не появился бы в теле вовсе (CANON §2.4) и identity всех
///   MASQUE-узлов сдвинулась бы;
/// - **`mtu` по умолчанию 1280 и `profile` по умолчанию `cloudflare`** — по
///   той же причине пишутся явно: корпус нормирует их присутствие в теле
///   (`uri/masque/default_vhttp_h3` несёт и `mtu: 1280`, и
///   `profile: cloudflare`);
/// - **`keep_alive` → `keep_alive_period`**: имя ссылки короче имени ядра;
/// - **legacy `network=` / `server_name=` не читаются** (контракт 0.8.0,
///   D-078). Они не переносятся и кода не дают — это не потеря значения, а
///   снятое написание: `?network=h2` рядом с `vhttp` роняло бы ядро
///   fail-fast'ом. Реестр числит их обычными неизвестными параметрами query.
///
/// **Судить в схеме осталось одно, и судит его реестр:** `vhttp` вне тройки
/// `h3|h2|auto` подменяется на `h3` с кодом `masque_vhttp_invalid`
/// (`body.fields.vhttp` → enum + `on_invalid: coerce h3`). Рукописный
/// `MasqueVhttpInvalidWarning` на пути ссылки снят.
library;

import '../uri_utils.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию — канонический masque (`443`).
const _kDefaultPort = 443;

/// §472 шаг 7 — дефолты ССЫЛКИ, а не ядра.
///
/// Все три пишутся в тело ЯВНО. Реестр объявляет их `default`, но `default`
/// по CANON §2.4 в тело не материализуется, а корпус их присутствия ждёт —
/// и на них стоит identity живых узлов.
const _kDefaultVhttp = 'h3';
const _kDefaultProfile = 'cloudflare';
const _kDefaultMtu = 1280;

/// `masque://<privKeyDer>@<server>:<port>?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста, приватного ключа, публичного ключа или
/// адреса туннеля записи не построить (те же четыре условия, что у прежнего
/// парсера; корпус нормирует два последних кейсами `missing_*_rejected`).
UriMapping? mapMasqueUri(String uri) {
  // §106 — сырой `/` в base64(DER) userinfo ломает `Uri.tryParse`.
  final p = Uri.tryParse(encodeUserInfoSlashes(uri));
  if (p == null || p.host.isEmpty) return null;

  final q = p.queryParameters;

  final privateKey = (p.userInfo.isEmpty
          ? (q['privatekey'] ?? q['private_key'] ?? '')
          : Uri.decodeComponent(p.userInfo))
      .trim();
  if (privateKey.isEmpty) return null;

  final publicKey = (q['publickey'] ?? q['public_key'] ?? '').trim();
  if (publicKey.isEmpty) return null;

  // `address=` — список локальных адресов туннеля; ядро держит их двумя
  // ОТДЕЛЬНЫМИ полями, по одному на семейство.
  String? ip, ipv6;
  for (final raw in (q['address'] ?? '').split(',')) {
    final a = ensureCidr(raw.trim());
    if (a.isEmpty) continue;
    if (a.contains(':')) {
      ipv6 ??= a;
    } else {
      ip ??= a;
    }
  }
  if (ip == null && ipv6 == null) return null;

  final vhttp = (q['vhttp'] ?? '').trim();
  final sni = (q['sni'] ?? '').trim();
  // §472 шаг 5 (tuic, 11.10) — `disable_sni` объявляет себя в теле ключом,
  // который знает и ядро, и sing-box-вход. Здесь так было всегда.
  final disableSni = q['disable_sni'] == '1' || q['disable_sni'] == 'true';
  final tls = <String, dynamic>{
    if (sni.isNotEmpty) 'server_name': sni,
    if (disableSni) 'disable_sni': true,
  };

  final idleTimeout = (q['idle_timeout'] ?? '').trim();
  final keepAlive = (q['keep_alive'] ?? '').trim();

  final body = <String, dynamic>{
    'type': 'masque',
    'server': p.host,
    'server_port': p.hasPort ? p.port : _kDefaultPort,
    'profile': (q['profile'] ?? '').trim().isEmpty
        ? _kDefaultProfile
        : q['profile']!.trim(),
    // Пустой `vhttp` в enum реестра ЕСТЬ (`""`), и отдай маппер пустую
    // строку — санитайзер пропустил бы её молча, а узел уехал бы без версии
    // HTTP. Дефолт подставляется здесь, кода за него нет: «нет параметра» —
    // не мусор, это конвенция (`vhttp_empty_defaults_to_h3`).
    'vhttp': vhttp.isEmpty ? _kDefaultVhttp : vhttp,
    'private_key': privateKey,
    'public_key': publicKey,
    'ip': ?ip,
    'ipv6': ?ipv6,
    'mtu': int.tryParse(q['mtu'] ?? '') ?? _kDefaultMtu,
    if (idleTimeout.isNotEmpty) 'idle_timeout': idleTimeout,
    if (keepAlive.isNotEmpty) 'keep_alive_period': keepAlive,
    if (tls.isNotEmpty) 'tls': tls,
  };

  return UriMapping(body: body, label: decodeFragment(p.fragment));
}
