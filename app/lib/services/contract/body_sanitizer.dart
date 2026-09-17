/// §460 W1 — санитайзер тела узла по схеме реестра контракта.
///
/// Работает по таблице 2.2 спеки: неизвестный ключ снимается, значение
/// проверяется типом/enum'ом/форматом/границами, нарушение уходит в
/// `on_invalid`, а связи между полями (`conflicts`, `requires`,
/// `forbidden_for`, `min_core`, `platform`) решаются после — когда состав
/// тела уже известен.
///
/// Чего санитайзер НЕ делает (осознанно, W1):
/// - не материализует `default` (CANON §2.4: дефолты не пишутся) — кроме
///   `all_or_nothing`, где дописать их велит сам реестр;
/// - не трогает `tag` и `detour`: их пишет сборка конфига, а не тело узла;
/// - не трогает `tristate`, `managed`, `deprecated`, `decision_pending`,
///   `drop_always`, `build_tag` — это волна W2.
///
/// Порядок ключей результата — `order` схемы (24.1.1): по нему же идёт
/// эмиттер, поэтому и список warnings детерминирован.
library;

import '../../models/node_warning.dart';
import '../parser/uri_utils.dart' show normalizeSingboxDuration;
import 'registry.dart';

/// Результат санитайзинга одной записи.
final class SanitizeResult {
  const SanitizeResult(this.body, this.warnings);

  /// Очищенное тело; `null` — запись снята целиком (`drop_node`).
  final Map<String, dynamic>? body;

  final List<RegistryWarning> warnings;
}

/// Ключи, которые санитайзер не трогает.
///
/// `tag`/`detour` пишет сборка конфига, а не тело узла (`detour` вычисляется
/// из Направлений и цепочек). `type` — сам дискриминатор записи: схему по
/// нему и выбрали, и в `body.order` протокола его нет именно поэтому.
const _kBuildManagedKeys = {'type', 'tag', 'detour'};

/// Код по умолчанию для нарушения `type`: в правилах реестра он явно не
/// пишется (SPEC 131 §3.2).
const _kDefaultInvalidCode = 'type_invalid';

/// Санитайзер тела записи по схеме реестра.
final class RegistrySanitizer {
  const RegistrySanitizer._();

  /// Очистить тело записи `outbounds[]`/`endpoints[]`.
  ///
  /// [scheme] — `type` записи (он же `singbox_type` реестра), [coreVersion] —
  /// версия запущенного ядра для гейта `min_core` (24.1.6), [platform] — ОС
  /// для гейта `platform`.
  ///
  /// Реестр не загружен либо схемы для [scheme] нет — тело возвращается как
  /// есть: неизвестный тип не повод выкидывать запись пользователя.
  static SanitizeResult sanitize(
    Map<String, dynamic> body, {
    required String scheme,
    required String coreVersion,
    String platform = 'android',
  }) {
    final schema = ContractRegistry.I.schemaFor(scheme);
    if (schema == null) return SanitizeResult(body, const []);

    final ctx = _Ctx(
      scheme: scheme,
      coreVersion: coreVersion,
      platform: platform,
      root: body,
    );
    final out = ctx.sanitizeObject(body, schema.order, schema.fields, '');
    if (ctx.dropNode) return SanitizeResult(null, ctx.warnings);
    return SanitizeResult(out, ctx.warnings);
  }
}

/// Состояние одного прогона: накопитель warnings, флаг `drop_node` и корень
/// тела — связи (`conflicts`/`requires`) адресуются путями от корня
/// (`tls.reality.public_key`), а не от текущего объекта.
final class _Ctx {
  _Ctx({
    required this.scheme,
    required this.coreVersion,
    required this.platform,
    required this.root,
  });

  final String scheme;
  final String coreVersion;
  final String platform;
  final Map<String, dynamic> root;

  final warnings = <RegistryWarning>[];
  bool dropNode = false;

