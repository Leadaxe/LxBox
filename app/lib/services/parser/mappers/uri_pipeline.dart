/// §472 шаг 2 — конвейер разбора ссылки.
///
/// ```
/// ссылка ─маппер→ сырая карта ─санитайзер по реестру→ чистая карта
///                                      │                    │
///                                      │                    ▼
///                                      │            parseSingboxEntry → NodeSpec
///                                      └→ warnings (code, path, value) ─┘
/// ```
///
/// Три решения этого шага записаны здесь, потому что проверяются здесь же.
///
/// **1. `parseSingboxEntry` кормится ЧИСТОЙ картой.** Модель обязана быть
/// типизированным представлением того, что поедет в ядро; кормить её сырой
/// картой значило бы оставить в ней значения, которые санитайзер только что
/// объявил негодными (мусорный путь транспорта, `short_id` не в hex), и
/// рукописные guard'ы в `json_parsers.dart` пришлось бы держать вторым
/// эшелоном навсегда. Санитайзер здесь единственный судья — ровно как у
/// лаунчера.
///
/// **2. `rawSource` остаётся ССЫЛКОЙ (§454).** `parseSingboxEntry` по
/// умолчанию кладёт в него pretty-print карты; конвейер передаёт исходный
/// текст ссылки. Это не косметика: `rawSource` — то, что человек
/// импортировал, на нём стоит бэкап (§221) и повторный разбор.
///
/// **3. Второй проход по `emit()` (`annotateAllWithRegistry`) НЕ снимается.**
/// Обоснование — в [markPipelineParsed].
library;

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../contract/body_sanitizer.dart';
import '../../contract/registry.dart';
import '../json_parsers.dart';
import '../uri_utils.dart';
import 'anytls_mapper.dart';
import 'hysteria2_mapper.dart';
import 'http_mapper.dart';
import 'masque_mapper.dart';
import 'naive_mapper.dart';
import 'shadowsocks_mapper.dart';
import 'socks_mapper.dart';
import 'ssh_mapper.dart';
import 'trojan_mapper.dart';
import 'tuic_mapper.dart';
import 'uri_mapper.dart';
import 'vless_mapper.dart';
import 'vmess_mapper.dart';
import 'wireguard_mapper.dart';

/// Версия ядра, которую санитайзер видит при разборе: гейты, которым она
/// нужна (`min_core`), здесь выключены. То же значение, что в
/// `parse_warnings.dart`.
const _kParseTimeCore = '0.0.0';

/// Схемы, переехавшие на конвейер. Растёт по шагу за протокол; список
/// нормативен для стража покрытия mapper-правил
/// (`test/parser/mapper_rules_coverage_test.dart`).
///
/// §472 шаг 5 — `hy2` стоит в списке отдельной записью: это АЛИАС СХЕМЫ
/// (`hysteria2.json` → `aliases`), и `parseUri` маршрутизирует по тексту
/// схемы, а не по типу тела. Перевод алиаса в каноническое имя — работа
/// маппера, он же кладёт в тело `type: hysteria2`.
const kPipelineSchemes = <String>{
  'trojan',
  'vless',
  'vmess',
  'ss',
  'hysteria2',
  'hy2',
  'tuic',
  'anytls',
  // §472 шаг 6 — у naive схема НЕСЁТ ТРАНСПОРТ: `naive+quic` это не алиас
  // написания, а другое тело (`quic: true`). Обе записи ведут в свой маппер.
  'naive+https',
  'naive+quic',
  // §472 шаг 6 — http(s) CONNECT-прокси (§222) и его плюс-алиасы (§268).
  // Суффикс схемы это TLS-дискриминатор, поэтому каждая запись своя, как у
  // naive: тело у `-http` и `-https` разное.
  'proxy-http',
  'proxy-https',
  'proxy+http',
  'proxy+https',
  // §472 шаг 6 — socks; `socks5` алиас написания (`socks.json` → aliases).
  'socks',
  'socks5',
  // §472 шаг 6 — ssh.
  'ssh',
  // §472 шаг 7 — masque (§130). Алиасов схема не имеет.
  'masque',
  // §472 шаг 7 — wireguard и оба его алиаса (`wireguard.json` → `aliases`).
  // `awg://` это АЛИАС НАПИСАНИЯ, а не другое тело: AWG-поля промоутятся в
  // корень endpoint'а одинаково, откуда бы ссылка ни пришла.
  //
  // Маршрутизация сюда НЕ заводится: `parseUri` по-прежнему зовёт
  // `parseWireguardUri`, потому что у схемы есть ВТОРАЯ ФОРМА
  // (`awg://<base64 .conf>`, §450), которую надо распознать до конвейера —
  // её payload не URI. Список нужен стражу покрытия mapper-правил.
  'wireguard',
  'wg',
  'awg',
};

