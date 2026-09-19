/// §472 шаг 7 — маппер wireguard / AmneziaWG.
///
/// Словарь ссылки — `registry/protocols/wireguard.json` → `uri`. Схема
/// единственная среди переехавших, у которой запись это **endpoint**, а не
/// outbound: адреса сервера в корне тела нет вовсе, он лежит в `peers[]`
/// (`kind: endpoint` реестра, sing-box >= 1.11).
///
/// Что маппер переводит (и не судит):
///
/// - **приватный ключ в userinfo**, фолбэк `?privatekey=` / `?private_key=`.
///   Сырой `/` внутри base64 percent-энкодится ДО `Uri.tryParse` (§106);
/// - **`address=` и `allowedips=` списками через запятую**, bare IP получает
///   префикс `/32`/`/128` — правило реестра `bare_ip_gets_prefix`. Дефолт
///   `allowed_ips` при отсутствии параметра — `0.0.0.0/0, ::/0` (D-022,
///   обе стороны);
/// - **один peer.** Share-URI несёт строго одного пира (реестр: «URI/share-URI
///   — строго один peer»), поэтому вся peer-часть — это `peers[0]`;
/// - **`reserved` / `client_id` → тройка байт.** Ссылка пишет их либо
///   десятичной тройкой `b0,b1,b2` (WARP), либо base64 трёх байт
///   (`client_id`); тело ядра хочет массив ЧИСЕЛ (`int_array`, `len: 3`).
///   Обе формы разбирает общий [parseReserved];
/// - **`keepalive` числом или AWG3-диапазоном `N-M`** ([parseWgKeepalive]);
/// - **AWG-параметры**, включая AWG 3.x, — [Awg.fromQuery]. Имена ключей у
///   ссылки без подчёркиваний (`headerprotectionkey` ↔
///   `header_protection_key`), значения `i1`–`i5` уезжают дословно;
/// - **`headerprotectionkey` читается с сохранением сырого `+`**
///   ([queryParamPreservePlus], §421): `Uri.queryParameters` декодирует по
///   правилам формы и превратил бы `+` base64 в пробел — «not base64» и
///   потерянный узел.
///
/// **Правила ЗНАЧЕНИЯ, которые судит реестр** (§473, контракт 1.1.5):
///
/// - потолок `mtu` у AmneziaWG — `max_when` (1280, код `awg_mtu_clamped`);
/// - дефолт `mtu` 1280 у AmneziaWG без параметра — `default_when`;
/// - ключи WireGuard 32 байта — `format: base64_32` у `private_key` и
///   `peers[].public_key` (`drop_node`), у `pre_shared_key` — `drop`;
/// - `address` / `allowed_ips` — `format: cidr`.
///
/// Обе MTU-ветки исполняет САНИТАЙЗЕР, по телу. Рукописные `awgClampMtu`,
/// `awgMtuByRegistry` и `awgMtuWarnings` сняты разом — долг §473 закрыт.
/// Условие рода узла у обоих правил одно и то же (`when.any_set` по списку
/// AWG-ключей), и читается оно по ИСХОДНОМУ телу: узел, у которого санитайзер
/// снял последнее AWG-поле, AmneziaWG-узлом быть не перестаёт (§463).
///
/// **Что осталось рукописным СУЖДЕНИЕМ — и почему.** Три группы, все про
/// AmneziaWG, и ни одной из них реестр сегодня не описывает:
///
/// 1. **`h1`–`h4`.** Реестр числит их типом `awg_range` без ограничений:
///    «ЧИСЛО либо строка min-max». Отбраковку мусора (`h2=a-b`, `h3=-5`,
///    `h4=1-2-3`) и нормализацию перевёрнутой пары (`300-200` → `200-300`,
///    D-031 — без неё одна нода даёт два хеша) делает [Awg.fromQuery], и код
///    `awg_header_invalid` ставится ПОФАКТОРНО, по одному на битый заголовок
///    (§463): человек читает четыре сообщения, а конверт корпуса несёт одну
///    запись без пути (кейс `awg_ranged_h_broken_dropped`).
/// 2. **`jc`/`jmin`/`jmax`/`s1`–`s4` с мусором снимаются МОЛЧА** — эталон Go
///    `applyAWGFields`. Реестр объявляет у них `on_invalid.code`
///    (`awg_header_invalid` / `awg3_field_invalid`), и отдай маппер сырую
///    строку санитайзеру, узел получил бы код там, где вторая сторона молчит,
///    а корпус ждёт тишины (`awg_jc_invalid_dropped` — там ОДИН код, и он про
///    `jmin`, снятый правилом `requires`).
/// 3. **Узел выбрасывается целиком** при битом ключе защиты заголовка или
///    паддинге короче 12 байт ([awg3NodeError], §421): ядро отвергло бы
///    конфиг ЦЕЛИКОМ. Реестр описывает `header_protection_key` форматом
///    `base64_32` с `action: drop` — то есть снял бы поле и оставил узел жить
///    без защиты заголовка, а это тихо сломанный туннель.
///
/// Все три — запрос к лаунчеру (спека 472, «Что вышло: шаг 7»).
library;

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию — канонический WireGuard.
const _kDefaultPort = 51820;

