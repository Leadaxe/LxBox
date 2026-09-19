/// §476 — генератор ПОЛНЫХ тел узла по схеме реестра.
///
/// Задача одна: из `registry/protocols/<схема>.json` (секция `body`) собрать
/// тела, в которых КАЖДОЕ поле схемы заполнено годным значением. По ним
/// сторожевой тест (`body_fields_roundtrip_test.dart`) гоняет круг
/// «тело → санитайзер → модель → emit» и ловит поле, которое разбор не читает.
///
/// **Почему генератор, а не рукописные фикстуры.** Рукописное тело стареет
/// молча: поле, добавленное бампом контракта, в него никто не впишет, и страж
/// пропустит ровно тот класс дефектов, ради которого заведён. Значения здесь
/// выводятся ИЗ САМОЙ СХЕМЫ, поэтому новое поле реестра попадает в тело в тот
/// же день, когда приезжает контракт.
///
/// **Незнакомое выражение реестра роняет генерацию** ([UnsupportedExpression]),
/// а не пропускается молча. Это обратная сторона предыдущего решения: тихий
/// пропуск вернул бы старение, только незаметнее — поле в теле как бы есть, но
/// без значения, и круг оно проходит ни о чём. Санитайзер на незнакомое
/// выражение реагирует наоборот (оставляет значение как есть, 24.1: реестр
/// впереди кода — рабочее состояние), и это не противоречие: у прода задача
/// пережить бамп контракта, у стража — заметить его.
///
/// **Несовместимые поля.** Одним телом схему не покрыть: `conflicts`,
/// `requires`, `forbidden_for`, варианты транспорта и пара `reality` ↔ `ech`
/// делают часть полей взаимоисключающими. Генератор возвращает НЕСКОЛЬКО тел
/// на протокол ([BodyVariant]) — по одному на несовместимую группу, и сам
/// считает, какое поле в каком теле побывало ([BodyVariant.covered]).
/// Непокрытое поле ловит тест.
library;

import 'package:lxbox/services/contract/registry.dart';

/// Выражение реестра, которого генератор не знает. Роняет тест с именем
/// выражения — молчаливый пропуск вернул бы старение фикстур.
/// §477 — образцы значений для полей с `pattern`, по пути поля.
///
/// Регулярка описывает МНОЖЕСТВО годных строк, а генератору нужна одна
/// конкретная, и вывести её из выражения в общем случае нельзя. Поэтому
/// образец пишется руками — но не молча: незнакомый путь роняет генерацию
/// ([UnsupportedExpression]), а образец, переставший подходить под выражение
/// реестра, роняет её тоже. Обе проверки держат таблицу живой при бампе
/// контракта.
///
/// `vless.encryption` — форма постквантового слоя: имя метода, вид, RTT и ключ
/// (§477, контракт 1.1.9).
const _kPatternSamples = <String, String>{
  'encryption': 'mlkem768x25519plus.native.0rtt.'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
};

final class UnsupportedExpression implements Exception {
  UnsupportedExpression(this.kind, this.name, this.path);

  /// `type` | `format` | `normalize`.
  final String kind;
  final String name;

  /// Путь поля в теле — чтобы было где искать.
  final String path;

  @override
  String toString() =>
      'реестр: незнакомое выражение $kind=$name (поле $path). '
      'Генератор §476 обязан уметь строить значение для каждого выражения '
      'схемы — допишите ветку в body_field_generator.dart';
}

/// Одно сгенерированное тело протокола.
final class BodyVariant {
  BodyVariant({
    required this.scheme,
    required this.name,
    required this.body,
    required this.covered,
  });

  /// `singbox_type` протокола.
  final String scheme;

  /// Имя группы совместимости — попадает в reason падения.
  final String name;

  /// Тело без `tag`/`detour`: их ставит сборка, а не автор узла.
  final Map<String, dynamic> body;

  /// Пути полей, которые это тело заполнило (от корня, `tls.reality.short_id`).
  final Set<String> covered;
}

/// Группы совместимости одного протокола.
///
/// Делить приходится по ЧЕТЫРЁМ независимым осям, и перемножать их не нужно:
/// поле обязано побывать хотя бы в одном теле, а не в каждом сочетании.
/// Поэтому оси переключаются по очереди, от базового тела.
///
/// 1. **транспорт** — `transport.type` дискриминатор, вариантов шесть, поля у
///    них разные (`ws.path` против `grpc.service_name`);
/// 2. **reality ↔ ech** — записаны взаимным `conflicts` у обоих;
/// 3. **`conflicts` внутри протокола** — `vless.flow` ↔ `transport`,
///    `multiplex.max_connections` ↔ `max_streams` и подобные;
/// 4. **`requires` с `equals`** — `hysteria2.obfs.min_packet_size` жив только
///    при `obfs.type = gecko`, и второе тело нужно под salamander.
List<BodyVariant> generateBodies(String scheme) {
  final schema = ContractRegistry.I.schemaFor(scheme);
  if (schema == null) return const [];
  final gen = _Generator(scheme);
  return gen.run(schema);
}

