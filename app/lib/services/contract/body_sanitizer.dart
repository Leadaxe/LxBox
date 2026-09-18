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
import '../app_log.dart';
import '../parser/uri_utils.dart'
    show decodeBase64Safe, normalizeSingboxDuration, urlPathOk;
import 'registry.dart';

/// §473 — вход, которым тело приехало в приложение.
///
/// Единственное место контракта, где вход влияет на РЕЗУЛЬТАТ, а не только на
/// разбор: `max_when.except_sources` (контракт 1.1.5, решение владельца
/// 18.09.2026). Основание не техническое, а по владению — тело sing-box
/// человек или подписка написали в собственной форме ядра, и молча
/// переписывать его приложение не вправе; значение из ссылки или `.conf`
/// сочинял генератор провайдера.
///
/// Перечисление намеренно НЕ повторяет словарь `sources` реестра целиком
/// (`uri`/`singbox`/`xray`/`wgconf`/`amnezia`): различать вход тоньше нам
/// нечем и незачем — правило одно, и делит оно ровно надвое. Появится второе
/// правило с другим делением — перечисление расширится по нему, а не заранее.
enum BodySource {
  /// Тело в собственной форме ядра: объект `outbounds[]`/`endpoints[]`,
  /// пришедший JSON-ом (`origin.kind: json`, §455) либо дословная карта
  /// провайдера при разборе JSON-подписки.
  singbox('singbox'),

  /// Всё остальное: ссылка, INI (`.conf`), `amnezia://`, форма редактора —
  /// тело собрал наш разбор, а не автор узла.
  other('');

  const BodySource(this.registryName);

  /// Имя входа в словаре `sources` реестра; у [other] пустое — под
  /// `except_sources` оно не подпадает ни при каком списке.
  final String registryName;
}

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

/// §469 — предел длины `value` предупреждения в рунах (CANON §6,
/// `WarningValueMax` контракта).
const _kWarningValueMax = 64;

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
  ///
  /// §460 W2a — [applyCoreGates] `false` выключает гейты `min_core` и
  /// `platform`: они зависят от ЗАПУЩЕННОГО ядра, а `entry` узла от него не
  /// зависит (24.1.6). При разборе узла ядра ещё нет (и версия его к моменту
  /// сборки может стать другой), поэтому поле, которое ядро «пока не знает»,
  /// при разборе не снимается и о нём не сообщается — это работа гарда
  /// сборки.
  ///
  /// §473 — [source] нужен ровно одному правилу, `max_when.except_sources`:
  /// на входе [BodySource.singbox] завышенное значение сохраняется и узел
  /// получает info-код вместо замены. Параметр явный и обязательный к
  /// передаче на том пути, где вход известен: глобального состояния у
  /// санитайзера нет и не будет — оно разошлось бы с телом на первом же
  /// параллельном разборе. Дефолт [BodySource.other] — консервативный: он
  /// означает «вход неизвестен», и правило применяется как прежде, заменой.
  static SanitizeResult sanitize(
    Map<String, dynamic> body, {
    required String scheme,
    required String coreVersion,
    String platform = 'android',
    bool applyCoreGates = true,
    BodySource source = BodySource.other,
  }) {
    final schema = ContractRegistry.I.schemaFor(scheme);
    if (schema == null) return SanitizeResult(body, const []);

    final ctx = _Ctx(
      scheme: scheme,
      coreVersion: coreVersion,
      platform: platform,
      applyCoreGates: applyCoreGates,
      source: source,
      root: body,
    );
    final out = ctx.sanitizeObject(body, schema.order, schema.fields, '');
    if (ctx.dropNode) return SanitizeResult(null, ctx.warnings);
    return SanitizeResult(out, ctx.warnings);
  }

  /// Значение для `value` предупреждения: у `secret`-полей — `***`, длинное
  /// обрезается до 64 РУН (24.1.4, CANON §6).
  ///
  /// §469 — форма нормирована КОРПУСОМ, не языком: карта печатается
  /// `map[ключ:значение ключ:значение]` с ключами по возрастанию, список —
  /// `[a b c]`, обрезка — 64 руны плюс `…`. Раньше здесь стоял `toString()`
  /// Dart (`{enabled: true, …}`) и обрезка 61+`...`, и `value` объектных
  /// полей расходился с ожиданиями корпуса (`tls_field_unsupported_naive` на
  /// `tls.utls`, `tls_not_applicable_quic` на QUIC) на одном лишь способе
  /// печати. Своего смысла у формы нет — это канон записи, и держать его надо
  /// одинаковым с обеих сторон.
  ///
  /// Публичный, потому что у `value` появился второй производитель: коды,
  /// которые при разборе ставит парсер, а не санитайзер
  /// (`forbiddenTlsBlockWarnings`, `parse_warnings.dart`).
  static String renderWarningValue(Object value, {bool secret = false}) {
    if (secret) return '***';
    return _truncateWarningValue(_renderWarningScalar(value));
  }
}

