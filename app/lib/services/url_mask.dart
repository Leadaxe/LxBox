/// Маскирует URL подписки до `scheme://host/***`.
///
/// Провайдер-credentials обычно живут в path/token части URL
/// (`https://provider/sub/<secret>`), поэтому при выдаче в логи / debug
/// API / шеринг по умолчанию светим только host. Если нужен полный URL
/// (reveal=true в debug API) — caller сам решит.
///
/// Централизовано здесь (night T2-3), чтобы controllers не тянули
/// `debug/serializers/` только ради одной функции.
String maskSubscriptionUrl(String raw) {
  if (raw.isEmpty) return '';
  // §129 — файловая подписка: `file:<uuid>` не несёт секретов (это локальный
  // ключ кэша), но и хоста у него нет. Светим как `file:<local>`, не `***`.
  if (raw.startsWith('file:')) return 'file:<local>';
  final u = Uri.tryParse(raw);
  if (u == null) return '***';
  if (u.host.isEmpty) return '***';
  return '${u.scheme}://${u.host}/***';
}

/// §638 — скрыть сетевые адреса в произвольном тексте ошибки (IPv4, IPv6,
/// доменные имена) → `***`; порт и остальной текст остаются.
///
/// Нужен для `VPN_ERROR(tunnel_error)`: сырая ошибка ядра вида
/// `dial tcp 1.2.3.4:443: i/o timeout` уходит broadcast'ом любому
/// подписчику Automation и не должна раскрывать адрес сервера.
String maskNetworkAddresses(String raw) {
  if (raw.isEmpty) return raw;
  var s = raw.replaceAll(_bracketV6Re, '[***]');
  s = s.replaceAllMapped(_bareV6Re, (m) {
    final t = m[0]!;
    // Время `12:34:56` и подобное — не адрес: нужен `::` или ≥3 двоеточий.
    final colons = ':'.allMatches(t).length;
    return (t.contains('::') || colons >= 3) ? '***' : t;
  });
  s = s.replaceAll(_v4Re, '***');
  s = s.replaceAll(_hostRe, '***');
  return s;
}

final _bracketV6Re = RegExp(r'\[[0-9A-Za-z:.%]*:[0-9A-Za-z:.%]*\]');
final _bareV6Re =
    RegExp(r'(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])');
final _v4Re = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
final _hostRe = RegExp(
    r'\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\b');