/// Поля схемы протокола — ПОЛНЫЙ список путей, которые обязаны быть покрыты.
///
/// Считается той же рекурсией, что и генерация, но без значений: так список
/// ожидаемого и список построенного заведомо считаются одним правилом.
Set<String> allFieldPaths(String scheme) {
  final schema = ContractRegistry.I.schemaFor(scheme);
  if (schema == null) return const {};
  final out = <String>{};
  _collectPaths(schema.order, schema.fields, '', out);
  return out;
}

void _collectPaths(
  List<String> order,
  Map<String, FieldSchema> fields,
  String prefix,
  Set<String> out,
) {
  for (final key in order) {
    final f = fields[key];
    if (f == null) continue;
    // `skip` — реестр сам не описал структуру поля (см. _Generator._skip).
    if (f.raw['skip'] != null) continue;
    final path = prefix.isEmpty ? key : '$prefix.$key';
    out.add(path);
    final ref = f.ref;
    if (f.type == 'ref' && ref != null) {
      if (ref == 'transports') {
        for (final t in _kTransportTypes) {
          final v = ContractRegistry.I.transportVariant(t);
          if (v == null) continue;
          _collectPaths(v.order, v.fields, '$path.$t', out);
        }
        continue;
      }
      if (ref == 'dialer.common' || ref.startsWith('dialer.common.')) continue;
      final shared = ContractRegistry.I.sharedSchema(ref);
      if (shared == null) continue;
      _collectPaths(shared.order, shared.fields, path, out);
      continue;
    }
    final sub = f.fields;
    if (sub != null) {
      _collectPaths(f.order ?? sub.keys.toList(), sub, path, out);
    }
  }
}

/// Запрещает ли реестр поле [path] схеме [scheme] — сам или через родителя.
///
/// `forbidden_for`/`allowed_for` стоят на БЛОКЕ (`tls.utls` целиком запрещён
/// QUIC-схемам), поэтому запрет наследуется вниз: запрещён блок — запрещены и
/// его поля. Без этого страж покрытия требовал бы от naive тело с `tls.reality`,
/// которого реестр ему не даёт.
bool forbiddenByRegistry(String scheme, String path) {
  final schema = ContractRegistry.I.schemaFor(scheme);
  if (schema == null) return false;
  Map<String, FieldSchema>? fields = schema.fields;
  for (final seg in path.split('.')) {
    final f = fields?[seg];
    if (f == null) return false;
    final forbidden = f.forbiddenFor;
    if (forbidden != null && forbidden.contains(scheme)) return true;
    final allowed = f.allowedFor;
    if (allowed != null && !allowed.contains(scheme)) return true;
    final ref = f.ref;
    if (f.type == 'ref' && ref != null && ref != 'transports') {
      fields = ContractRegistry.I.sharedSchema(ref)?.fields;
    } else {
      fields = f.fields;
    }
  }
  return false;
}

/// Варианты транспорта — перечислены поимённо по той же причине, что и файлы
/// протоколов в реестре: каталог не листается, а состав меняется вместе с
/// бампом контракта. Расхождение ловит тест покрытия.
const _kTransportTypes = <String>['ws', 'grpc', 'http', 'httpupgrade', 'xhttp', 'quic'];

/// Непересекающиеся полосы magic-заголовков AWG: связь реестра
/// `ranges_disjoint` роняет узел, если диапазоны `h1`–`h4` пересеклись, а
/// одним образцом на весь тип `awg_range` они совпадали бы все четыре.
const _kAwgHeaderBands = <String, String>{
  'h1': '10-20',
  'h2': '30-40',
  'h3': '50-60',
  'h4': '70-80',
};

final class _Generator {
  _Generator(this.scheme);

  final String scheme;

