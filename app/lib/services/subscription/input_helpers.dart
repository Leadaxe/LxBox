// Вспомогательные функции для UI-классификации пользовательского ввода
// (SubscriptionsScreen paste / "Add servers" поток). Чистые функции без
// зависимостей на контроллеры/стораджи.

bool isSubscriptionUrl(String input) {
  final t = input.trim();
  return t.startsWith('http://') || t.startsWith('https://');
}

/// §129 — файловая подписка. `url` = `file:<uuid>` (синтетический ключ, а не
/// путь): дискриминатор режима + ключ HttpCache. Источник нод — снапшот в кэше,
/// перечитывания файла между сессиями нет (см. spec 129).
bool isFileSubscription(String url) => url.startsWith('file:');

bool isDirectLink(String input) {
  final t = input.trim();
  return t.startsWith('vless://') ||
      t.startsWith('vmess://') ||
      t.startsWith('trojan://') ||
      t.startsWith('ss://') ||
      t.startsWith('hysteria2://') ||
      t.startsWith('hy2://') ||
      t.startsWith('tuic://') ||
      t.startsWith('ssh://') ||
      t.startsWith('wireguard://') ||
      t.startsWith('wg://') ||
      t.startsWith('awg://') ||
      t.startsWith('socks5://') ||
      t.startsWith('socks://') ||
      // §222 — кастомная схема HTTP(S)-прокси: голые http(s):// заняты
      // isSubscriptionUrl (проверяется раньше в addFromInput).
      t.startsWith('proxy-http://') ||
      t.startsWith('proxy-https://');
}

bool isWireGuardConfig(String input) {
  final t = input.trim();
  return t.contains('[Interface]') && t.contains('[Peer]');
}

/// §110 — Amnezia `vpn://`-ссылка (контейнерный экспорт Amnezia/awg2).
/// Не direct link: внутри не одноузловой URI, а base64-контейнер.
bool isAmneziaVpnLink(String input) => input.trim().startsWith('vpn://');
