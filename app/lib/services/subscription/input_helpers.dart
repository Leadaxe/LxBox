// Вспомогательные функции для UI-классификации пользовательского ввода
// (SubscriptionsScreen paste / "Add servers" поток). Чистые функции без
// зависимостей на контроллеры/стораджи.

import 'dart:convert';

import '../parser/engine/section_loader.dart' show MapperSections;
import '../parser/mappers/uri_pipeline.dart' show pipelineSchemes;

bool isSubscriptionUrl(String input) {
  final t = input.trim();
  return t.startsWith('http://') || t.startsWith('https://');
}

/// §129 — файловая подписка. `url` = `file:<uuid>` (синтетический ключ, а не
/// путь): дискриминатор режима + ключ HttpCache. Источник нод — снапшот в кэше,
/// перечитывания файла между сессиями нет (см. spec 129).
bool isFileSubscription(String url) => url.startsWith('file:');

/// Ссылка на ОДИН узел — по набору схем, которые разбирает конвейер.
///
/// §480 W6 — список схем ОДИН на приложение ([pipelineSchemes]): раньше
/// здесь лежала вторая его копия, и она успела разъехаться с первой —
/// `naive+quic://` конвейер разбирал, а классификатор ввода не знал, и
/// вставка такой ссылки из буфера падала на «not a subscription URL, proxy
/// link, or JSON». Ровно тем же дефектом раньше были `socks4://` (§475) и
/// `naive+https://`/`masque://` (§268): каждый чинился правкой ЭТОЙ копии,
/// то есть по одной схеме за находку.
///
/// `http(s)://` в набор не входит: голые схемы заняты [isSubscriptionUrl],
/// который проверяется раньше в `addFromInput` (§222), а прокси-формы
/// приходят своими написаниями (`proxy-https://`).
///
/// §512 — набор берётся у РЕЕСТРА (`detect.scheme_in` секций `mappers.uri`):
/// написание, приехавшее контрактом, вставляется из буфера без правки кода.
/// `amneziawg://` (1.1.48) — первый такой случай.
bool isDirectLink(String input) {
  final t = input.trim();
  final sep = t.indexOf('://');
  if (sep <= 0) return false;
  return pipelineSchemes().contains(t.substring(0, sep).toLowerCase());
}

/// §480 W6 — вид источника по РЕЕСТРУ: `kind` ветки, опознавшей ввод, либо
/// `null` (реестра нет — запасной путь у каждого вызывающего свой).
///
/// Классификаторы ниже спрашивают реестр, а не считают признак заново:
/// «что это за документ» — один вопрос с одним ответом, и второй его
/// экземпляр в UI-слое разъехался бы с первым ровно как разъехался список
/// схем у [isDirectLink].
String? documentKindOf(String input) {
  final reg = MapperSections.I.documents;
  if (reg == null) return null;
  // Спрашивается ВИД, а не содержимое: оболочку снимать не нужно и нечем —
  // распаковщики живут у декодера тела. `matchAll` отвечает предикатами,
  // победитель — с меньшим `priority` (норма §2).
  final hits = reg.matchAll(input);
  if (hits.isEmpty) return reg.defaultSource?.kind;
  var best = hits.first;
  for (final s in hits) {
    if (s.priority < best.priority) best = s;
  }
  return best.kind;
}

bool isWireGuardConfig(String input) {
  final kind = documentKindOf(input);
  if (kind != null) return kind == 'wireguard_conf';
  // Реестр не загружен — запасной признак тот же, что у реестра
  // (`source_kinds.json`): секция `[Interface]`; `[Peer]` не требуется.
  return input.trim().contains('[Interface]');
}

/// §110 — Amnezia `vpn://`-ссылка (контейнерный экспорт Amnezia/awg2).
/// Не direct link: внутри не одноузловой URI, а base64-контейнер.
bool isAmneziaVpnLink(String input) {
  final kind = documentKindOf(input);
  if (kind != null) return kind == 'amnezia_link';
  return input.trim().startsWith('vpn://');
}

/// §500 — метка в шапке шторки при отказе одиночного ввода: фрагмент ссылки
/// (`#tag`) или схема/тип входа.
String inputSourceLabel(String input) {
  final t = input.trim();
  final firstLine = t.split(RegExp(r'\r?\n')).first.trim();
  if (firstLine.contains('://')) {
    final uri = Uri.tryParse(firstLine);
    if (uri != null) {
      if (uri.fragment.isNotEmpty) return uri.fragment;
      if (uri.scheme.isNotEmpty) return uri.scheme;
    }
    final scheme = firstLine.split('://').first.toLowerCase();
    if (scheme.isNotEmpty) return scheme;
  }
  if (isWireGuardConfig(t)) return 'wireguard';
  if (firstLine.startsWith('{') || firstLine.startsWith('[')) {
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map) {
        final type = decoded['type'] ?? decoded['protocol'];
        if (type is String && type.isNotEmpty) return type;
      }
    } on FormatException {
      // ignore
    }
    return 'json';
  }
  return 'input';
}