  List<BodyVariant> run(BodySchema schema) {
    final out = <BodyVariant>[];

    // Базовое тело: транспорт ws, TLS с reality, без ech.
    out.add(_build(schema, name: 'base', transport: 'ws', tlsMode: _TlsMode.reality));

    // Ось 1 — остальные транспорты. Каждый несёт свои поля варианта.
    for (final t in _kTransportTypes.skip(1)) {
      if (ContractRegistry.I.transportVariant(t) == null) continue;
      out.add(_build(schema, name: 'transport=$t', transport: t, tlsMode: _TlsMode.reality));
    }

    // Ось 2 — ech вместо reality.
    out.add(_build(schema, name: 'tls=ech', transport: 'ws', tlsMode: _TlsMode.ech));

    // Ось 3 — без транспорта вовсе: поля, конфликтующие с transport
    // (`vless.flow`), живут только здесь.
    out.add(_build(schema, name: 'no-transport', transport: null, tlsMode: _TlsMode.reality));

    // Ось 4 — второй вариант у полей с `requires`+`equals` (obfs gecko против
    // salamander). Собирается только если такие поля у схемы есть.
    final alt = _equalsAlternatives(schema);
    for (final a in alt) {
      out.add(_build(schema,
          name: 'equals:${a.key}=${a.value}',
          transport: 'ws',
          tlsMode: _TlsMode.reality,
          equalsOverride: a));
    }

    // Ось 5 — поля TLS, конфликтующие с тем, что базовое тело кладёт всегда:
    // каждому нужно тело, где уступает НЕ ОНО, а сосед.
    for (final excl in _kTlsExclusive) {
      out.add(_build(schema,
          name: 'tls-exclusive=$excl',
          transport: 'ws',
          // `disable_sni`/`spoof` конфликтуют с `tls.reality.enabled`: их тело
          // обязано идти без REALITY, иначе уступят они же. У
          // `certificate_public_key_sha256` соперники другие (`certificate`,
          // `certificate_path`), и REALITY ему не мешает — иначе поля блока
          // не побывали бы ни в одном теле этой оси.
          tlsMode: _kTlsExclusiveNeedsNoReality.contains(excl)
              ? _TlsMode.none
              : _TlsMode.reality,
          tlsExclusive: excl));
    }

    // Ось 6 — то же самое на КОРНЕ тела: поле, уступающее соседу по
    // `conflicts`, получает тело, где сосед снят. Так покрываются
    // AWG-генераторы `i1`/`i2` (уступают `id`/`ip`/`ib`) и `listen_port`.
    for (final key in _rootConflictLosers(schema)) {
      out.add(_build(schema,
          name: 'root-exclusive=$key',
          transport: 'ws',
          tlsMode: _TlsMode.reality,
          rootExclusive: key));
    }

    // Ось 7 — вложенные пары (`transport.xhttp.xmux.max_concurrency` уступает
    // соседу `max_connections`). Тело собирается на том транспорте, где поле
    // живёт, и соперник в нём снят.
    for (final loser in _nestedConflictLosers(schema)) {
      out.add(_build(schema,
          name: 'nested-exclusive=$loser',
          transport: _transportOfPath(loser) ?? 'ws',
          tlsMode: _TlsMode.reality,
          nestedExclusive: loser));
    }
    return out;
  }

  /// Транспорт, внутри варианта которого лежит путь (`transport.xhttp.…`).
  String? _transportOfPath(String path) {
    final parts = path.split('.');
    if (parts.length < 2 || parts.first != 'transport') return null;
    return _kTransportTypes.contains(parts[1]) ? parts[1] : null;
  }

  /// Вложенные поля, уступающие соседу по `conflicts` — полным путём.
  List<String> _nestedConflictLosers(BodySchema schema) {
    final out = <String>[];
    void walk(List<String> order, Map<String, FieldSchema> fields, String prefix) {
      for (final key in order) {
        final f = fields[key];
        if (f == null) continue;
        final path = prefix.isEmpty ? key : '$prefix.$key';
        if (prefix.isNotEmpty && f.conflicts.isNotEmpty) {
          final rivals = [
            for (final r in f.conflicts)
              if (r['with'] is String) r['with'] as String,
          ];
          // Соперник-сосед по тому же объекту: его снимет ось.
          if (rivals.any((r) => r.split('.').last != key)) out.add(path);
        }
        final sub = f.fields;
        if (sub != null) walk(f.order ?? sub.keys.toList(), sub, path);
      }
    }

    for (final t in _kTransportTypes) {
      final v = ContractRegistry.I.transportVariant(t);
      if (v == null) continue;
      walk(v.order, v.fields, 'transport.$t');
    }
    return out;
  }