  /// Снимок уже проверенных значений по абсолютному пути от корня тела.
  ///
  /// Связи (`conflicts`/`requires`) адресуются именно так
  /// (`tls.reality.public_key`), и смотреть им надо на состояние ПОСЛЕ
  /// проверки: поле, снятое как невалидное, зависимые обязаны считать
  /// отсутствующим — иначе `short_id` пережил бы мусорный `public_key`.
  final sanitized = <String, Object?>{};

  void warn(
    String code, {
    String? path,
    Object? value,
    bool secret = false,
    Map<String, String> params = const {},
  }) {
    warnings.add(RegistryWarning(
      code: code,
      path: path,
      value: value == null ? null : _renderValue(value, secret: secret),
      params: params,
    ));
  }

  /// Значение для текста предупреждения: у `secret`-полей — `***`, длинное
  /// обрезается до 64 символов (24.1.4).
  static String _renderValue(Object value, {bool secret = false}) {
    if (secret) return '***';
    final s = value is String ? value : value.toString();
    return s.length <= 64 ? s : '${s.substring(0, 61)}...';
  }

  /// Обход объекта по схеме. [prefix] — путь от корня тела (пустой у корня),
  /// он же адресация связей и текст `{path}` предупреждений.
  Map<String, dynamic> sanitizeObject(
    Map<String, dynamic> src,
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
  ) {
    final out = <String, dynamic>{};

    // 1. Неизвестные реестру ключи — снять (24.1.3). Ядро отвергает такой
    // ключ ошибкой на ВЕСЬ конфиг, оставить его нельзя.
    for (final key in src.keys) {
      if (fields.containsKey(key)) continue;
      if (prefix.isEmpty && _kBuildManagedKeys.contains(key)) continue;
      warn('unknown_key', path: _join(prefix, key));
    }

    // 2. Значения — по одному, в порядке схемы: и результат, и список
    // warnings становятся детерминированными.
    final kept = <String, Object?>{};
    for (final key in order) {
      final f = fields[key];
      if (f == null) continue;
      if (!src.containsKey(key)) {
        // `required` без поля — запись уходит целиком (24.1.7): ядро такую
        // не принимает и роняет весь конфиг.
        if (f.required) {
          dropNode = true;
          warn('field_missing', params: {'field': _join(prefix, key)});
        }
        continue;
      }
      final path = _join(prefix, key);
      final res = _sanitizeValue(src[key], f, path);
      if (dropNode) return out;
      if (res.keep) kept[key] = res.value;
    }

    // Состояние ПОСЛЕ проверки значений: связи обязаны видеть его, а не
    // исходное тело. Поле, снятое как невалидное, для зависимых от него —
    // отсутствует (reality.short_id без валидного public_key).
    for (final e in kept.entries) {
      sanitized[_join(prefix, e.key)] = e.value;
    }

    // 3. Связи между полями — когда состав уже известен: `requires` смотрит
    // на соседей, `conflicts` снимает младшее по `order`.
    _applyRelations(kept, order, fields, prefix);

    // Связи могли что-то снять — синхронизируем снимок.
    for (final key in order) {
      if (!kept.containsKey(key)) sanitized.remove(_join(prefix, key));
    }

    // Порядок ключей результата — ВХОДЯЩИЙ, а не `order` схемы.
    //
    // `order` реестра нормирует ЭМИТТЕР (24.1.1), а гард §460 — второй
    // эшелон над уже собранным телом: он снимает негодные значения, но
    // переставлять ключи ему нечего — валидный конфиг обязан остаться байт в
    // байт прежним (эталоны rich_v0/avd_v0). Порядок станет схемным вместе с
    // переездом эмиссии на реестр, волной W2.
    //
    // Ключи сборки (`type`/`tag`/`detour`) идут здесь же, на своих местах:
    // схема их не описывает, но снимать их нельзя — без `tag` запись
    // безымянна, без `detour` рушится маршрут.
    for (final key in src.keys) {
      if (kept.containsKey(key)) {
        out[key] = kept[key];
      } else if (prefix.isEmpty && _kBuildManagedKeys.contains(key)) {
        out[key] = src[key];
      }
    }
    // Ключи, появившиеся в санитайзинге (дефолты all_or_nothing лежат внутри
    // своего объекта, но на всякий случай) — в конец.
    for (final e in kept.entries) {
      if (!out.containsKey(e.key)) out[e.key] = e.value;
    }
    return out;
  }