/// §456 — имя узла из INI, когда ни комментария под `[Peer]`, ни `nameHint`
/// нет. Оно же попадает в тег: INI тега не несёт.
const _kIniFallbackName = 'WireGuard';

// §480 W4 — РУКОПИСНОГО МАППЕРА ССЫЛКИ здесь больше нет: `wireguard://`,
// `wg://` и `awg://` разбирает движок по секции `contract_draft/uri/
// wireguard.json`. Вместе с ним ушли заплаты, которые секция выражает
// данными: percent-энком `/` в userinfo (лексер режет authority сам),
// `queryParamPreservePlus` у ключа защиты заголовка (`decode_extra
// .plus_literal` у поля base64-формата) и ручной фолбэк приватника
// userinfo → query (цепочка `source`).
//
// INI остался рукописным ОСОЗНАННО: движок сегодня исполняет пространства
// `url` и `json`, а `ini` придёт своей волной вместе с видом источника
// `conf`. Секция для него уже написана (`contract_draft/conf/wireguard.json`)
// и ждёт движка — не наоборот.

/// §472 шаг 7 / §456 — маппер ТЕКСТА INI (`wg-quick`).
///
/// Второй вход той же схемы, и отличается он от ссылки ровно разбором входа:
/// выход у обоих один — сырая карта sing-box. Форма интерфейса это позволяет
/// с шага 4, где [UriMapper] стал принимать исходный ТЕКСТ, а не `Uri`.
///
/// **`rawSource` остаётся текстом INI, байт в байт** (§456): узел пришёл
/// файлом, и подставлять в источник пересобранную ссылку нельзя — на
/// `rawSource` стоят бэкап (§221), вкладка Source и повторный разбор.
/// Подставляет его вызывающий ([parseWireguardIni]), потому что конвейер
/// кладёт туда свой аргумент.
///
/// **Имя узла** (INI тега не несёт), по убыванию силы: первый комментарий под
/// `[Peer]` без `=` → [nameHint] → `WireGuard`. Порядок задаёт вызывающий:
/// сюда приходит уже выбранное имя.
///
/// Что переводит диалект INI поверх общего перевода схемы:
///
/// - **секции.** `[Interface]` несёт ключи узла, `[Peer]` — ключи пира;
///   имена ключей регистронезависимы (`PrivateKey` = `privatekey`);
/// - **`Endpoint = host:port`** разбирается в адрес и порт пира, с учётом
///   `[IPv6]:port` и голого IPv6 (§219: несколько `:` без скобок — адрес
///   целиком, порт по умолчанию, потому что отличить его нечем);
/// - **`Reserved` / `ClientId` в `[Peer]`** — WARP client_id (§126);
/// - **AWG-ключи из `[Interface]`** приходят под теми же именами, что в
///   query ссылки (`HeaderProtectionKey` → `headerprotectionkey`), поэтому
///   дальше их читает тот же [Awg.fromQuery];
/// - **`DNS` игнорируется** — у sing-box endpoint такого поля нет
///   (`uri.query.dns.impl`: «параметр лоссы by design»).
UriMapping? mapWireguardIni(String config, {String? nameHint}) {
  final params = <String, String>{};
  var host = '';
  var port = _kDefaultPort;
  var section = '';
  var endpoint = '';

  for (final line in config.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      continue;
    }
    final idx = t.indexOf('=');
    if (idx < 0) continue;
    final k = t.substring(0, idx).trim().toLowerCase();
    final v = t.substring(idx + 1).trim();
    if (v.isEmpty) continue;
    if (section == '[interface]') {
      switch (k) {
        case 'privatekey':
          params['privatekey'] = v;
        case 'address':
          params['address'] = v;
        case 'mtu':
          params['mtu'] = v;
        default:
          // AWG2 (`Jc`/`H1`/`I1`…) и AWG3 (`HeaderProtectionKey`…) — под теми
          // же именами, что в query ссылки.
          if (Awg.numKeys.contains(k) ||
              Awg.strKeys.contains(k) ||
              Awg.awg3ParamToJson.containsKey(k)) {
            params[k] = v;
          }
      }
    } else if (section == '[peer]') {
      switch (k) {
        case 'publickey':
          params['publickey'] = v;
        case 'endpoint':
          endpoint = v;
        case 'allowedips':
          // §103 amnezia_vpn_plain_wg — читать обязательно: без этого
          // IPv4-only INI получал дефолтный `::/0` в придачу.
          params['allowedips'] = v;
        case 'presharedkey':
          params['presharedkey'] = v;
        case 'persistentkeepalive':
          params['keepalive'] = v;
        case 'reserved':
        case 'client_id':
        case 'clientid':
          params['reserved'] = v; // §126 — WARP client_id
      }
    }
  }

  if (endpoint.isEmpty) return null;
  (host, port) = _splitEndpoint(endpoint);
  if (host.isEmpty) return null;

  final hint = (nameHint ?? '').trim();
  return _mapWireguardParams(
    params,
    host: host,
    port: port,
    label: hint.isEmpty ? _kIniFallbackName : hint,
  );
}