  /// Поля КОРНЯ тела, которые уступают соседу по `conflicts`. Каждому нужно
  /// своё тело: иначе поле не побывает ни в одном, и круг его не проверит.
  ///
  /// Только корень: вложенные пары (`xmux.max_concurrency` ↔
  /// `xmux.max_connections`) разводит [_nestedConflictLosers].
  List<String> _rootConflictLosers(BodySchema schema) {
    final out = <String>[];
    for (final key in schema.order) {
      final f = schema.fields[key];
      if (f == null || f.conflicts.isEmpty) continue;
      if (f.raw['skip'] != null) continue;
      // Соседи, которых генератор кладёт сам (не оси TLS/транспорта).
      final rivals = <String>[
        for (final r in f.conflicts)
          if (r['with'] is String) r['with'] as String,
      ].where((p) => p != 'transport' && !p.startsWith('tls.')).toList();
      if (rivals.isEmpty) continue;
      // `detour` тело не несёт вовсе — конфликт с ним не мешает.
      if (rivals.every((r) => _kBuildManaged.contains(r))) continue;
      out.add(key);
    }
    return out;
  }

  /// Значения `requires.equals`, отличные от того, что генератор выбирает по
  /// умолчанию: каждое просит своего тела, иначе зависимые от него поля
  /// («min_packet_size» при gecko) не побывают ни в одном.
  List<MapEntry<String, Object?>> _equalsAlternatives(BodySchema schema) {
    final out = <MapEntry<String, Object?>>[];
    final seen = <String>{};
    void walk(List<String> order, Map<String, FieldSchema> fields, String prefix) {
      for (final key in order) {
        final f = fields[key];
        if (f == null) continue;
        final path = prefix.isEmpty ? key : '$prefix.$key';
        for (final r in f.requires) {
          if (!r.containsKey('equals')) continue;
          final target = r['path'] as String?;
          if (target == null) continue;
          final v = r['equals'];
          final id = '$target=$v';
          if (seen.add(id)) out.add(MapEntry(target, v));
        }
        final sub = f.fields;
        if (sub != null) walk(f.order ?? sub.keys.toList(), sub, path);
      }
    }

    walk(schema.order, schema.fields, '');
    return out;
  }

  BodyVariant _build(
    BodySchema schema, {
    required String name,
    required String? transport,
    required _TlsMode tlsMode,
    MapEntry<String, Object?>? equalsOverride,
    String? tlsExclusive,
    String? rootExclusive,
    String? nestedExclusive,
  }) {
    final ctx = _BuildCtx(
      transport: transport,
      tlsMode: tlsMode,
      equalsOverride: equalsOverride,
      tlsExclusive: tlsExclusive,
      rootExclusive: rootExclusive,
      nestedExclusive: nestedExclusive,
    );
    final body = _object(schema.order, schema.fields, '', ctx);
    body['type'] = scheme;
    return BodyVariant(
      scheme: scheme,
      name: name,
      body: body,
      covered: ctx.covered,
    );
  }

  Map<String, dynamic> _object(
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
    _BuildCtx ctx,
  ) {
    final out = <String, dynamic>{};
    // Поля, снятые осью совместимости этого тела: их значение в тело не
    // кладётся и покрытым оно не считается.
    for (final key in order) {
      final f = fields[key];
      if (f == null) continue;
      final path = prefix.isEmpty ? key : '$prefix.$key';
      if (_skip(f, path, ctx)) continue;
      final v = _value(f, path, ctx);
      if (v == _kOmit) continue;
      out[key] = v;
      ctx.covered.add(path);
    }
    return out;
  }

