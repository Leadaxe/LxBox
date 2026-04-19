// Вспомогательные функции для UI-классификации пользовательского ввода
// (SubscriptionsScreen paste / "Add servers" поток). Чистые функции без
// зависимостей на контроллеры/стораджи.

bool isSubscriptionUrl(String input) {
  final t = input.trim();
  return t.startsWith('http://') || t.startsWith('https://');
}

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
      t.startsWith('socks5://') ||
      t.startsWith('socks://');
}

bool isWireGuardConfig(String input) {
  final t = input.trim();
  return t.contains('[Interface]') && t.contains('[Peer]');
}