/// Мапперы переехавших схем, по схеме ссылки.
const Map<String, UriMapper> _kMappers = <String, UriMapper>{
  'trojan': mapTrojanUri,
  'vless': mapVlessUri,
  'vmess': mapVmessUri,
  'ss': mapShadowsocksUri,
  'hysteria2': mapHysteria2Uri,
  'hy2': mapHysteria2Uri,
  'tuic': mapTuicUri,
  'anytls': mapAnyTlsUri,
  'naive+https': mapNaiveHttpsUri,
  'naive+quic': mapNaiveQuicUri,
  'proxy-http': mapHttpProxyUri,
  'proxy-https': mapHttpProxyUri,
  'proxy+http': mapHttpProxyUri,
  'proxy+https': mapHttpProxyUri,
  'socks': mapSocksUri,
  'socks5': mapSocksUri,
  'ssh': mapSshUri,
  'masque': mapMasqueUri,
  'wireguard': mapWireguardUri,
  'wg': mapWireguardUri,
  'awg': mapWireguardUri,
};

/// Разобрать ссылку конвейером, если её схема переехала. `null` — схема ещё
/// идёт старым путём (вызывающий обязан обработать сам) ИЛИ ссылка не
/// разбирается вовсе.
///
/// Различать эти два «null» вызывающему не нужно: `parseUri` выбирает ветку
/// ДО вызова, по имени схемы ([kPipelineSchemes]).
NodeSpec? parseUriViaPipeline(String uri, String scheme) {
  final mapper = _kMappers[scheme];
  if (mapper == null) return null;
  // §472 шаг 4 — маппер получает ИСХОДНЫЙ ТЕКСТ. Общего `Uri.tryParse` здесь
  // больше нет: у vmess и shadowsocks ссылка не URI, и приведение authority к
  // нижнему регистру убивало бы base64 (см. [UriMapper]).
  return _runPipeline(uri, mapper);
}

/// §472 шаг 7 — тот же конвейер для входа, у которого СХЕМЫ НЕТ: текст INI
/// (`wg-quick`).
///
/// Отличие от [parseUriViaPipeline] ровно одно — маршрутизация. У ссылки
/// маппер выбирается по схеме, а INI-текст схемы не несёт вовсе, и выбирает
/// его вызывающий (`ini_parser.dart`): формат опознан раньше, ещё на входе
/// приложения (`parse_all.dart`, `body_decoder.dart`). Всё остальное —
/// санитайзер, тег, `rawSource`, отметка «разобран конвейером» — общее.
///
/// [source] уезжает в `rawSource` узла как есть: у INI это текст файла байт в
/// байт (§456).
NodeSpec? parseIniViaPipeline(String source, UriMapper mapper) =>
    _runPipeline(source, mapper);