/// Печать значения по канону корпуса (см. [RegistrySanitizer.renderWarningValue]).
String _renderWarningScalar(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return 'map[${[
      for (final k in keys) '$k:${_renderWarningScalar(value[k])}',
    ].join(' ')}]';
  }
  if (value is List) {
    return '[${[for (final e in value) _renderWarningScalar(e)].join(' ')}]';
  }
  return value is String ? value : '$value';
}

/// Обрезка до [_kWarningValueMax] РУН (не кодовых единиц: значение вправе
/// нести не-ASCII) с многоточием-символом — зеркало `TruncateWarningValue`
/// контракта.
String _truncateWarningValue(String s) {
  final runes = s.runes.toList(growable: false);
  if (runes.length <= _kWarningValueMax) return s;
  return '${String.fromCharCodes(runes.take(_kWarningValueMax))}…';
}

/// Состояние одного прогона: накопитель warnings, флаг `drop_node` и корень
/// тела — связи (`conflicts`/`requires`) адресуются путями от корня
/// (`tls.reality.public_key`), а не от текущего объекта.
final class _Ctx {
  _Ctx({
    required this.scheme,
    required this.coreVersion,
    required this.platform,
    required this.applyCoreGates,
    required this.source,
    required this.root,
  });

  final String scheme;
  final String coreVersion;
  final String platform;

  /// §473 — вход тела; читает его только `max_when.except_sources`.
  final BodySource source;

  /// §460 W2a — считать ли гейты, зависящие от запущенного ядра
  /// (`min_core`, `platform`). При разборе — нет (24.1.6).
  final bool applyCoreGates;
  final Map<String, dynamic> root;

  final warnings = <RegistryWarning>[];
  bool dropNode = false;

  /// §472 шаг 5 — снят ВЛОЖЕННЫЙ объект, а не узел: у него не хватило поля,
  /// объявленного `required` внутри него самого.
  ///
  /// Флаг живёт ровно один вызов `_sanitizeObjectField`: тот ставит его в
  /// `false` перед спуском и читает сразу после. Отдельный от [dropNode] он
  /// потому, что и отказ другой: узел остаётся, пропадает одна его секция
  /// (`hysteria2.obfs` без пароля — узел живёт без обфускации).
  bool dropObject = false;

  /// Снимок уже проверенных значений по абсолютному пути от корня тела.
  ///
  /// Связи (`conflicts`/`requires`) адресуются именно так
  /// (`tls.reality.public_key`), и смотреть им надо на состояние ПОСЛЕ
  /// проверки: поле, снятое как невалидное, зависимые обязаны считать
  /// отсутствующим — иначе `short_id` пережил бы мусорный `public_key`.
  final sanitized = <String, Object?>{};

