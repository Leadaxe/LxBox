/// §560 — разница между телом, которое прислал провайдер (после санитайзера),
/// и тем, что пишет типизированная модель узла.
///
/// Модель узла (`VlessSpec`, `SocksSpec`, …) держит не все поля тела ядра:
/// `multiplex`, `udp_over_tcp`, dial-поля, `workers`/`listen_port` и прочие
/// объявленные реестром ключи в ней полей не имеют и при `emit()` терялись
/// молча. Обратное тоже бывало: модель дописывала ключ, которого в теле не
/// было (`version` у socks, откат `tls.server_name` на адрес), — дефолт ядра,
/// который конвейер по норме контракта не материализует (PARSING_PRINCIPLES §2.4).
///
/// Дельта считается ОДИН раз при разборе, по схеме тела из реестра, и
/// накладывается на каждый `emit()`. Значения, которые модель пишет сама,
/// побеждают: дельта только добавляет недостающие ключи и снимает лишние.
/// Слой моделей реестра не знает — какие ключи учитывать, решил разбор.
library;

/// Путь ключа в теле: `['tls', 'server_name']`.
typedef BodyPath = List<String>;

final class BodyDelta {
  const BodyDelta({this.add = const [], this.drop = const []});

  /// Ключи тела, которых модель не пишет: путь → значение (JSON).
  final List<(BodyPath, Object?)> add;

  /// Ключи, которые модель дописала сама, а в теле их не было.
  final List<BodyPath> drop;

  bool get isEmpty => add.isEmpty && drop.isEmpty;

  /// Та же дельта без добавлений по путям [paths] (`tls.server_name`).
  BodyDelta? withoutAdds(Set<String> paths) {
    final kept = [
      for (final a in add)
        if (!paths.contains(a.$1.join('.'))) a,
    ];
    final out = BodyDelta(add: kept, drop: drop);
    return out.isEmpty ? null : out;
  }

  /// Наложить на свежую карту `emit()` (мутирует [map]).
  void applyTo(Map<String, dynamic> map, Object? Function(Object?) copy) {
    for (final p in drop) {
      final parent = _parentOf(map, p);
      parent?.remove(p.last);
    }
    for (final (p, v) in add) {
      final parent = _parentOf(map, p);
      if (parent == null || parent.containsKey(p.last)) continue;
      parent[p.last] = copy(v);
    }
  }

  static Map<String, dynamic>? _parentOf(Map<String, dynamic> map, BodyPath p) {
    Map<String, dynamic> cur = map;
    for (var i = 0; i < p.length - 1; i++) {
      final next = cur[p[i]];
      if (next is! Map) return null;
      // Подмодель могла отдать узко типизированную карту (`Map<String,
      // bool>` у uTLS): перекладываем в общую, чтобы дописать ключ иного типа.
      if (next is! Map<String, dynamic>) {
        final widened = Map<String, dynamic>.from(next);
        cur[p[i]] = widened;
        cur = widened;
      } else {
        cur = next;
      }
    }
    return cur;
  }
}