  /// Поле, которое в ЭТОМ теле не участвует: запрещено схеме
  /// (`forbidden_for`/`allowed_for`), уступает оси совместимости
  /// (`conflicts`), либо его `requires` в этом теле не выполнен.
  bool _skip(FieldSchema f, String path, _BuildCtx ctx) {
    // `skip` реестра — поле, чью структуру контракт СОЗНАТЕЛЬНО не расписал
    // (`hysteria2.realm`: «поля опишем вместе с поддержкой realm в лаунчере»).
    // Значение для него не из чего строить, и круг его не проверяет.
    if (f.raw['skip'] != null) return true;
    final forbidden = f.forbiddenFor;
    if (forbidden != null && forbidden.contains(scheme)) return true;
    final allowed = f.allowedFor;
    if (allowed != null && !allowed.contains(scheme)) return true;

    // Ключи, которые приложение выставляет само: тело автора их не несёт.
    if (_kBuildManaged.contains(path)) return true;

    // Ось reality ↔ ech.
    if (path == 'tls.reality' && ctx.tlsMode != _TlsMode.reality) return true;
    if (path == 'tls.ech' && ctx.tlsMode != _TlsMode.ech) return true;

    // Ось «эксклюзивное поле TLS»: поле из этого списка живёт ТОЛЬКО в своём
    // теле. В прочих телах его нет вовсе — иначе оно снимало бы
    // `tls.reality.enabled`, с которым конфликтует, и флаг REALITY не побывал
    // бы ни в одном теле.
    if (_kTlsExclusive.contains(path) && path != ctx.tlsExclusive) return true;

    // Ось 6 — соперники поля, ради которого собрано тело, в него не идут.
    if (ctx.rootExclusive != null && ctx.rivalsOfRootExclusive.contains(path)) {
      return true;
    }

    // Ось 7 — то же для вложенной пары: сосед-соперник снят, поле остаётся.
    final nested = ctx.nestedExclusive;
    if (nested != null && path != nested) {
      final parent = nested.substring(0, nested.lastIndexOf('.'));
      if (path.startsWith('$parent.') &&
          !path.substring(parent.length + 1).contains('.')) {
        // Внутри объекта-владельца оставляем только само поле: соперники
        // записаны соседями, и какой из них чей — решает реестр, не мы.
        for (final rel in f.conflicts) {
          if (rel['with'] is String) return true;
        }
        // Поле-соперник узнаётся с другой стороны: оно названо в `conflicts`
        // эксклюзивного поля.
        if (ctx.rivalsOfNested.contains(path.split('.').last)) return true;
      }
    }

    // Ось транспорта.
    if (path == 'transport' && ctx.transport == null) return true;

    // `conflicts` — уступает декларант, ровно как в санитайзере (§474).
    //
    // Поле, РАДИ которого собрано тело оси, соперникам не уступает: их из
    // этого тела и снимают. Иначе `tls.spoof` уступал бы `tls.disable_sni`,
    // которого в его собственном теле нет.
    final chosen = path == ctx.tlsExclusive ||
        path == ctx.rootExclusive ||
        path == ctx.nestedExclusive;
    if (!chosen) {
      for (final rel in f.conflicts) {
        final with0 = rel['with'] as String?;
        if (with0 == null) continue;
        if (_willBePresent(with0, ctx)) return true;
      }
    }

    // `requires` с `equals`: поле живёт только при конкретном значении соседа.
    for (final rel in f.requires) {
      if (!rel.containsKey('equals')) continue;
      final target = rel['path'] as String?;
      if (target == null) continue;
      if (ctx.equalsValueFor(target) != rel['equals']) return true;
    }
    return false;
  }

  /// Будет ли сосед в этом теле — по осям совместимости. Точности хватает
  /// ровно на то, чтобы не положить в одно тело обе стороны конфликта.
  ///
  /// Пути REALITY и ECH разбираются с ПРЕФИКСОМ (`tls.reality.enabled`, а не
  /// только `tls.reality`): конфликты реестра записаны именно на флагах
  /// (`tls.ech.enabled` ↔ `tls.reality.enabled`), и без этого обе стороны
  /// считались бы присутствующими всегда — оба флага уступали бы друг другу и
  /// не попадали ни в одно тело.
  bool _willBePresent(String path, _BuildCtx ctx) {
    // Ключи, которые тело автора не несёт вовсе (`detour` ставит сборка):
    // конфликт с ними не срабатывает никогда, и поле остаётся.
    if (_kBuildManaged.contains(path)) return false;
    if (path == 'transport') return ctx.transport != null;
    if (path == 'tls.reality' || path.startsWith('tls.reality.')) {
      return ctx.tlsMode == _TlsMode.reality;
    }
    if (path == 'tls.ech' || path.startsWith('tls.ech.')) {
      return ctx.tlsMode == _TlsMode.ech;
    }
    // Ось «взаимные конфликты внутри TLS»: `disable_sni`, `spoof` и
    // `certificate_public_key_sha256` конфликтуют с соседями, которых базовое
    // тело кладёт всегда, и без своей оси не побывали бы нигде. В теле они
    // есть РОВНО ТОГДА, когда тело собрано ради них.
    if (_kTlsExclusive.contains(path)) return ctx.tlsExclusive == path;
    // Ось 6: соперники поля, ради которого собрано это тело, сняты.
    if (ctx.rootExclusive != null && !path.contains('.')) {
      return !ctx.rivalsOfRootExclusive.contains(path);
    }
    return true;
  }