  /// §472 шаг 3 — пути, СНЯТЫЕ этим же прогоном с объяснением.
  ///
  /// Зависимое поле (`requires`) уходит вслед за тем, чего ему не хватает, и
  /// второго сообщения это не заслуживает: человек уже прочёл, ПОЧЕМУ ушёл
  /// `tls.reality.public_key`, а «`short_id` требует `public_key`» добавляет
  /// к этому только шум. Корпус нормирует ровно так: у
  /// `vless/reality_pbk_junk_degrade`, `tls_pbk_junk_enabled` и
  /// `reality_key_share_without_pbk_ignored` в ожидании ОДИН код —
  /// `reality_pbk_invalid`, а комментарий последнего говорит прямо: «снят не
  /// он, а весь блок, поэтому кода `reality_key_share_invalid` НЕТ».
  ///
  /// Поле, которого в теле НЕ БЫЛО вовсе, сюда не попадает: там `requires`
  /// — единственное объяснение, и код нужен (корпус
  /// `hysteria2/salamander_ignores_gecko_sizes`).
  final explainedDrops = <String>{};

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
      value: value == null
          ? null
          : RegistrySanitizer.renderWarningValue(value, secret: secret),
      params: params,
    ));
  }

  /// §472 шаг 5 — параметры кода, объявленного у `required`-поля.
  ///
  /// Текст такого кода говорит о БЛОКЕ, и назвать блок он может только
  /// соседним полем: `obfs_password_missing` печатает `{type}` — какую именно
  /// обфускацию сняли. Значение берётся из ИСХОДНОГО объекта: к этому моменту
  /// разбор до соседа мог и не дойти, а в теле он уже лежит.
  ///
  /// Соседа нет или он не строка — параметра нет вовсе: подстановка `{type}`
  /// останется видна в тексте, и это честнее выдуманного значения.
  Map<String, String> _requiredParams(Map<String, dynamic> src) {
    final type = src['type'];
    return type is String && type.isNotEmpty ? {'type': type} : const {};
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
    //
    // §470 — `value` ставится и здесь: конверт корпуса называет его у
    // `unknown_key` (`manual_object_junk`), и лаунчер печатает снятое
    // значение (`nodeflow/sanitize.go` → `s.warn("unknown_key", path,
    // src[name], …)`). Без него человек видел «ключ снят» и не знал, ЧТО
    // именно снято, а раннер тел молча расходился с контрактом на одном
    // недостающем поле. `secret` тут неоткуда взять: ключа в схеме нет, а
    // значит нет и его флага — печатаем как есть, ровно как вторая сторона.
    for (final key in src.keys) {
      if (fields.containsKey(key)) continue;
      if (prefix.isEmpty && _kBuildManagedKeys.contains(key)) continue;
      warn('unknown_key', path: _join(prefix, key), value: src[key]);
    }

    // 2. Значения — по одному, в порядке схемы: и результат, и список
    // warnings становятся детерминированными.
    final kept = <String, Object?>{};
    for (final key in order) {
      final f = fields[key];
      if (f == null) continue;
      if (!src.containsKey(key)) {
        // §464 (W2d) — `default_when`: дефолт, без которого ядро не поднимает
        // outbound вовсе (полоса hysteria v1 — «missing upload speed» фаталом
        // на ВЕСЬ конфиг). В отличие от `default` (CANON §2.4 — не пишется),
        // такой дефолт материализуется явно, и кода на него нет: узел жив и в
        // порядке.
        //
        // §473 (контракт 1.1.5) — у `default_when` появилось условие `when`:
        // дефолт, зависящий от РОДА узла. `mtu: 1280` дописывается только
        // AmneziaWG-узлу; обычный WireGuard поля не получает вовсе — ядро
        // берёт свой 1408, и наш дефолт спорил бы с ним и ломал identity-хеш
        // (CANON §2.4).
        final dw = f.defaultWhen;
        if (dw != null &&
            dw['absent'] == true &&
            _conditionHolds(dw['when'], src)) {
          kept[key] = dw['value'];
          final code = dw['code'] as String?;
          if (code != null) warn(code, path: _join(prefix, key));
          continue;
        }
        // `required` без поля — запись уходит целиком (24.1.7): ядро такую
        // не принимает и роняет весь конфиг.
        //
        // §472 шаг 5 — но только на КОРНЕ тела. Внутри вложенного объекта
        // единица отказа — сам объект, а не узел: реестр пишет это прямо у
        // `hysteria2.obfs.password` («отсутствие пароля снимает блок obfs
        // целиком, узел живёт без обфускации»), и корпус ждёт того же
        // (`uri/hysteria2/obfs_no_password_dropped` — узел с телом и одним
        // кодом `obfs_password_missing`). Прежний код ронял такой узел
        // ЦЕЛИКОМ; заметить это было нечем, пока obfs собирал рукописный
        // `normalizeHysteria2Obfs` до санитайзера, а в корпусе тел кейса без
        // пароля нет вовсе.
        //
        // Путь кода при этом не теряется: он стоит в `params.field`, как и
        // прежде, — форма записи у `field_missing` такая (адреса у
        // отсутствующего поля нет, есть имя).
        //
        // Форма записи у двух кодов разная, и разводит их сам реестр. Общий
        // `field_missing` — про УЗЕЛ («узел отброшен»), адреса у него нет, имя
        // поля лежит в `params.field`. Код, объявленный у поля через `code`, —
        // про БЛОК (`obfs_password_missing`: «весь блок обфускации снят, узел
        // подключается без обфускации»), и он адресуется полем: ожидание
        // корпуса называет `path: obfs.password`, а `params` у него свои
        // (`type` — какую обфускацию сняли).
        if (f.required) {
          final own = f.code;
          if (own == null) {
            warn('field_missing', params: {'field': _join(prefix, key)});
          } else {
            warn(own, path: _join(prefix, key), params: _requiredParams(src));
          }
          if (prefix.isEmpty) {
            dropNode = true;
          } else {
            dropObject = true;
            return out;
          }
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
    // на соседей, `conflicts` снимает декларанта (§474).
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

  /// Гейты уровня поля: годность значения они не проверяют, но само значение
  /// им нужно — контракт требует его в `value` предупреждения (CANON §6:
  /// «исходное значение до деградации»). `true` — поле снято.
  bool _gated(FieldSchema f, String path, Object? value) {
    // `forbidden_for` / `allowed_for` — по схеме записи. Код обязателен по
    // схеме реестра; если его всё же нет, код типа лучше молчания.
    //
    // §469 (контракт 1.1.4) — код берётся через `forbidden_codes`: один и тот
    // же запрет у разных схем даёт разный исход, и словарь «схема → код» это
    // выражает (`tls.utls` на naive — потерянная настройка, на QUIC —
    // снятая бессмыслица).
    //
    // Значение снятого блока идёт в `value` предупреждения: контракт зовёт
    // его «исходным значением до деградации» (CANON §6), и для объекта это
    // сам объект. Секрета в `utls`/`reality` нет, `secret` у полей стоит
    // точечно и проверяется тем же `f.secret`.
    final forbidden = f.forbiddenFor;
    if (forbidden != null && forbidden.contains(scheme)) {
      warn(f.forbiddenCodeFor(scheme) ?? _kDefaultInvalidCode,
          path: path, value: value, secret: f.secret);
      return true;
    }
    final allowed = f.allowedFor;
    if (allowed != null && !allowed.contains(scheme)) {
      warn(f.code ?? _kDefaultInvalidCode,
          path: path, value: value, secret: f.secret);
      return true;
    }
    // `min_core` — гейт СБОРКИ (24.1.6): ключ, неизвестный запущенному ядру,
    // эмиттер опускает. Кода нет намеренно — узел жив и в порядке, причина
    // уходит в лог сборки, а не в ⚠ пользователю.
    if (!applyCoreGates) return false;
    final minCore = f.minCore;
    if (minCore != null && !coreAtLeast(coreVersion, minCore)) return true;
    // `platform` — то же самое: kTLS вне Linux валит весь конфиг.
    final plat = f.platform;
    if (plat != null && plat != platform) return true;
    return false;
  }

  _Value _sanitizeValue(Object? value, FieldSchema f, String path) {
    if (_gated(f, path, value)) return const _Value.drop();

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
    // §472 шаг 5 — та же граница, что у объекта: не хватило `required` внутри
    // общей суб-схемы — снимается она, а не узел. Сегодня таких полей в
    // `tls`/`multiplex`/`dialer` нет ни одного на верхнем уровне (все четыре
    // лежат глубже, во вложенных объектах), но правило должно быть одно на
    // оба спуска — иначе оно зависело бы от того, описано поле ссылкой или
    // объектом.
    dropObject = false;
    final cleaned = sanitizeObject(
        value.cast<String, dynamic>(), shared.order, shared.fields, path);
    if (dropObject) {
      dropObject = false;
      return const _Value.drop();
    }
    return _Value.keep(cleaned);
  }

  _Value _sanitizeObjectField(Object? value, FieldSchema f, String path) {
    if (value is! Map) return _invalid(f, path, value);
    final map = value.cast<String, dynamic>();
    final fields = f.fields;
    // Объект без `fields` — свободная карта (`transport.headers`): состав
    // задаёт не реестр, внутрь санитайзер не смотрит.
    if (fields == null) return _Value.keep(map);

    // §472 шаг 5 — объект, которому не хватило собственного `required`-поля,
    // снимается целиком, а узел живёт. Флаг гасится ПЕРЕД спуском: он
    // относится к этому объекту, а не к соседу, разобранному раньше.
    dropObject = false;
    final cleaned = sanitizeObject(map, f.order ?? const [], fields, path);
    if (dropNode) return const _Value.drop();
    if (dropObject) {
      dropObject = false;
      return const _Value.drop();
    }

    // §467 — `all_or_nothing` НЕ влечёт действия санитайзера.
    //
    // Атрибут читался наоборот: считалось, что частичный объект надо
    // дополнить дефолтами соседей. Ядро при частично заданной секции
    // оставляет незаданные поля НУЛЯМИ (= без лимита), поэтому дописывание
    // навязывало узлу лимиты, которых у него не было: у 13 живых узлов
    // vless+xhttp одной подписки лаунчера так испортился рабочий `xmux`
    // (контракт §24.9). Атрибут остаётся в реестре документацией о поведении
    // ядра, частичный объект проходит как есть. Код `partial_object_defaulted`
    // снят из `warnings.json` вместе с этим правилом.
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
      v = _normalizeString(v, norm);
    }
    // `listable_string` нормализуется поэлементно.
    if (norm != null && v is List) {
      v = [
        for (final e in v)
          if (e is String) _normalizeString(e, norm) else e,
      ];
    }

    // §464 (W2d) — `normalize_code`: нормализация, которая ЗАБРАЛА часть
    // значения, обязана объявить потерю. `0x1a2` → `01a2` — другой short_id,
    // и молчать о нём нельзя ни на одном из входов (DRIFT §2(b)).
    //
    // Код ставится на исходном значении: человеку нужно видеть, что он
    // написал, а не что из этого осталось.
    //
    // §472 шаг 3 — сравнение идёт с `lower(trim(исходного))`, а не с самим
    // исходным. Регистр и обрамляющие пробелы не ЗАБИРАЮТ ничего: `sid=ABCD`
    // и `sid=abcd` — один и тот же идентификатор, и корпус на нём кода не
    // ждёт (`vless/reality_valid_pbk_sid` — `warnings` нет вовсе), тогда как
    // `0x1a2` и `48 ab12` его ждут. Эталон Go ровно такой же —
    // `realityShortIDWouldDegrade` сверяет с `strings.ToLower(TrimSpace(raw))`
    // (зеркало в Dart: `realityShortIdWouldDegrade`, `uri_utils.dart`).
    // Расхождение было латентным: до конвейера `hex_only` встречался только на
    // JSON-входе, где написанного заглавными `sid` в корпусе нет.
    final normCode = f.normalizeCode;
    if (normCode != null && v != _foldForNormalizeCode(coerced.value)) {
      warn(normCode, path: path, value: coerced.value, secret: f.secret);
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

    // §473 (контракт 1.1.5) — `max_when`: УСЛОВНЫЙ потолок. В отличие от
    // `max`, нарушение которого делает значение негодным (`on_invalid` →
    // поле снимается), здесь значение законно — потолок диктует род узла, и
    // исход правила зависит от того, КТО тело написал.
    v = _applyMaxWhen(v, f, path);

    // `advisory` — ядро значение принимает, но узел получает info-код.
    // Поле НЕ меняется.
    //
    // Две формы отбора (§464, W2d):
    //   `values` — перечислено, на чём код ставится (ss legacy-шифры);
    //   `except` — перечислено, на чём НЕ ставится (reality_fp_not_chrome:
    //   отпечатков у ядра три десятка, а гибридный шар есть у девяти).
    // `when` — дополнительное условие по другому полю тела: код про REALITY
    // не имеет смысла на узле без REALITY.
    //
    // §474 (контракт 1.1.6) — `values` принимает и BOOLEAN: `tls.insecure:
    // true` даёт info-код `tls_insecure`, значение сохраняется. Отбор именно
    // по значению, а не `except`: у bool «не задано» и `false` неразличимы, и
    // код обязан стоять ровно на `true`. Сравнение `vals.contains(v)` работает
    // на bool как есть — отдельной ветки тип не требует.
    for (final a in f.advisory) {
      final code = a['code'] as String?;
      if (code == null) continue;
      final vals = (a['values'] as List?)?.cast<Object?>();
      final except = (a['except'] as List?)?.cast<Object?>();
      if (vals != null && !vals.contains(v)) continue;
      // Пустое значение под `except` не попадает по определению: «не задано»
      // — не выбор автора ссылки (tls.json, impl у fingerprint).
      if (except != null && (except.contains(v) || v == null || v == '')) {
        continue;
      }
      if (!_advisoryWhen(a['when'])) continue;
      warn(code,
          path: path,
          value: v,
          secret: f.secret,
          params: _advisoryParams(code, v));
    }

    return _Value.keep(v);
  }

  /// §474 — подстановки advisory-кода ПО ЕГО ОБЪЯВЛЕНИЮ в `warnings.json`.
  ///
  /// `path` и `value` подставляются всегда (`text_params_implicit`) и сюда не
  /// попадают — их несут одноимённые поля warning'а. Остаётся то, что код
  /// объявил сам, и единственная осмысленная подстановка для правила значения
  /// — само значение: `ss_method_legacy` зовёт его `{method}`.
  ///
  /// Раньше `{method}` ставился безусловно. Коду, который его не объявлял,
  /// лишний параметр не мешал, но и не помогал: `tls_insecure` объявляет
  /// `path` и `value`, и заполняются они сами. Явный разбор нужен, чтобы
  /// новый advisory-код со своим именем параметра не потребовал правки здесь
  /// — тест рендера всех кодов реестра поймает незаполненный `{…}` сразу.
  Map<String, String> _advisoryParams(String code, Object? v) {
    final declared = ContractRegistry.I.textFor(code)?.params ?? const [];
    final text = v is String ? v : '$v';
    return {
      for (final p in declared)
        if (p != 'path' && p != 'value') p: text,
    };
  }

  /// §473 — условный потолок `max_when`. Возвращает значение, которое
  /// остаётся в теле: заменённое потолком либо исходное.
  ///
  /// Три исхода, и путать их нельзя:
  ///
  /// 1. условие `when` не выполнено (узел не того рода) — правила нет вовсе;
  /// 2. выполнено, вход НЕ в `except_sources` — значение заменяется потолком,
  ///    код `code` (severity warning);
  /// 3. выполнено, вход В `except_sources` — значение остаётся, код
  ///    `note_code` (severity info).
  ///
  /// Исход 3 — единственное место контракта, где вход узла влияет на
  /// результат (решение владельца 18.09.2026): тело в форме ядра человек или
  /// подписка написали сами, и молча переписывать его нельзя.
  ///
  /// Условие читается по ИСХОДНОМУ телу объекта ([root] через [_anySetInBody]),
  /// а не по уже очищенному: род узла задаёт то, что автор написал. Битый
  /// `jc`, снятый парой строк выше, AmneziaWG-узел AmneziaWG-узлом быть не
  /// перестаёт (§463 — то же основание у рукописного `isAwg`).
  Object? _applyMaxWhen(Object? v, FieldSchema f, String path) {
    final rule = f.maxWhen;
    if (rule == null) return v;
    final ceiling = rule['max'];
    if (v is! num || ceiling is! num) return v;
    if (v <= ceiling) return v;
    if (!_conditionHolds(rule['when'], root)) return v;

    final except = (rule['except_sources'] as List?)?.map((e) => '$e');
    if (except != null && except.contains(source.registryName)) {
      final note = rule['note_code'] as String?;
      // `note_code` обязателен по схеме при `except_sources`; без него
      // молчание лучше выдуманного кода — значение всё равно сохраняется.
      if (note != null) warn(note, path: path, value: v, secret: f.secret);
      return v;
    }

    final code = rule['code'] as String?;
    // Код на ИСХОДНОМ значении: человеку нужно видеть, что он написал.
    if (code != null) warn(code, path: path, value: v, secret: f.secret);
    return ceiling;
  }

  /// §473 — условие правила значения (`default_when.when`, `max_when.when`).
  ///
  /// Форма реестра одна: `{any_set: [ключ, …]}`. Пустое/отсутствующее условие
  /// — правило безусловно.
  ///
  /// [body] — объект, в котором ищутся ключи. Незнакомую форму условия читаем
  /// как «не выполнено»: правило значения, чьё условие непонятно, применять
  /// наугад нельзя (в отличие от незнакомого `normalize`, который просто
  /// ничего не делает).
  bool _conditionHolds(Object? when, Map<String, dynamic> body) {
    if (when == null) return true;
    if (when is! Map) return true;
    final anySet = (when['any_set'] as List?)?.map((e) => '$e');
    if (anySet != null) return _anySetInBody(anySet, body);
    _logUnknownExpression('when', when.keys.join(','));
    return false;
  }

  /// §473 — предикат «КЛЮЧ ПРИСУТСТВУЕТ», и только он.
  ///
  /// **Не путать с [_meaningful]** — предикатом «ЗНАЧЕНИЕ ЗАДАНО», по которому
  /// судят `conflicts`/`requires` (§467). Разница не стилистическая: `jc: 0`
  /// — законная запись «мусорные пакеты выключены» у настоящего
  /// AmneziaWG-узла (кейс корпуса `awg_jc_zero_explicit`, наш
  /// `awg_test.dart`). Прочитай условие рода узла через [_meaningful], с
  /// такого узла потолок MTU снялся бы, и туннель молча не понёс бы данные.
  ///
  /// Обратное смешение так же вредно: `max_concurrency: "16-32"` при
  /// `max_connections: "0"` — не конфликт, и там судить надо значение.
  ///
  /// Пути условия — ключи корня тела (реестр называет их так же, как
  /// `conflicts`/`requires`): вложенных условий у `any_set` сегодня нет, и
  /// выдумывать их разбор здесь нечего — сегмент с точкой просто не найдётся.
  static bool _anySetInBody(Iterable<String> keys, Map<String, dynamic> body) {
    for (final key in keys) {
      if (body.containsKey(key)) return true;
    }
    return false;
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
        // §472 шаг 3 — поле снято и причина названа: зависимым от него
        // второго кода не полагается. См. [explainedDrops].
        explainedDrops.add(path);
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
    // `conflicts`: снимается ДЕКЛАРАНТ — поле, у которого правило записано.
    //
    // §474 (контракт 1.1.6). Раньше здесь снималось «младшее по `order`», и
    // это было ошибкой прочтения: формулировка описывала типичный случай, а
    // не контракт. Уступает всегда сторона-декларант, а соседа видно и в
    // ИСХОДНОМ теле — потому правило работает и тогда, когда сосед стоит по
    // `body.order` позже. Ровно так судит лаунчер
    // (`nodeflow/sanitize.go` → `relationsOK`), и по всем 22 записям реестра
    // противоположная сторона не нужна ни разу.
    //
    // Разница видна на `vless.flow ↔ transport`: `flow` (order 3) идёт раньше
    // `transport` (order 9), и прежнее «младшее» оставляло оба поля — из-за
    // чего гашение vision жило рукописным правилом в маппере. Симметричные
    // пары (`tls.ech.enabled` ↔ `tls.reality.enabled`) записаны у ОБОИХ
    // участников, и снятие декларанта их не ломает: первый по обходу уходит
    // сам, второй перестаёт видеть соседа и остаётся.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      final myPath = _join(prefix, key);
      for (final rel in f.conflicts) {
        final with0 = rel['with'] as String?;
        if (with0 == null) continue;
        if (!_presentInSource(with0, kept, prefix)) continue;
        kept.remove(key);
        warn(rel['code'] as String? ?? 'field_conflict',
            path: myPath, params: {'with': with0});
        // §474 — поле снято и причина названа: зависимым от него второго кода
        // не полагается (та же граница, что у `requires`).
        explainedDrops.add(myPath);
        break;
      }
    }

    // `requires`: нет требуемого — поле снимается, само по себе не влияет.
    //
    // §464 (W2d) — `equals`: требуется не наличие соседа, а его КОНКРЕТНОЕ
    // значение (`obfs.min_packet_size` осмыслен только при
    // `obfs.type = gecko`). Без этого поле gecko переживало salamander и
    // расходилось с тем же узлом, пришедшим другим входом.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      for (final rel in f.requires) {
        final need = rel['path'] as String?;
        if (need == null) continue;
        final ok = rel.containsKey('equals')
            ? _valueAt(need, kept, prefix) == rel['equals']
            : _present(need, kept, prefix);
        if (ok) continue;
        kept.remove(key);
        // §472 шаг 3 — требуемое поле снял этот же прогон и уже объяснил
        // почему: молча уходим следом. См. [explainedDrops].
        if (!explainedDrops.contains(need)) {
          warn(rel['code'] as String? ?? 'field_requires',
              path: _join(prefix, key), params: {'requires': need});
        }
        break;
      }
    }
  }

  /// Значение по пути связи — для `requires` с `equals`.
  ///
  /// Пути `equals`-правил реестра записаны от корня тела (`obfs.type`), но
  /// само правило лежит внутри того же объекта (`obfs.min_packet_size`), так
  /// что сосед по последнему сегменту находится раньше снимка: он проверен в
  /// этом же проходе и в `kept` уже есть.
  Object? _valueAt(String path, Map<String, Object?> siblings, String prefix) {
    final last = path.split('.').last;
    if (siblings.containsKey(last)) return siblings[last];
    if (sanitized.containsKey(path)) return sanitized[path];
    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map || !cur.containsKey(seg)) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Условие `when` у `advisory`: `{path, present: true}` — правило работает
  /// только когда поле по пути задано и осмысленно.
  bool _advisoryWhen(Object? when) {
    if (when == null) return true;
    if (when is! Map) return true;
    final path = when['path'] as String?;
    if (path == null) return true;
    final present = _present(path, const {}, '');
    return when['present'] == false ? !present : present;
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

  /// §474 — сосед для `conflicts`: виден и в ИСХОДНОМ теле.
  ///
  /// Отличие от [_present] ровно одно и оно намеренное. `requires` судит
  /// состояние ПОСЛЕ санитайзинга: поле, снятое как негодное, для зависимых
  /// от него отсутствует — иначе `short_id` пережил бы мусорный `public_key`.
  /// `conflicts` судит иначе: он отвечает на вопрос «что автор написал в
  /// теле», и ответ не зависит от того, дошёл ли обход до соседа. `flow`
  /// (order 3) обязан увидеть `transport` (order 9), которого в снимке ещё
  /// нет вовсе; лаунчерский `pathPresent` читает `srcRoot` по той же
  /// причине.
  ///
  /// Снятое санитайзером поле соседом всё же не считается ([explainedDrops] и
  /// снимок проверяются первыми): конфликтовать с тем, чего в теле уже не
  /// будет, нечему.
  bool _presentInSource(String path, Map<String, Object?> siblings, String prefix) {
    if (!path.contains('.')) {
      // Сосед по тому же объекту: обход идёт по `order`, и поле, стоящее
      // позже, в `siblings` ещё не лежит — читаем исходную карту объекта.
      if (siblings.containsKey(path)) return _meaningful(siblings[path]);
      final abs = _join(prefix, path);
      if (explainedDrops.contains(abs)) return false;
      if (sanitized.containsKey(abs)) return _meaningful(sanitized[abs]);
      return _meaningful(_rawAt(abs));
    }
    if (explainedDrops.contains(path)) return false;
    if (sanitized.containsKey(path)) return _meaningful(sanitized[path]);
    final parent = path.substring(0, path.lastIndexOf('.'));
    // Ветку уже разобрали, а ключа в снимке нет — поле снято проверкой
    // значения, и для конфликта его нет.
    if (sanitized.containsKey(parent) || _branchDone(parent)) return false;
    return _meaningful(_rawAt(path));
  }

  /// Значение по абсолютному пути в ИСХОДНОМ теле; `null` — пути нет.
  Object? _rawAt(String path) {
    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map || !cur.containsKey(seg)) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Разобрана ли уже ветка [prefix] — есть ли в снимке хоть один её ключ.
  bool _branchDone(String prefix) =>
      sanitized.keys.any((k) => k.startsWith('$prefix.'));

  /// Предикат «задано» — ОДИН на весь слой связей (`conflicts`, `requires`,
  /// `forbidden_when`); §467, контракт §24.9.
  ///
  /// Судится ЗНАЧЕНИЕ, а не наличие ключа. Не задано: ключ отсутствует,
  /// `null`, `""`, `0`, `false`, пустой объект, пустой массив и строка-число
  /// из одних нулей (`"0"`, `"0-0"` — диапазоны `XmuxRange` приходят
  /// строками).
  ///
  /// Провайдеры присылают секции в полной форме, где незаданные поля выписаны
  /// нулями. По наличию ключа `max_concurrency: "16-32"` при
  /// `max_connections: "0"` читался как конфликт, рабочее значение снималось и
  /// возвращалось дефолтом `"1-1"` — пропускная способность узла падала молча
  /// (13 узлов на реальном state лаунчера). Ядро
  /// (`transport/v2rayxhttp/xmux.go`) считает конфликтом только оба > 0.
  /// Правило общее: так же судятся `certificate` ↔ `pins` и `reality` ↔ `ech`.
  static bool _meaningful(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty && !_allZeroNumeric(v);
    if (v is Iterable) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  /// Строка-число из одних нулей: `"0"`, `"0-0"`, `"00"`. Форма «N-M» —
  /// `XmuxRange`: диапазон из нулей это тот же ноль, то есть «не задано».
  /// Строка с непустой цифрой (`"0-32"`) задана.
  static bool _allZeroNumeric(String s) {
    var sawDigit = false;
    for (final unit in s.codeUnits) {
      if (unit == 0x30) {
        sawDigit = true;
        continue;
      }
      // Разделитель диапазона и пробелы игнорируем, любой другой символ
      // (в т.ч. цифра 1..9 и буква) делает строку заданной.
      if (unit == 0x2D || unit == 0x20) continue;
      return false;
    }
    return sawDigit;
  }

}

String _join(String prefix, String key) => prefix.isEmpty ? key : '$prefix.$key';

/// Нормализации реестра (`normalize`). Неизвестная — значение НЕ трогается:
/// выражение из будущей версии контракта не повод портить рабочее поле.
String _normalizeString(String v, String norm) {
  switch (norm) {
    case 'trim':
      return v.trim();
    case 'lower':
      return v.toLowerCase();
    case 'trim_lower':
      return v.trim().toLowerCase();
    // §464 (W2d) — `hex_only`: чистка не-hex рун (моджибейк U+00C2, NBSP,
    // пробелы, префикс `0x`) с приведением к нижнему регистру. Правило жило
    // в URI-парсере (§343), теперь одно на все входы.
    case 'hex_only':
      final b = StringBuffer();
      for (final r in v.runes) {
        final c = String.fromCharCode(r);
        if (_reHexRune.hasMatch(c)) b.write(c.toLowerCase());
      }
      return b.toString();
    default:
      _logUnknownExpression('normalize', norm);
      return v;
  }
}

final _reHexRune = RegExp(r'^[0-9a-fA-F]$');

/// §472 шаг 3 — исходное значение в форме, с которой сверяется `normalize_code`.
///
/// Код объявляет ПОТЕРЮ, а регистр и обрамляющие пробелы ничего не теряют.
/// Значения другого типа (число, bool) нормализация строк не трогает — они
/// возвращаются как есть и сравниваются напрямую.
Object? _foldForNormalizeCode(Object? raw) =>
    raw is String ? raw.trim().toLowerCase() : raw;

/// Выражения реестра, о которых санитайзер уже сказал в лог. Один раз на
/// процесс: незнакомое выражение — это бамп контракта впереди кода, и
/// повторять о нём на каждом узле подписки бессмысленно.
final _seenUnknownExpressions = <String>{};

/// Неизвестное выражение реестра не роняет загрузку и не трогает значение
/// (24.1: реестр впереди кода — рабочее состояние, а не ошибка).
void _logUnknownExpression(String kind, String name) {
  if (!_seenUnknownExpressions.add('$kind:$name')) return;
  AppLog.I.warning(
      'RegistrySanitizer: неизвестное выражение реестра $kind=$name — '
      'значение оставлено как есть (контракт новее кода)');
}

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
    // §464 (W2d) — типы, которых словарь SPEC 131 §4 не выражал.
    //
    // `awg_range` — поле AWG, принимающее и число, и диапазон «N-M» строкой
    // (h1..h4, таймеры lx.32). Форма прибытия законна ОБЕ, и подмена одной
    // на другую меняла бы конфиг на ровном месте, поэтому значение идёт как
    // есть; мусор вне этих двух форм снимается.
    case 'awg_range':
      if (value is int) return (value: value);
      if (value is double && value == value.roundToDouble()) {
        return (value: value.toInt());
      }
      if (value is String && _reAwgRange.hasMatch(value.trim())) {
        return (value: value.trim());
      }
      return null;
    // `int_array` — массив целых (`peers[].reserved`: ровно три). Число
    // строкой приводится по общему правилу подписок.
    case 'int_array':
      if (value is! List) return null;
      final out = <int>[];
      for (final e in value) {
        if (e is int) {
          out.add(e);
        } else if (e is double && e == e.roundToDouble()) {
          out.add(e.toInt());
        } else if (e is String && int.tryParse(e.trim()) != null) {
          out.add(int.parse(e.trim()));
        } else {
          return null;
        }
      }
      return (value: out);
    default:
      _logUnknownExpression('type', type);
      return (value: value);
  }
}

