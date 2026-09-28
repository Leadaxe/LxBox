/// §449 — hostname узла Tailscale по умолчанию: по имени в админке tailnet
/// видно, что устройство заведено из LxBox. Каноническая связка секций узла
/// (правило маршрута, DNS-сервер и DNS-правило) отменена §575: её даёт пресет
/// шаблона (§578).
library;

/// §449 — префикс hostname по умолчанию: по имени в админке tailnet видно, что
/// устройство заведено из LxBox.
const String kTailscaleHostnamePrefix = 'LxBox';

/// §449 — потолок длины DNS-метки (`<hostname>.<tailnet>.ts.net`).
const int kTailscaleHostnameMaxLength = 63;

/// §449 — hostname узла по умолчанию: `LxBox-<модель устройства>`.
///
/// Пустое поле Hostname оставляет имя на откуп tsnet, а тот берёт имя хоста
/// системы: на стенде 15.09 узел вошёл в tailnet как `node`, и какой это из
/// серверов LxBox — по админке не прочитать. Tag узла в имя не идёт: он живёт
/// внутри приложения (заголовок записи и основа тега в конфиге ядра).
///
/// [model] — `SubscriptionIdentity.effectiveDeviceModel` (`Build.MODEL` либо
/// override из App Settings). Пустая или схлопнувшаяся целиком модель даёт
/// голый префикс: `LxBox` лучше, чем `LxBox-`.
String defaultTailscaleHostname(String model) {
  final suffix = _dnsLabelSegment(model);
  if (suffix.isEmpty) return kTailscaleHostnamePrefix;
  final room = kTailscaleHostnameMaxLength - kTailscaleHostnamePrefix.length - 1;
  final trimmed = suffix.length > room
      // Хвостовой дефис после обрезки снимаем: `LxBox-pixel-` — не метка.
      ? _stripDashes(suffix.substring(0, room))
      : suffix;
  if (trimmed.isEmpty) return kTailscaleHostnamePrefix;
  return '$kTailscaleHostnamePrefix-$trimmed';
}

/// Модель устройства как сегмент DNS-метки: латиница и цифры в нижнем
/// регистре, всё прочее (пробел, `_`, кириллица, эмодзи) — дефис, серии
/// схлопнуты, края очищены. `Pixel 7 Pro` → `pixel-7-pro`.
///
/// Санитизация тега (`tailscaleStateDirName`, §445) сюда не годится: там имя
/// каталога ФС со своим алфавитом, и схлопывание кириллицы в `___` дало бы
/// `LxBox----`.
String _dnsLabelSegment(String model) {
  final buf = StringBuffer();
  for (final code in model.toLowerCase().codeUnits) {
    final isDigit = code >= 0x30 && code <= 0x39;
    final isLetter = code >= 0x61 && code <= 0x7A;
    buf.writeCharCode(isDigit || isLetter ? code : 0x2D);
  }
  return _stripDashes(buf.toString());
}

/// Схлопывает серии дефисов и снимает их по краям.
String _stripDashes(String s) {
  final collapsed = s.replaceAll(RegExp(r'-+'), '-');
  return collapsed.replaceAll(RegExp(r'^-|-$'), '');
}