  Object? _value(FieldSchema f, String path, _BuildCtx ctx) {
    final ref = f.ref;
    if (f.type == 'ref' && ref != null) {
      if (ref == 'transports') {
        final t = ctx.transport;
        if (t == null) return _kOmit;
        final variant = ContractRegistry.I.transportVariant(t);
        if (variant == null) return _kOmit;
        final inner = _object(variant.order, variant.fields, '$path.$t', ctx);
        return <String, dynamic>{'type': t, ...inner};
      }
      // `dialer.common` — правило значения ОДНОГО скаляра, лежащего плоско.
      // Имя поля берётся из самого `ref`, когда он его называет
      // (`dialer.common.network` у masque: поле зовётся `network_list`, а
      // правило у него сетевое), иначе — по последнему сегменту пути.
      if (ref == 'dialer.common' || ref.startsWith('dialer.common.')) {
        final shared = ContractRegistry.I.sharedSchema('dialer.common');
        final named = ref.startsWith('dialer.common.')
            ? ref.substring('dialer.common.'.length)
            : path.split('.').last;
        final sub = shared?.fields[named];
        if (sub == null) return _kOmit;
        return _value(sub, path, ctx);
      }
      final shared = ContractRegistry.I.sharedSchema(ref);
      if (shared == null) return _kOmit;
      return _object(shared.order, shared.fields, path, ctx);
    }

    switch (f.type) {
      case 'object':
        final sub = f.fields;
        // Объект без `fields` — свободная карта (`transport.headers`):
        // состав задаёт не реестр, кладём образец из одной пары.
        if (sub == null) return <String, dynamic>{'X-Sample': 'lxbox'};
        return _object(f.order ?? sub.keys.toList(), sub, path, ctx);
      case 'array':
        final items = f.items;
        if (items == null) return <Object?>['sample'];
        final n = f.len ?? 1;
        return <Object?>[
          for (var i = 0; i < n; i++) _value(items, '$path[$i]', ctx),
        ];
      default:
        return _scalar(f, path, ctx);
    }
  }

  Object? _scalar(FieldSchema f, String path, _BuildCtx ctx) {
    // Поле, чьё значение задаёт ось `equals`: оно обязано совпасть с тем, что
    // ждут зависимые от него поля этого тела.
    final forced = ctx.equalsForcedValue(path);
    if (forced != null) return forced;

    // Закрытый набор — первое ГОДНОЕ значение. Пустая строка в наборе это
    // «не задано»: положив её, мы бы не проверили ничего.
    //
    // Списочные типы берут элемент из того же набора, но кладут его СПИСКОМ:
    // `curve_preferences` это `listable_string` с `values`, и голая строка
    // прошла бы санитайзер, а формой реестра быть перестала.
    final values = f.values;
    final pick = values == null ? null : _firstUsable(values);
    if (pick != null && !_kListTypes.contains(f.type)) return pick;

    // ВАЖЕН ПОРЯДОК: тип проверяется раньше формата. `address` и
    // `allowed_ips` у wireguard это `string_array` с `format: cidr`, и разбор
    // «по формату» отдал бы голую строку — поле стало бы негодным, а
    // `required` снял бы весь узел.
    final format = f.format;

    switch (f.type) {
      case 'string':
        return format != null ? _byFormat(format, f, path) : _string(f, path);
      case 'listable_string':
      case 'string_array':
        // Списочная форма — она шире: круг обязан пережить и её.
        final one = pick ??
            (format != null ? _byFormat(format, f, path) : _string(f, path));
        return <Object?>[one];
      case 'int_array':
        final n = f.len ?? 3;
        return <int>[for (var i = 0; i < n; i++) i];
      case 'bool':
        return true;
      case 'int':
      case 'uint16':
        return format != null ? _byFormat(format, f, path) : _int(f, path);
      case 'duration':
        return '30s';
      case 'awg_range':
        // Диапазоны magic-заголовков h1–h4 обязаны НЕ пересекаться: связь
        // реестра `ranges_disjoint` (контракт 1.1.11) иначе роняет узел с
        // `awg_headers_overlap`, и круг не проверил бы ни одного поля
        // wireguard. Отсюда своя полоса каждому заголовку — в том же порядке,
        // каким реестр задаёт их дефолты ядра (h1=1 … h4=4).
        final band = _kAwgHeaderBands[path.split('.').last];
        return band ?? '10-20';
      case 'enum':
        // enum без `values` реестр писать не должен, но если написал —
        // выдумывать набор нечего.
        throw UnsupportedExpression('enum-without-values', f.type, path);
      default:
        throw UnsupportedExpression('type', f.type, path);
    }
  }

  /// Первое годное значение закрытого набора: `null` и пустая строка в нём
  /// означают «не задано», и проверять на них нечего.
  Object? _firstUsable(List<Object?> values) {
    for (final v in values) {
      if (v == null) continue;
      if (v is String && v.isEmpty) continue;
      return v;
    }
    return null;
  }