/// Форма `awg_range`: голое число либо диапазон «N-M».
final _reAwgRange = RegExp(r'^\d+(-\d+)?$');

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
    // §464 (W2d) — ключ ровно 32 байта ПОСЛЕ декода (REALITY `pbk`, ключи
    // WireGuard). Длина строки не годится: `enabled` — валидный base64 на
    // 5 байт, `true` — на 3, и прежний `base64` их пропускал, после чего
    // ядро отвечало «invalid public_key» фаталом на ВЕСЬ конфиг.
    case 'base64_32':
      return v is String && _base64Bytes(v) == 32;
    case 'host':
      return v is String && v.isNotEmpty && !v.contains(' ');
    case 'ipv4':
      return v is String && _ipv4Ok(v);
    // §463 / контракт §24.6 — новый формат W2c: ядро разбирает путь
    // транспорта через `url.Parse`, и битое percent-кодирование («%zz») роняет
    // ВЕСЬ config.json («ws: parse path: invalid URL escape»), а не один узел.
    case 'url_path':
      return v is String && urlPathOk(v);
    case 'cidr':
      if (v is! String) return false;
      final parts = v.split('/');
      if (parts.length != 2) return false;
      final bits = int.tryParse(parts[1]);
      if (bits == null || bits < 0 || bits > 128) return false;
      return _ipv4Ok(parts[0]) || parts[0].contains(':');
    default:
      _logUnknownExpression('format', format);
      return true;
  }
}

/// Длина ключа в байтах после декода base64 — любое из четырёх написаний
/// (std/url, с паддингом и без). `null` — строка не декодируется вовсе.
///
/// Декодер общий с §169 (`isValidRealityPublicKey`): расходиться в том, что
/// считать валидным base64, двум гардам одного и того же ключа нельзя.
int? _base64Bytes(String v) => decodeBase64Safe(v.trim())?.length;

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
