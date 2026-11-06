/// §657 — ссылки Telegram в метаданных подписки (`support-url`).
///
/// Провайдеры отдают и веб-форму (`https://t.me/x`), и схему приложения
/// (`tg://resolve?domain=x`); признак по подстроке `t.me` вторую не видел.
library;

const _webHosts = {'t.me', 'telegram.me', 'telegram.dog'};

/// Ссылка ведёт в Telegram: схема `tg:` или хост t.me / telegram.me /
/// telegram.dog (с `www.` тоже).
bool isTelegramUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'tg') return true;
  if (scheme != 'http' && scheme != 'https') return false;
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  return _webHosts.contains(host);
}

/// Веб-форма `tg://`-ссылки для устройства без Telegram (§390 fallbackUrl).
/// null — ссылка не `tg://` или формы без веб-аналога.
String? telegramWebFallback(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'tg') return null;
  final q = uri.queryParameters;
  switch (uri.host.toLowerCase()) {
    case 'resolve':
      final domain = q['domain'] ?? '';
      if (domain.isEmpty) return null;
      final post = q['post'] ?? '';
      return post.isEmpty
          ? 'https://t.me/$domain'
          : 'https://t.me/$domain/$post';
    case 'join':
      final invite = q['invite'] ?? '';
      return invite.isEmpty ? null : 'https://t.me/+$invite';
  }
  return null;
}