  Object _byFormat(String format, FieldSchema f, String path) {
    switch (format) {
      case 'port':
        return 443;
      case 'uuid':
        return 'b831381d-6324-4d53-ad4f-8cda48b30811';
      case 'hex':
        // `len`/`len_parity` — у reality.short_id.
        final len = f.len ?? (f.lenParity == 'even' ? 8 : 8);
        return List.filled(len, 'a').join();
      case 'base64':
        return 'c2FtcGxl';
      case 'base64_32':
        // Ровно 32 байта после декода — иначе санитайзер снимет поле.
        return 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      case 'host':
        return 'example.com';
      case 'ipv4':
        return '10.0.0.2';
      case 'cidr':
        return '10.0.0.2/32';
      case 'url_path':
        return '/sample';
      default:
        throw UnsupportedExpression('format', format, path);
    }
  }

  Object _string(FieldSchema f, String path) {
    final norm = f.normalize;

    // §477 — поле с `pattern`: образец берётся из таблицы ниже.
    //
    // Это единственное выражение реестра, из которого значение НЕ выводится:
    // по регулярке в общем случае образца не построить, а `sample` заведомо
    // не подойдёт — такое поле снимет `on_invalid`, и у `vless.encryption`
    // это `drop_node`, то есть круг не проверил бы ничего вовсе.
    //
    // Таблица держится по ПУТИ и роняет генерацию на незнакомом пути, как и
    // всё остальное здесь: новое поле с `pattern`, приехавшее бампом
    // контракта, обязано получить образец осознанно, а не пройти молча.
    final pattern = f.pattern;
    if (pattern != null) {
      final sample = _kPatternSamples[path];
      if (sample == null) throw UnsupportedExpression('pattern', pattern, path);
      // Образец обязан удовлетворять САМОМУ выражению реестра: разъедься они
      // при бампе контракта — круг снова проверял бы отсутствие поля.
      if (!RegExp(pattern).hasMatch(sample)) {
        throw UnsupportedExpression(
            'pattern-sample-mismatch', pattern, path);
      }
      return sample;
    }

    // Значение обязано ПЕРЕЖИТЬ нормализацию без изменений: иначе круг
    // сравнивал бы не с тем, что положили. `hex_only` поэтому даёт hex,
    // `trim_lower` — нижний регистр без пробелов.
    const base = 'sample';
    final len = f.len;
    if (norm == 'hex_only') {
      return List.filled(len ?? 8, 'a').join();
    }
    if (norm != null && !const {'trim', 'lower', 'trim_lower'}.contains(norm)) {
      throw UnsupportedExpression('normalize', norm, path);
    }
    if (len != null) return List.filled(len, 'a').join();
    final min = f.min;
    final max = f.max;
    var s = base;
    if (min != null && s.length < min) s = s.padRight(min.toInt(), 'x');
    if (max != null && s.length > max) s = s.substring(0, max.toInt());
    return s;
  }

  int _int(FieldSchema f, [String path = '']) {
    // AWG 3 (§421): при заданном `header_protection_key` ядро требует padding
    // не меньше 12 — правило живёт в ядре и в нашем гарде, реестр его как
    // `min` не выражает. Меньшее значение снимает узел целиком, и круг не
    // проверил бы ничего.
    if (const {'s1', 's2', 's3', 's4'}.contains(path)) return 16;
    final min = f.min?.toInt();
    final max = f.max?.toInt();
    // `max_when` — условный потолок: значение под ним, иначе санитайзер
    // заменит его и круг сравнивал бы не с тем, что положили.
    final ceiling = f.maxWhen?['max'];
    var v = 8;
    if (min != null && v < min) v = min;
    if (max != null && v > max) v = max;
    if (ceiling is num && v > ceiling) v = ceiling.toInt();
    return v;
  }
}

/// Ключи, которые проставляет приложение, а не автор тела.
const _kBuildManaged = {'tag', 'detour', 'domain_resolver'};

/// Поля TLS, которые конфликтуют с тем, что базовое тело кладёт всегда
/// (`certificate`, `reality.enabled`). Каждому нужно СВОЁ тело, иначе они
/// уступают по `conflicts` и не побывают ни в одном.
const _kTlsExclusive = <String>[
  'tls.disable_sni',
  'tls.spoof',
  'tls.certificate_public_key_sha256',
];

/// Из них те, чей соперник — `tls.reality.enabled`: их тело идёт без REALITY.
const _kTlsExclusiveNeedsNoReality = {'tls.disable_sni', 'tls.spoof'};

/// Типы реестра, чьё значение едет СПИСКОМ.
const _kListTypes = {'listable_string', 'string_array'};

/// Маркер «поля в теле нет».
const Object _kOmit = Object();

