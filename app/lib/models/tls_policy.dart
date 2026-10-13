/// §636 — переопределение TLS-ручек раздела «TLS Fragmentation» на узле,
/// папке и подписке. Каждое поле трёхзначное: `null` — наследовать с уровня
/// выше (узел → источник → глобальные `vars`), значение — своё. `false`
/// ниже бьёт `true` выше.
class TlsPolicy {
  /// `tls.fragment`.
  final bool? fragment;

  /// `tls.record_fragment`.
  final bool? recordFragment;

  /// `tls.fragment_fallback_delay` — duration-строка ядра как введена.
  final String? fallbackDelay;

  /// `server_name` в случайном регистре (пост-шаг сборки).
  final bool? mixedCaseSni;

  const TlsPolicy({
    this.fragment,
    this.recordFragment,
    this.fallbackDelay,
    this.mixedCaseSni,
  });

  static const none = TlsPolicy();

  /// Ключи записи (`tls` источника и члена папки).
  static const keys = {
    'fragment',
    'record_fragment',
    'fallback_delay',
    'mixed_case_sni',
  };

  bool get isEmpty =>
      fragment == null &&
      recordFragment == null &&
      fallbackDelay == null &&
      mixedCaseSni == null;

  bool get isNotEmpty => !isEmpty;

  /// Только заданные поля; пустая политика — пустой объект.
  Map<String, dynamic> toJson() => {
        if (fragment != null) 'fragment': fragment,
        if (recordFragment != null) 'record_fragment': recordFragment,
        if (fallbackDelay != null) 'fallback_delay': fallbackDelay,
        if (mixedCaseSni != null) 'mixed_case_sni': mixedCaseSni,
      };

  /// Терпимое чтение: не-объект — пустая политика; неизвестные ключи и
  /// значения не того типа игнорируются.
  static TlsPolicy fromJson(Object? raw) {
    if (raw is! Map) return none;
    bool? b(Object? v) => v is bool ? v : null;
    final d = raw['fallback_delay'];
    return TlsPolicy(
      fragment: b(raw['fragment']),
      recordFragment: b(raw['record_fragment']),
      fallbackDelay: d is String ? d : null,
      mixedCaseSni: b(raw['mixed_case_sni']),
    );
  }

  /// Частичная правка (PATCH): ключа нет в [patch] — поле не меняется,
  /// `null` — сброс в «наследовать». Значения не того типа — [FormatException].
  TlsPolicy patched(Map<String, dynamic> patch) {
    T? pick<T>(String k, T? cur) {
      if (!patch.containsKey(k)) return cur;
      final v = patch[k];
      if (v == null) return null;
      if (v is T) return v;
      throw FormatException('tls.$k: expected ${T == bool ? 'bool' : 'string'} or null');
    }

    return TlsPolicy(
      fragment: pick<bool>('fragment', fragment),
      recordFragment: pick<bool>('record_fragment', recordFragment),
      fallbackDelay: pick<String>('fallback_delay', fallbackDelay),
      mixedCaseSni: pick<bool>('mixed_case_sni', mixedCaseSni),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TlsPolicy &&
          fragment == other.fragment &&
          recordFragment == other.recordFragment &&
          fallbackDelay == other.fallbackDelay &&
          mixedCaseSni == other.mixedCaseSni);

  @override
  int get hashCode =>
      Object.hash(fragment, recordFragment, fallbackDelay, mixedCaseSni);

  @override
  String toString() => 'TlsPolicy(${toJson()})';
}

/// §636 — уровни TLS-политики одного outbound'а из источника: узловой
/// ([node]: член папки, одиночный сервер) и источника ([source]: подписка,
/// папка). Глобальный слой — `vars` пост-шага. Уровень важен не только для
/// приоритета: фрагментацию REALITY-узлу даёт только узловой.
class TlsLayers {
  final TlsPolicy node;
  final TlsPolicy source;

  const TlsLayers({this.node = TlsPolicy.none, this.source = TlsPolicy.none});

  bool get isEmpty => node.isEmpty && source.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TlsLayers && node == other.node && source == other.source;

  @override
  int get hashCode => Object.hash(node, source);
}
