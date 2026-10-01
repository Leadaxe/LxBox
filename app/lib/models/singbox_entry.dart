/// Результат `NodeSpec.emit()` — либо sing-box outbound, либо endpoint
/// (WireGuard). Builder раскладывает по двум массивам через exhaustive
/// switch (§2.2 спеки 026). Никаких рантайм-проверок `type == 'wireguard'`.
sealed class SingboxEntry {
  SingboxEntry();
  Map<String, dynamic> get map;

  /// §577 — тело авторское (§576: свой сервер или член папки, не группа,
  /// вид источника ровно `singbox_outbound`, текст — JSON-объект): взято
  /// дословно (`verbatimBodyOf`), и шаги сборки правят его только жёсткими
  /// правилами реестра (`contract/body_edit.dart`). Ставит тот, кто тело
  /// подставил (`ServerListBuild`).
  bool authored = false;

  /// Живой геттер, читает `map['tag']`. Если post-step переименует тэг —
  /// всё, что держит ссылку на entry (preset-группы в ctx), увидит новое имя.
  String get tag => (map['tag'] as String?) ?? '';
}

final class Outbound extends SingboxEntry {
  @override
  final Map<String, dynamic> map;
  Outbound(this.map);
}

final class Endpoint extends SingboxEntry {
  @override
  final Map<String, dynamic> map;
  Endpoint(this.map);
}
