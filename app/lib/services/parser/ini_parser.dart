import '../../models/node_spec.dart';
import 'mappers/uri_pipeline.dart';
import 'mappers/wireguard_mapper.dart';

/// Разбор WireGuard INI (`wg-quick`) в `WireguardSpec`.
///
/// §472 шаг 7 — INI идёт ТЕМ ЖЕ КОНВЕЙЕРОМ, что и ссылка: маппер переводит
/// текст INI в сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель. Второй вход той же схемы отличается
/// ровно разбором входа — выход у обоих один
/// (`mappers/wireguard_mapper.dart`, [mapWireguardIni]).
///
/// Синтетического `wg://`-URI внутри БОЛЬШЕ НЕТ. Он был промежуточной формой
/// (§3.3, затем §456) и стоил двух лишних превращений текста — сборки query с
/// percent-кодированием и обратного разбора её же; на конвейере обе стороны
/// говорят картой, и посредник не нужен. Поведение при этом прежнее: имена
/// параметров у INI-маппера те же, что у query ссылки, и дальше обе воронки
/// сходятся в одном коде.
///
/// §456 — **источник узла (`rawSource`) это сам INI-текст, байт в байт**.
/// Конвейер кладёт в него свой аргумент, поэтому текст передаётся туда
/// напрямую.
///
/// §456 — **имя узла** (INI тега не несёт), по убыванию силы:
///
/// 1. первый комментарий сразу под `[Peer]` без `=` — Proton пишет туда имя
///    сервера (`# CH-FREE#11`); строки вида `# Bouncing = 0` в `[Interface]`
///    не годятся;
/// 2. [nameHint] — имя файла при импорте (§243), тег записи при чтении
///    хранения, поле Tag редактора при Save;
/// 3. `WireGuard`.
///
/// Тег хранится полем записи, не в тексте.
WireguardSpec? parseWireguardIni(String config, {String? nameHint}) {
  final peerName = peerCommentName(config);
  return parseIniViaPipeline(
    config,
    (text) => mapWireguardIni(text, nameHint: peerName ?? nameHint),
  ) as WireguardSpec?;
}

/// §456 — имя сервера из комментария под `[Peer]`: первая строка секции,
/// начинающаяся с `#`, без `=` (иначе это опция вроде `# Bouncing = 0`).
/// `null` — комментария нет.
String? peerCommentName(String config) {
  var inPeer = false;
  for (final line in config.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inPeer = t.toLowerCase() == '[peer]';
      continue;
    }
    if (!inPeer || t.isEmpty) continue;
    if (!t.startsWith('#')) break; // первая настоящая строка секции — имени нет
    final name = t.substring(1).trim();
    if (name.isEmpty || name.contains('=')) continue;
    return name;
  }
  return null;
}