  /// Гейты уровня поля, не зависящие от значения. `true` — поле снято.
  bool _gated(FieldSchema f, String path) {
    // `forbidden_for` / `allowed_for` — по схеме записи. Код обязателен по
    // схеме реестра; если его всё же нет, код типа лучше молчания.
    final forbidden = f.forbiddenFor;
    if (forbidden != null && forbidden.contains(scheme)) {
      warn(f.code ?? _kDefaultInvalidCode, path: path);
      return true;
    }
    final allowed = f.allowedFor;
    if (allowed != null && !allowed.contains(scheme)) {
      warn(f.code ?? _kDefaultInvalidCode, path: path);
      return true;
    }
    // `min_core` — гейт СБОРКИ (24.1.6): ключ, неизвестный запущенному ядру,
    // эмиттер опускает. Кода нет намеренно — узел жив и в порядке, причина
    // уходит в лог сборки, а не в ⚠ пользователю.
    final minCore = f.minCore;
    if (minCore != null && !coreAtLeast(coreVersion, minCore)) return true;
    // `platform` — то же самое: kTLS вне Linux валит весь конфиг.
    final plat = f.platform;
    if (plat != null && plat != platform) return true;
    return false;
  }

  _Value _sanitizeValue(Object? value, FieldSchema f, String path) {
    if (_gated(f, path)) return const _Value.drop();

    // `ref` — спуск в общую суб-схему (tls / multiplex / transports).
    final ref = f.ref;
    if (f.type == 'ref' && ref != null) {
      return _sanitizeRef(value, f, ref, path);
    }

    switch (f.type) {
      case 'object':
        return _sanitizeObjectField(value, f, path);
      case 'array':
        return _sanitizeArray(value, f, path);
      default:
        return _sanitizeScalar(value, f, path);
    }
  }

  _Value _sanitizeRef(Object? value, FieldSchema f, String ref, String path) {
    // `transports` — вариант по дискриминатору `transport.type`.
    if (ref == 'transports') {
      if (value is! Map) return _invalid(f, path, value);
      final map = value.cast<String, dynamic>();
      final type = map['type'];
      if (type is! String) {
        // Транспорт без `type` ядро не разберёт вовсе — тот же тип-фатал.
        return _invalid(f, path, value);
      }
      final variant = ContractRegistry.I.transportVariant(type);
      if (variant == null) return _invalid(f, path, type);
      // `type` — сам дискриминатор: в `order` варианта его нет, но снимать
      // его нельзя, иначе транспорт перестанет быть транспортом.
      final inner = Map<String, dynamic>.from(map)..remove('type');
      final cleaned =
          sanitizeObject(inner, variant.order, variant.fields, path);
      return _Value.keep(<String, dynamic>{'type': type, ...cleaned});
    }

    final shared = ContractRegistry.I.sharedSchema(ref);
    if (shared == null) return _Value.keep(value);
    // `dialer.common` — правило значения одного скаляра (server/server_port/
    // network), а не объект: поле описано ссылкой, но лежит плоско.
    if (ref == 'dialer.common') {
      final key = path.split('.').last;
      final sub = shared.fields[key];
      if (sub == null) return _Value.keep(value);
      return _sanitizeValue(value, sub, path);
    }
    if (value is! Map) return _invalid(f, path, value);
    final cleaned = sanitizeObject(
        value.cast<String, dynamic>(), shared.order, shared.fields, path);
    return _Value.keep(cleaned);
  }