/// Общее тело конвейера: маппер → санитайзер → `parseSingboxEntry`.
NodeSpec? _runPipeline(String source, UriMapper mapper) {
  final mapping = mapper(source);
  if (mapping == null) return null;

  final warnings = <NodeWarning>[...mapping.warnings];

  // §474 — dial-поля идут В САНИТАЙЗЕР, вместе со всем телом.
  //
  // До контракта 1.1.6 они дописывались ПОСЛЕ него и мимо него: реестр
  // числил их строками `skipped`, и санитайзер снял бы их как `unknown_key`
  // — то есть повесил бы код о «неизвестном ключе» на поле, которое ядро
  // принимает, а человек написал сам. Теперь `dialer.json` описывает их
  // полями (`tcp_keep_alive`, `tcp_keep_alive_interval` — `duration`,
  // `disable_tcp_keep_alive` — `bool`), и обходить судью больше незачем:
  // значения судятся наравне с прочими.
  var body = mapping.body;
  if (mapping.extensionFields.isNotEmpty) {
    body = {...body, ...mapping.extensionFields};
  }

  // Санитайзер по реестру — единственный судья значений. Гейты `min_core`/
  // `platform` выключены: они зависят от ЗАПУЩЕННОГО ядра, а узел от него не
  // зависит (24.1.6, та же граница, что у W2a и шага 1).
  if (ContractRegistry.I.isLoaded) {
    final res = RegistrySanitizer.sanitize(
      body,
      scheme: body['type'] as String,
      coreVersion: _kParseTimeCore,
      applyCoreGates: false,
    );
    // `drop_node` — запись снята целиком: ядро её не принимает, и узла нет.
    if (res.body == null) return null;
    body = res.body!;
    warnings.addAll(res.warnings);
  }

  // §463/§473 — ПОТОЛОК `mtu` там, где санитайзер до значения не дотянулся.
  //
  // Правило реестра (`wireguard.body.fields.mtu`: `default_when`/`max_when`)
  // исполняет САНИТАЙЗЕР, по телу, на всех входах — это и есть закрытый долг
  // §473. Остаются ровно два случая, до которых он не достаёт, и оба
  // опасны молчанием: AWG-узел без потолка поднимает туннель, по которому не
  // идут данные.
  //
  // 1. **Узел ПРОСИЛ AmneziaWG, но не донёс ни одного годного AWG-поля** —
  //    `jc=abc` вместе с одиноким `jmin` (корпус: `awg_bad_numeric_skipped`,
  //    `awg_jc_invalid_dropped`). Условие `when.any_set` судит наличие ключа
  //    в ТЕЛЕ, а там не осталось ничего; род узла знает только маппер
  //    ([UriMapping.kindIsAwg], §463).
  // 2. **Реестр не загружен** — санитайзер не работал вовсе. Здесь
  //    [awgMtuCeilingByRegistry] отвечает запасным числом, и это намеренно:
  //    молчание тут не безопасно.
  //
  // Число в Dart не вписывается: и потолок, и его код называет реестр.
  if (mapping.kindIsAwg) {
    final ceiling = awgMtuCeilingByRegistry();
    if (ceiling != null) {
      final written = body['mtu'];
      if (written == null) {
        // Дефолт: подстановка недостающего — не замена, кода за неё нет
        // (`default_when` реестра его и не объявляет).
        body['mtu'] = ceiling;
      } else if (written is num && written > ceiling) {
        // Замена написанного — с кодом и ИСХОДНЫМ значением: человеку нужно
        // видеть, что он написал. Дубля с санитайзером тут быть не может: он
        // этот узел AmneziaWG-узлом не считал и молчал.
        warnings.add(RegistryWarning(
          code: awgMtuClampCodeByRegistry() ?? 'awg_mtu_clamped',
          path: 'mtu',
          value: RegistrySanitizer.renderWarningValue(written),
        ));
        body['mtu'] = ceiling;
      }
    }
  }

  // Имя узла: `tag` вычисляется из фрагмента общим правилом, как раньше.
  // `parseSingboxEntry` читает `label` из `tag`, поэтому тег кладётся в карту
  // перед вызовом — и снимается санитайзером он не может (ключ сборки).
  //
  // §472 шаг 4 — тег-фолбэк строится по ИМЕНИ ТИПА ТЕЛА, а не по схеме
  // ссылки. У первых трёх схем они совпадали, у shadowsocks нет: ссылка
  // зовётся `ss://`, тело — `shadowsocks`, и старый парсер подставлял в
  // фолбэк второе. Возьми конвейер имя схемы — безымянный узел получил бы
  // тег `ss-host-8388` вместо `shadowsocks-host-8388`, то есть у живых узлов
  // сменилась бы identity (она и есть сырой тег, `node_hash.dart`).
  //
  // §472 шаг 7 — у ENDPOINT-схем (wireguard/AWG) корневых `server`/
  // `server_port` не бывает: адрес пира лежит в `peers[]`, и `emitWireguard`
  // в корень его не пишет. Маппер такой схемы называет адрес сам
  // ([UriMapping.tagAddress]); прочие схемы поля не ставят, и адрес берётся
  // из корня тела, как прежде.
  final (server, port) = mapping.tagAddress ??
      (
        body['server']?.toString() ?? '',
        (body['server_port'] as num?)?.toInt() ?? 0,
      );
  body['tag'] =
      tagFromLabel(mapping.label, body['type'] as String, server, port);

  // §454 — `rawSource` узла из ссылки это САМА ССЫЛКА, а не карта.
  // `label` — текст фрагмента, а не тег: ссылка без `#` даёт тег-фолбэк, и
  // подставить его в имя значило бы вернуть выдуманное `#trojan-host-443`
  // из `toUri()`.
  // §103 D-008 — заголовок early data подставлен САМОЙ формой `?ed=N`
  // хвостом пути. В теле этой разницы нет, и знает о ней только маппер:
  // он один видел исходную форму. Знание доносится ДО постройки модели —
  // шаг 2 пересобирал узел после (`_withImplicitEdHeader` ветвился по
  // `TrojanSpec`), и каждая новая схема требовала бы там своей ветки.
  final node = parseSingboxEntry(
    body,
    rawSource: source,
    label: mapping.label,
    wsEarlyDataHeaderImplicit: mapping.wsEarlyDataHeaderImplicit,
  );
  if (node == null) return null;

  node.warnings.addAll(warnings);
  markPipelineParsed(node);
  return node;
}