/// `Endpoint = …` → (хост, порт). Поддержаны `[IPv6]:port`, `host:port` и
/// голый IPv6 (§219 — порт от адреса неотличим, берётся дефолтный).
(String, int) _splitEndpoint(String endpoint) {
  if (endpoint.startsWith('[')) {
    final close = endpoint.indexOf(']');
    final host =
        endpoint.substring(1, close > 0 ? close : endpoint.length);
    final after = close > 0 ? endpoint.substring(close + 1) : '';
    final port = after.startsWith(':')
        ? (int.tryParse(after.substring(1)) ?? _kDefaultPort)
        : _kDefaultPort;
    return (host, port);
  }
  final lastColon = endpoint.lastIndexOf(':');
  if (lastColon > 0 && endpoint.indexOf(':') == lastColon) {
    return (
      endpoint.substring(0, lastColon),
      int.tryParse(endpoint.substring(lastColon + 1)) ?? _kDefaultPort,
    );
  }
  // §219 — несколько `:` без скобок это голый IPv6: порт ПРИНЦИПИАЛЬНО
  // неотличим от адреса (`2001:db8::1:51820`), берём весь endpoint хостом.
  return (endpoint, _kDefaultPort);
}

/// Общее ядро обоих входов: плоская карта «имя параметра → значение» плюс
/// адрес пира → сырая карта sing-box.
///
/// Имена параметров — те же, что в query ссылки: диалект INI приводится к ним
/// вызывающим. Всё, что ниже, — перевод схемы, одинаковый для обоих входов;
/// суждения о значениях делает санитайзер (см. док библиотеки).
UriMapping? _mapWireguardParams(
  Map<String, String> q, {
  required String host,
  required int port,
  required String label,
}) {
  // SPEC 103 D-023/D-030 — ключи WireGuard приводятся к КАНОНУ: ровно 32
  // байта, любая из четырёх форм base64 → std-base64 с padding.
  // [normalizeWGKey] это НОРМАЛИЗАЦИЯ, а не суждение, и снять её нельзя:
  // корпус нормирует именно её результат (`uri_psk_keepalive` — ключ
  // `…ccC=` в теле становится `…ccA=`, те же 32 байта в канонической записи).
  // Реестр про написание молчит: `format: base64_32` только ПРОВЕРЯЕТ, а
  // проверяет он строгим декодером, для которого `…ccC=` вообще не base64.
  // Без нормализации одна нода давала бы два identity-хеша (D-030).
  //
  // §481 (контракт 1.1.11) — ГОДНОСТЬ ключа маппер больше НЕ судит. Раньше
  // `normalizeWGKey == null` роняла узел МОЛЧА и только на входе «ссылка»: то
  // же значение телом sing-box проверок не проходило вовсе и уносило мусор в
  // ядро. Теперь негодный ключ уезжает в тело КАК ЕСТЬ, и его судит реестр
  // (`format: base64_32`, `on_invalid: drop_node`, код `wg_key_invalid`) —
  // одинаково на всех входах и С КОДОМ. Перевод написания остаётся здесь: о
  // нём реестр молчит, а `format` проверяет строгим декодером, для которого
  // `…ccC=` вообще не base64.
  final privateKeyRaw = (q['privatekey'] ?? q['private_key'] ?? '').trim();
  if (privateKeyRaw.isEmpty) return null;
  final privateKey = normalizeWGKey(privateKeyRaw) ?? privateKeyRaw;

  final publicKeyRaw = (q['publickey'] ?? q['public_key'] ?? '').trim();
  if (publicKeyRaw.isEmpty) return null;
  final publicKey = normalizeWGKey(publicKeyRaw) ?? publicKeyRaw;

  final address = q['address'] ?? '';
  if (address.isEmpty) return null;
  final localAddresses = _cidrList(address);

  // Канон — только `presharedkey` без подчёркивания: единственный ключ,
  // который читает Go (`node_parser_wireguard.go`, без `preshared_key`-алиаса
  // — в отличие от `privatekey`/`private_key`, где алиас добавлен намеренно,
  // D-021).
  //
  // §481 (контракт 1.1.11) — ЗАПРОС ЗАКРЫТ В НАШУ СТОРОНУ: реестр объявил у
  // `peers[].pre_shared_key` `on_invalid: {action: drop_node}` с кодом
  // `wg_key_invalid`. Прежде реестр снимал здесь ПОЛЕ, а маппер ронял узел
  // молча, и две записи расходились. Теперь узел роняет реестр, и мусорный psk
  // уезжает ему как есть.
  final pskRaw = (q['presharedkey'] ?? '').trim();
  final psk = pskRaw.isEmpty ? '' : (normalizeWGKey(pskRaw) ?? pskRaw);

  final badAwg3 = <(String, String)>[];
  // §463 — пути полей, снятых правилом `requires` реестра (одинокий `jmin`).
  final droppedRequires = <String>[];
  final awg =
      Awg.fromQuery(q, badAwg3: badAwg3, droppedRequires: droppedRequires);

  // §481 (контракт 1.1.11) — рукописная проверка AWG 3.x (`awg3NodeError`)
  // СНЯТА: её исполняет реестр. Битый ключ защиты заголовков — `pattern` плюс
  // `format: base64_32` с `on_invalid: drop_node` (`awg3_header_key_invalid`),
  // короткий паддинг — `min_when` у `s1`–`s4` (`awg3_padding_too_short`,
  // `absent_is_zero`). Оба кода были объявлены в `warnings.json` и НЕ
  // СТАВИЛИСЬ никогда: рукописная проверка роняла узел молча и только на
  // входе «ссылка». Нормализация написания ключа к std-base64 переехала в
  // [normalizeAwgHeaderKey] — её реестр не делает.
  if (awg != null) normalizeAwgHeaderKey(awg);

  final peer = <String, dynamic>{
    'address': host,
    'port': port,
    'public_key': publicKey,
    // §025 — WARP client_id: `reserved=b0,b1,b2` или base64 `client_id`.
    // Битое значение параметр опускает, узел живёт (`uri.query.reserved`).
    'reserved': ?_reserved(q['reserved'] ?? q['client_id'] ?? ''),
    // §481 (контракт 1.1.11) — дефолт `0.0.0.0/0,::/0` СНЯТ отсюда: он стал
    // `default_when` у `peers[].allowed_ips`. Раньше он стоял двумя копиями
    // (здесь и в конвертере профиля Amnezia) и на входе sing-box не работал
    // вовсе — тело без `allowed_ips` узел ТЕРЯЛ, хотя ядро отвергает такого
    // пира фаталом на весь конфиг. Тела узлов от переезда не сдвинулись:
    // дефолт материализуется, как и прежде, только теперь одним местом.
    'allowed_ips': ?_cidrListOrNull(q['allowedips'] ?? q['allowed_ips']),
    if (psk.isNotEmpty) 'pre_shared_key': psk,
    // §421 — число как раньше; AWG3-диапазон `25-35` — строкой.
    'persistent_keepalive_interval': ?parseWgKeepalive(q['keepalive']),
  };

  final body = <String, dynamic>{
    'type': 'wireguard',
    // §473 — `mtu` кладётся В ТОЙ ФОРМЕ, В КАКОЙ ЕГО НАПИСАЛ АВТОР, и только
    // если он его написал. Потолок и дефолт — дело санитайзера:
    // `default_when` срабатывает ровно на ОТСУТСТВИИ ключа, и напиши маппер
    // сюда своё число, правило реестра не сработало бы вовсе. Обычный
    // WireGuard поля не получает и после санитайзера (условие `any_set` не
    // выполнено) — ядро берёт свой 1408, и наш дефолт спорил бы с ним и ломал
    // identity-хеш (CANON §2.4).
    'mtu': ?int.tryParse(q['mtu'] ?? ''),
    'address': localAddresses,
    'private_key': privateKey,
    'peers': [peer],
  };
  // §097 — AmneziaWG-поля в корень endpoint (числа → JSON number).
  awg?.writeInto(body);

  // §463/§473 — РОД УЗЛА ПО ЗАПРОСУ ВХОДА, а не по уцелевшим полям.
  //
  // Условие `when.any_set` реестра судит НАЛИЧИЕ КЛЮЧА в теле, и для почти
  // всех AWG-узлов этого довольно: хоть одно поле да уцелело. Но вход может
  // попросить AmneziaWG и не донести НИ ОДНОГО годного поля — `jc=abc` вместе
  // с одиноким `jmin` (кейсы корпуса `awg_bad_numeric_skipped`,
  // `awg_jc_invalid_dropped`). Тело у такого узла от обычного WireGuard
  // неотличимо, а корпус ждёт `mtu: 1280`: вход просил AWG, и потолок —
  // свойство ЗАПРОШЕННОГО протокола. Иначе снятие последнего поля молча
  // возвращало бы узлу MTU обычного WireGuard, и туннель не понёс бы данные.
  //
  // Отдать санитайзеру сырые значения вместо разобранных нельзя: реестр
  // объявляет у `jc` свой `on_invalid.code`, и узел получил бы код там, где
  // Go молчит (`applyAWGFields` роняет битые числа молча), а `h1`–`h4` дали бы
  // `type_invalid` вместо `awg_header_invalid`. Корпус нормирует тишину.
  //
  // Поэтому маппер сообщает род узла ОТДЕЛЬНО от тела
  // ([UriMapping.kindIsAwg]), а подставляет `mtu` конвейер — и подставляет
  // ровно то, что назвал реестр (`default_when.value`). Число 1280 в Dart не
  // появляется ни здесь, ни там.
  final askedAwg = awg != null ||
      Awg.hasAwg3Params(q) ||
      badAwg3.isNotEmpty ||
      droppedRequires.isNotEmpty;

  return UriMapping(
    body: body,
    label: label,
    // Адрес для тег-фолбэка: в корне тела его нет, запись — endpoint.
    tagAddress: (host, port),
    kindIsAwg: askedAwg,
    warnings: [
      // §463 — код с путём: снятие по `requires` реестра, а не битое
      // значение (у `jmin` оно как раз корректное — не хватает пары).
      for (final field in droppedRequires)
        RegistryWarning(code: 'awg_header_invalid', path: field),
      for (final (field, value) in badAwg3)
        Awg3FieldInvalidWarning(field, value),
      if (awg != null && awg.randomTrailersWithWideHeaders)
        const Awg3RandomTrailersWideHeadersWarning(),
    ],
  );
}

/// Список CIDR через запятую; bare IP получает префикс
/// (`bare_ip_gets_prefix`). Пустые элементы отбрасываются.
List<String> _cidrList(String raw) => [
      for (final e in raw.split(','))
        if (e.trim().isNotEmpty) ensureCidr(e.trim()),
    ];

/// §481 — то же, но `null` на ОТСУТСТВУЮЩЕМ параметре: ключа в теле не
/// появляется вовсе, и дефолт материализует реестр (`default_when`). Пустая
/// строка — тоже «параметра нет»: писать пустой список значило бы дать ядру
/// «missing allowed ips for peer» фаталом на весь конфиг вместо дефолта.
List<String>? _cidrListOrNull(String? raw) {
  if (raw == null) return null;
  final list = _cidrList(raw);
  return list.isEmpty ? null : list;
}

/// Три байта `reserved` из десятичной тройки или base64; `null` — параметра
/// нет или он битый (поле опускается, узел живёт).
List<int>? _reserved(String raw) =>
    raw.isEmpty ? null : parseReserved(raw);