  _Value _sanitizeObjectField(Object? value, FieldSchema f, String path) {
    if (value is! Map) return _invalid(f, path, value);
    final map = value.cast<String, dynamic>();
    final fields = f.fields;
    // Объект без `fields` — свободная карта (`transport.headers`): состав
    // задаёт не реестр, внутрь санитайзер не смотрит.
    if (fields == null) return _Value.keep(map);

    final cleaned = sanitizeObject(map, f.order ?? const [], fields, path);
    if (dropNode) return const _Value.drop();

    // `all_or_nothing` — в ядре задание одного поля обнуляет дефолты
    // соседних: частичный объект дописывается дефолтами явно, чтобы секция
    // вела себя так, как выглядит.
    if (f.allOrNothing && cleaned.isNotEmpty) {
      final missing = <String>[];
      for (final key in f.order ?? const <String>[]) {
        if (cleaned.containsKey(key)) continue;
        final def = fields[key]?.defaultValue;
        if (def == null) continue;
        missing.add(key);
      }
      if (missing.isNotEmpty) {
        final withDefaults = <String, dynamic>{};
        for (final key in f.order ?? const <String>[]) {
          if (cleaned.containsKey(key)) {
            withDefaults[key] = cleaned[key];
          } else if (missing.contains(key)) {
            withDefaults[key] = fields[key]!.defaultValue;
          }
        }
        warn('partial_object_defaulted', path: path);
        return _Value.keep(withDefaults);
      }
    }
    return _Value.keep(cleaned);
  }

  _Value _sanitizeArray(Object? value, FieldSchema f, String path) {
    if (value is! List) return _invalid(f, path, value);
    final items = f.items;
    if (items == null) return _Value.keep(value);
    final out = <Object?>[];
    for (var i = 0; i < value.length; i++) {
      final res = _sanitizeValue(value[i], items, '$path[$i]');
      if (dropNode) return const _Value.drop();
      if (res.keep) out.add(res.value);
    }
    // `len` у массива — точное число элементов (wireguard.peers[].reserved).
    final len = f.len;
    if (len != null && out.length != len) return _invalid(f, path, value);
    return _Value.keep(out);
  }

  _Value _sanitizeScalar(Object? value, FieldSchema f, String path) {
    final coerced = _coerceType(value, f.type);
    if (coerced == null) return _invalid(f, path, value);
    var v = coerced.value;

    // `normalize` — ДО проверки enum/format. Ставится только там, где ядро
    // case-sensitive и обе стороны нормализуют.
    final norm = f.normalize;
    if (norm != null && v is String) {
      v = switch (norm) {
        'trim' => v.trim(),
        'lower' => v.toLowerCase(),
        _ => v.trim().toLowerCase(),
      };
    }
    // `listable_string` нормализуется поэлементно.
    if (norm != null && v is List) {
      v = [
        for (final e in v)
          if (e is String)
            switch (norm) {
              'trim' => e.trim(),
              'lower' => e.toLowerCase(),
              _ => e.trim().toLowerCase(),
            }
          else
            e,
      ];
    }

    // `values` — закрытый набор. У `listable_string` проверяется каждый
    // элемент (network: tcp/udp).
    final values = f.values;
    if (values != null) {
      final bad = v is List
          ? v.where((e) => !values.contains(e)).toList()
          : (values.contains(v) ? const [] : [v]);
      if (bad.isNotEmpty) return _invalid(f, path, bad.first, secret: f.secret);
    }

    // `format` / `min` / `max` / `len` / `len_parity`.
    final violation = _checkConstraints(v, f);
    if (violation != null) {
      return _invalid(f, path, violation, secret: f.secret);
    }

    // `advisory` — ядро значение принимает, но узел получает info-код.
    // Поле НЕ меняется.
    for (final a in f.advisory) {
      final vals = (a['values'] as List?) ?? const [];
      if (!vals.contains(v)) continue;
      final code = a['code'] as String?;
      if (code == null) continue;
      warn(code,
          path: path,
          value: v,
          secret: f.secret,
          params: {'method': v is String ? v : '$v'});
    }

    return _Value.keep(v);
  }