/// Узел, разобранный конвейером: его коды реестра уже стоят, по `emit()`
/// второй раз идти незачем.
///
/// **Решение по второму проходу (п. 2 задания шага 2).** Проход по `emit()`
/// (`annotateAllWithRegistry`) НЕ снимается совсем, а ПРОПУСКАЕТСЯ адресно —
/// по этой отметке. Разница существенная:
///
/// - снять проход целиком нельзя: им судятся URI/INI-узлы схем, которые ещё
///   не переехали (двенадцать из тринадцати на шаге 2), и JSON-узлы, где есть
///   значения, поставленные САМИМ разбором;
/// - оставить его на переехавших узлах тоже нельзя, хотя дедуп по
///   `(code, path)` дубли и снял бы. Причина не в дублях, а в `value`:
///   санитайзер конвейера видит СЫРОЕ значение ссылки
///   (`fp=HelloChrome_120`), а проход по `emit()` — уже канонизированное
///   (`chrome`). Первый пришедший выигрывает, то есть дедуп дал бы верный
///   ответ случайно, порядком вызовов. Отметка делает это правилом: у узла
///   конвейера источник кодов ровно один, и `value` называет то, что написал
///   автор ссылки.
///
/// Отметка — [Expando], а не поле модели и не запись в `warnings`.
/// `NodeSpec` это ХРАНИМАЯ форма узла: служебный флаг в ней уехал бы в бэкап
/// (§221) и в `emit()`, то есть в identity-хеш. Expando живёт ровно столько,
/// сколько объект узла в памяти, ничего не сериализует и не мешает GC.
final _pipelineParsed = Expando<bool>('§472 разобран конвейером');

void markPipelineParsed(NodeSpec node) => _pipelineParsed[node] = true;

/// Разобран ли узел конвейером (коды реестра на нём уже стоят).
bool isPipelineParsed(NodeSpec node) => _pipelineParsed[node] == true;
