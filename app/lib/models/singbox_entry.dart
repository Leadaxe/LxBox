/// Результат `NodeSpec.emit()` — либо sing-box outbound, либо endpoint
/// (WireGuard). Builder раскладывает по двум массивам через exhaustive
/// switch (§2.2 спеки 026). Никаких рантайм-проверок `type == 'wireguard'`.
sealed class SingboxEntry {
  const SingboxEntry();
  Map<String, dynamic> get map;

  /// Живой геттер, читает `map['tag']`. Если post-step переименует тэг —
  /// всё, что держит ссылку на entry (preset-группы в ctx), увидит новое имя.
  String get tag => (map['tag'] as String?) ?? '';
}

final class Outbound extends SingboxEntry {
  @override
  final Map<String, dynamic> map;
  const Outbound(this.map);
}

final class Endpoint extends SingboxEntry {
  @override
  final Map<String, dynamic> map;
  const Endpoint(this.map);
}