  /// Нарушенное ограничение — возвращает значение для текста кода, `null`
  /// если всё в порядке.
  Object? _checkConstraints(Object? v, FieldSchema f) {
    final format = f.format;
    if (format != null && !_formatOk(v, format)) return v;

    final len = f.len;
    final parity = f.lenParity;
    // `len` у массива — число элементов (`reserved`: ровно три).
    if (v is List) {
      if (len != null && v.length != len) return v;
      return null;
    }
    if (v is String) {
      if (len != null && v.length != len) return v;
      if (parity != null) {
        final even = v.length.isEven;
        if ((parity == 'even') != even) return v;
      }
      // `min`/`max` у строки — границы ДЛИНЫ.
      final min = f.min;
      final max = f.max;
      if (format == null && f.type == 'string') {
        if (min != null && v.length < min) return v;
        if (max != null && v.length > max) return v;
      }
    }
    if (v is num) {
      final min = f.min;
      final max = f.max;
      if (min != null && v < min) return v;
      if (max != null && v > max) return v;
    }
    return null;
  }

  /// Нарушение ограничения → `on_invalid`. Без `on_invalid` — снять поле с
  /// кодом типа (спека §2.2).
  _Value _invalid(FieldSchema f, String path, Object? value,
      {bool secret = false}) {
    final rule = f.onInvalid;
    final code = rule?['code'] as String? ?? _kDefaultInvalidCode;
    final action = rule?['action'] as String? ?? 'drop';
    switch (action) {
      case 'coerce':
        warn(code, path: path, value: value, secret: secret || f.secret);
        return _Value.keep(rule?['value']);
      case 'drop_node':
        dropNode = true;
        warn(code,
            path: path,
            value: value,
            secret: secret || f.secret,
            params: {'field': path});
        return const _Value.drop();
      default:
        warn(code, path: path, value: value, secret: secret || f.secret);
        return const _Value.drop();
    }
  }

  /// `conflicts` и `requires` — после того, как состав объекта известен.
  void _applyRelations(
    Map<String, Object?> kept,
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
  ) {
    // `conflicts`: оба заданы → снимается младшее по `order`. Порядок
    // реестра = порядок структуры ядра, и «младшее» одинаково у обеих сторон.
    //
    // Правило конфликта записано у ОБОИХ участников (`tls.ech.enabled` ↔
    // `tls.reality.enabled`), поэтому решение принимается один раз — по
    // сравнению путей, а не по тому, чьё правило разбирается сейчас: иначе
    // сняло бы оба поля и узел потерял бы обе настройки.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      final myPath = _join(prefix, key);
      for (final rel in f.conflicts) {
        final with0 = rel['with'] as String?;
        if (with0 == null) continue;
        if (!_present(with0, kept, prefix)) continue;
        // Старший путь остаётся: он идёт раньше в порядке эмиссии.
        if (_pathBefore(myPath, with0)) continue;
        kept.remove(key);
        warn(rel['code'] as String? ?? 'field_conflict',
            path: myPath, params: {'with': with0});
        break;
      }
    }