/// Режим TLS-блока тела. [none] — ни REALITY, ни ECH: на нём живут поля,
/// конфликтующие с `reality.enabled` (`disable_sni`, `spoof`).
enum _TlsMode { reality, ech, none }

final class _BuildCtx {
  _BuildCtx({
    required this.transport,
    required this.tlsMode,
    required this.equalsOverride,
    this.tlsExclusive,
    this.rootExclusive,
    this.nestedExclusive,
  });

  final String? transport;
  final _TlsMode tlsMode;

  /// Единственное взаимоисключающее поле TLS, которое это тело несёт.
  final String? tlsExclusive;

  /// Поле КОРНЯ тела, ради которого снимаются его соперники по `conflicts`.
  final String? rootExclusive;

  /// Вложенное поле, ради которого снимаются его соперники по объекту.
  final String? nestedExclusive;

  /// Соперники [nestedExclusive] — имена соседей из его `conflicts`.
  late final Set<String> rivalsOfNested = _nestedRivals();

  Set<String> _nestedRivals() {
    final path = nestedExclusive;
    if (path == null) return const {};
    final t = path.split('.');
    if (t.length < 2) return const {};
    final variant = ContractRegistry.I.transportVariant(t[1]);
    if (variant == null) return const {};
    Map<String, FieldSchema>? fields = variant.fields;
    FieldSchema? f;
    for (final seg in t.skip(2)) {
      f = fields?[seg];
      fields = f?.fields;
    }
    return {
      for (final r in f?.conflicts ?? const <Map<String, dynamic>>[])
        if (r['with'] is String) (r['with'] as String).split('.').last,
    };
  }

  /// Соперники [rootExclusive] по `conflicts` — считаются один раз на тело.
  late final Set<String> rivalsOfRootExclusive = _rivals();

  Set<String> _rivals() {
    final key = rootExclusive;
    if (key == null) return const {};
    final out = <String>{};
    for (final scheme in _searchSchemes) {
      final s = ContractRegistry.I.schemaFor(scheme);
      final f = s?.fields[key];
      if (f == null) continue;
      for (final r in f.conflicts) {
        final w = r['with'];
        if (w is String && !w.contains('.')) out.add(w);
      }
    }
    return out;
  }

  /// Ось 4: значение, которое в ЭТОМ теле принимает поле-дискриминатор
  /// (`obfs.type`), и зависимые от него поля живут по нему.
  final MapEntry<String, Object?>? equalsOverride;

  final covered = <String>{};

  /// Значение дискриминатора в этом теле: заданное осью либо то, что
  /// генератор положит по умолчанию (первое годное из `values`).
  Object? equalsValueFor(String target) {
    final o = equalsOverride;
    if (o != null && o.key == target) return o.value;
    return _defaultEnumValue(target);
  }

  /// Значение, которое ось навязала конкретному полю.
  Object? equalsForcedValue(String path) {
    final o = equalsOverride;
    if (o == null) return null;
    // Путь `equals` записан от корня тела (`obfs.type`), а поле строится по
    // тому же пути — сравнение прямое.
    return o.key == path ? o.value : null;
  }

  /// Первое годное значение enum'а по пути — то же правило, что у генератора.
  Object? _defaultEnumValue(String target) {
    final parts = target.split('.');
    // Ищем схему поля от корня протокола. Глубже двух уровней `equals` в
    // реестре сегодня не уходит.
    return _enumCache.putIfAbsent(target, () {
      FieldSchema? f;
      Map<String, FieldSchema>? fields;
      for (final scheme in _searchSchemes) {
        final s = ContractRegistry.I.schemaFor(scheme);
        if (s == null) continue;
        fields = s.fields;
        f = null;
        for (final seg in parts) {
          final cur = fields?[seg];
          if (cur == null) {
            f = null;
            break;
          }
          f = cur;
          fields = cur.fields;
        }
        if (f != null) break;
      }
      final values = f?.values;
      if (values == null) return null;
      for (final v in values) {
        if (v == null) continue;
        if (v is String && v.isEmpty) continue;
        return v;
      }
      return null;
    });
  }

  static final _enumCache = <String, Object?>{};

  /// Схемы, среди которых ищется поле `equals`-правила. Правило лежит внутри
  /// того же протокола, чьё тело строится, но контекст его имени не знает —
  /// перебор по всем дешевле передачи имени сквозь рекурсию.
  static const _searchSchemes = <String>[
    'hysteria2',
    'hysteria',
    'vless',
    'vmess',
    'trojan',
    'tuic',
    'anytls',
    'shadowsocks',
    'naive',
    'socks',
    'http',
    'ssh',
    'wireguard',
    'masque',
    'tailscale',
  ];
}