    // `requires`: нет требуемого — поле снимается, само по себе не влияет.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      for (final rel in f.requires) {
        final need = rel['path'] as String?;
        if (need == null) continue;
        if (_present(need, kept, prefix)) continue;
        kept.remove(key);
        warn(rel['code'] as String? ?? 'field_requires',
            path: _join(prefix, key), params: {'requires': need});
        break;
      }
    }
  }

  /// Есть ли поле по пути связи — по состоянию ПОСЛЕ санитайзинга.
  ///
  /// Пути в реестре двух форм: абсолютные от корня тела
  /// (`tls.reality.public_key`) и короткие — имя соседа в том же объекте
  /// (`ip`, `realm`, `server_ports`). Сначала пробуем соседа: правила внутри
  /// одного объекта так и написаны.
  bool _present(String path, Map<String, Object?> siblings, String prefix) {
    if (!path.contains('.')) {
      return siblings.containsKey(path) && _meaningful(siblings[path]);
    }
    // Абсолютный путь: сперва снимок санитайзера, и только если ветка ещё не
    // обработана (связь смотрит вперёд) — исходное тело.
    if (sanitized.containsKey(path)) return _meaningful(sanitized[path]);
    final parent = path.substring(0, path.lastIndexOf('.'));
    // Родитель уже разобран, а ключа в снимке нет — значит поле снято.
    if (sanitized.containsKey(parent) || _branchDone(parent)) return false;

    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map) return false;
      if (!cur.containsKey(seg)) return false;
      cur = cur[seg];
    }
    return _meaningful(cur);
  }

  /// Разобрана ли уже ветка [prefix] — есть ли в снимке хоть один её ключ.
  bool _branchDone(String prefix) =>
      sanitized.keys.any((k) => k.startsWith('$prefix.'));

  /// `false` у bool-флага = «выключено», а не «задано»: `requires`
  /// `tls.utls.enabled` при `enabled: false` не выполнено.
  static bool _meaningful(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  /// Идёт ли [a] раньше [b] в порядке эмиссии тела. Пути конфликтов реестра
  /// абсолютны от корня (`tls.reality.enabled`), поэтому сравниваются
  /// посегментно по `order` схемы: посегментное сравнение — это и есть
  /// порядок, в котором эмиттер пишет ключи.
  bool _pathBefore(String a, String b) {
    if (a == b) return false;
    final sa = a.split('.');
    final sb = b.split('.');
    final ranks = _pathRanks(sa, sb);
    for (var i = 0; i < ranks.$1.length && i < ranks.$2.length; i++) {
      if (ranks.$1[i] != ranks.$2[i]) return ranks.$1[i] < ranks.$2[i];
    }
    // Один путь — префикс другого: родитель раньше потомка.
    return sa.length < sb.length;
  }

  /// Ранги сегментов обоих путей в схеме записи. Сегмент, которого схема не
  /// знает, получает ранг «в конец» — сравнение всё равно детерминировано.
  (List<int>, List<int>) _pathRanks(List<String> a, List<String> b) =>
      (_ranksOf(a), _ranksOf(b));

  List<int> _ranksOf(List<String> segments) {
    final out = <int>[];
    var schema = ContractRegistry.I.schemaFor(scheme);
    var order = schema?.order ?? const <String>[];
    var fields = schema?.fields ?? const <String, FieldSchema>{};
    for (final seg in segments) {
      final i = order.indexOf(seg);
      out.add(i < 0 ? 1 << 20 : i);
      final f = fields[seg];
      if (f == null) break;
      final ref = f.ref;
      if (f.type == 'ref' && ref != null && ref != 'transports') {
        schema = ContractRegistry.I.sharedSchema(ref);
        order = schema?.order ?? const [];
        fields = schema?.fields ?? const {};
        continue;
      }
      order = f.order ?? const [];
      fields = f.fields ?? const {};
    }
    return out;
  }
}

String _join(String prefix, String key) => prefix.isEmpty ? key : '$prefix.$key';

/// Приведение к типу реестра. `null` — не приводится (→ `on_invalid`).
///
/// Приведение пробуется сначала (`"443"`→443, `"true"`→true, float без
/// дробной части→int): подписки шлют числа строками, и ронять из-за этого
/// рабочий узел незачем (память json-map-type-assert-trap).
///
/// Правило приведения одно: значение, которое ядро принимает, санитайзер НЕ
/// переписывает. Поэтому число под `type: string` остаётся числом — так
/// записаны AWGRange-поля (`h1`..`h4`, `persistent_keepalive_interval`):
/// реестр зовёт их строкой, потому что они принимают и «min-max», но форма
/// числом законна, а её подмена на `"1"` меняла бы конфиг на ровном месте.
({Object? value})? _coerceType(Object? value, String type) {
  switch (type) {
    case 'string':
      if (value is String) return (value: value);
      if (value is num || value is bool) return (value: value);
      return null;
    case 'bool':
      if (value is bool) return (value: value);
      if (value is String) {
        if (value == 'true') return (value: true);
        if (value == 'false') return (value: false);
      }
      return null;
    case 'int':
    case 'uint16':
      if (value is int) return (value: value);
      if (value is double && value == value.roundToDouble()) {
        return (value: value.toInt());
      }
      if (value is String) {
        final n = int.tryParse(value.trim());
        if (n != null) return (value: n);
      }
      return null;
    case 'duration':
      if (value is String) return (value: normalizeSingboxDuration(value.trim()));
      // Голое число ядро читает как наносекунды, подписки имеют в виду
      // секунды — нормализуем той же функцией, что и парсеры.
      if (value is int) return (value: normalizeSingboxDuration('$value'));
      return null;
    case 'listable_string':
      if (value is String) return (value: value);
      if (value is List && value.every((e) => e is String || e is num)) {
        return (value: value);
      }
      return null;
    case 'string_array':
      // Числа в массиве оставляем как есть по тому же правилу: `reserved`
      // реестр зовёт string_array, а ядро читает `[]uint8` — три числа —
      // и именно так его пишут все источники.
      if (value is List && value.every((e) => e is String || e is num)) {
        return (value: value);
      }
      return null;
    case 'enum':
      // Набор проверяется отдельно; здесь только форма значения.
      if (value is String || value is int) return (value: value);
      return null;
    default:
      return (value: value);
  }
}

bool _formatOk(Object? v, String format) {
  if (v is List) return v.every((e) => _formatOk(e, format));
  switch (format) {
    case 'port':
      final n = v is int ? v : int.tryParse('$v');
      return n != null && n >= 1 && n <= 65535;
    case 'uuid':
      return v is String && _reUuid.hasMatch(v);
    case 'hex':
      return v is String && _reHex.hasMatch(v);
    case 'base64':
      return v is String && _reBase64.hasMatch(v);
    case 'host':
      return v is String && v.isNotEmpty && !v.contains(' ');
    case 'ipv4':
      return v is String && _ipv4Ok(v);
    case 'cidr':
      if (v is! String) return false;
      final parts = v.split('/');
      if (parts.length != 2) return false;
      final bits = int.tryParse(parts[1]);
      if (bits == null || bits < 0 || bits > 128) return false;
      return _ipv4Ok(parts[0]) || parts[0].contains(':');
    default:
      return true;
  }
}

bool _ipv4Ok(String v) {
  final parts = v.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

final _reUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _reHex = RegExp(r'^[0-9a-fA-F]*$');
final _reBase64 = RegExp(r'^[A-Za-z0-9+/_-]*={0,2}$');

/// Сравнение версий ядра `X.Y.Z-lx.N` (24.1.6). Суффикса `lx` нет — 0:
/// upstream-сборка старше любого форкового пина той же тройки.
bool coreAtLeast(String version, String required) {
  final a = _parseCore(version);
  final b = _parseCore(required);
  // Версия ядра неизвестна (пустая строка) — гейт не применяем: обрезать
  // поля из-за незнания хуже, чем оставить их ядру на разбор.
  if (a == null) return true;
  if (b == null) return true;
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return true;
}

List<int>? _parseCore(String v) {
  if (v.isEmpty) return null;
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-lx\.(\d+))?').firstMatch(v.trim());
  if (m == null) return null;
  return [
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.tryParse(m.group(4) ?? '0') ?? 0,
  ];
}

/// Результат обработки одного значения: оставить (с возможной заменой) или
/// снять.
final class _Value {
  const _Value.keep(this.value) : keep = true;
  const _Value.drop()
      : keep = false,
        value = null;

  final bool keep;
  final Object? value;
}
