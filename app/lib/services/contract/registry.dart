/// §460 W1 — реестр контракта в приложении: схема тела узла и тексты кодов.
///
/// Контракт 1.1.0 (`TASKS_LXBOX.md` §24) вынес схему тела 384 полей из
/// структур ядра `1.14.1-lx.4` в `registry/`. Раньше правила «какое поле у
/// какого протокола допустимо» жили рукописными таблицами в Dart по
/// протоколу и расходились с лаунчером и с ядром на каждом пине. Теперь
/// реестр едет в assets, и по нему работает [RegistrySanitizer].
///
/// Слой: сервис без Flutter-зависимостей по существу — `rootBundle` спрятан
/// за [AssetLoader], поэтому юнит-тесты грузят реестр с диска
/// ([ContractRegistry.loadFromDirectory]) и биндинга не требуют.
///
/// Файлы читаются из `assets/contract/` — зеркала вендоренной копии
/// `app/contract/`, которое кладёт `tool/sync_contract.sh`. Зеркало в git
/// (в отличие от копии), потому что сборка без репозитория лаунчера (CI,
/// F-Droid) обязана собираться.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// Чтение файла реестра. Инъекция ради тестов: прод читает `rootBundle`,
/// тест — файловую систему, и сервис остаётся свободен от биндинга.
typedef AssetLoader = Future<String> Function(String path);

/// Схемы-ссылки (`ref`), которые тело узла разворачивает по имени.
const _kSharedRefs = <String, String>{
  'tls': 'tls.json',
  'transports': 'transports.json',
  'multiplex': 'multiplex.json',
  'dialer': 'dialer.json',
  'dialer.common': 'dialer.json',
};

/// Описание поля тела — обёртка над картой реестра.
///
/// Атрибуты не копируются в поля класса: их 30+, читает их санитайзер
/// точечно, и лишний слой конвертации разошёлся бы со схемой на первом же
/// новом атрибуте. Геттеры — только для тех, что нужны санитайзеру.
final class FieldSchema {
  const FieldSchema(this.raw);

  final Map<String, dynamic> raw;

  String get type => raw['type'] as String? ?? 'string';

  String? get ref => raw['ref'] as String?;

  bool get inline => raw['inline'] == true;

  bool get required => raw['required'] == true;

  bool get secret => raw['secret'] == true;

  bool get allOrNothing => raw['all_or_nothing'] == true;

  /// `trim` | `lower` | `trim_lower` | `hex_only` — нормализация ДО
  /// проверки enum/format.
  String? get normalize => raw['normalize'] as String?;

  /// §464 (W2d) — код, который ставится, если [normalize] ИЗМЕНИЛА значение.
  /// Нормализация без него молчалива (`trim_lower` у enum'ов), с ним —
  /// объявляет потерю: `0x1a2` → `01a2` это ДРУГОЙ short_id.
  String? get normalizeCode => raw['normalize_code'] as String?;

  /// §464 (W2d) — дефолт, который ядру НУЖЕН: без поля outbound не
  /// поднимается вовсе (полоса hysteria v1 — «missing upload speed» фаталом
  /// на весь конфиг). В отличие от `default`, материализуется явно.
  ///
  /// Форма реестра: `{"absent": true, "value": 100}`; §473 (контракт 1.1.5)
  /// добавил ей условие `when` — дефолт, зависящий от РОДА узла (1280 у
  /// AmneziaWG, у обычного WireGuard поля нет вовсе).
  Map<String, dynamic>? get defaultWhen =>
      (raw['default_when'] as Map?)?.cast<String, dynamic>();

  /// §473 (контракт 1.1.5) — УСЛОВНЫЙ потолок значения.
  ///
  /// Обычный [max] действует всегда; этот — только когда выполнено `when`.
  /// Нужен там, где потолок диктует не поле, а род узла: у AmneziaWG
  /// накладные расходы на пакет делают `mtu` выше 1280 нерабочим
  /// (рукопожатие проходит, данные не идут), а у обычного WireGuard того же
  /// поля потолка нет — `max: 1280` снял бы `mtu` у каждого plain-WG-узла.
  ///
  /// Форма: `{max, code, when, except_sources?, note_code?}`.
  /// `except_sources` — входы, на которых замены НЕТ: значение остаётся, узел
  /// получает `note_code` (см. [BodySource]).
  Map<String, dynamic>? get maxWhen =>
      (raw['max_when'] as Map?)?.cast<String, dynamic>();

  String? get format => raw['format'] as String?;

  /// Минимальная версия ядра; ниже неё ключ снимается на сборке (24.1.6).
  String? get minCore => raw['min_core'] as String?;

  /// ОС, на которой поле работает; на прочих ключ снимается на сборке.
  String? get platform => raw['platform'] as String?;

  num? get min => raw['min'] as num?;

  num? get max => raw['max'] as num?;

  int? get len => raw['len'] as int?;

  /// `even` | `odd` — требование к чётности длины (reality.short_id).
  String? get lenParity => raw['len_parity'] as String?;

  List<Object?>? get values => (raw['values'] as List?)?.cast<Object?>();

  Map<String, dynamic>? get onInvalid =>
      (raw['on_invalid'] as Map?)?.cast<String, dynamic>();

  List<String>? get forbiddenFor =>
      (raw['forbidden_for'] as List?)?.cast<String>();

  List<String>? get allowedFor => (raw['allowed_for'] as List?)?.cast<String>();

  /// Код для `allowed_for`/`forbidden_for`.
  String? get code => raw['code'] as String?;

  /// §469 (контракт 1.1.4) — словарь «схема → код» поверх общего [code] у
  /// `forbidden_for`. Понадобился ровно потому, что один запрет даёт разный
  /// ИСХОД у разных схем: у naive снятый `tls.utls` это потерянная настройка
  /// (`tls_field_unsupported_naive`, severity warning), а на QUIC-схемах
  /// (hysteria, hysteria2, tuic, masque) uTLS и REALITY не применились бы в
  /// принципе — снята бессмыслица, узел ничего не теряет
  /// (`tls_not_applicable_quic`, severity info).
  ///
  /// Схема без записи в словаре берёт общий [code].
  Map<String, String>? get forbiddenCodes =>
      (raw['forbidden_codes'] as Map?)?.map((k, v) => MapEntry('$k', '$v'));

  /// §469 — код запрета для [scheme]: точечный из [forbiddenCodes], иначе
  /// общий [code]. `null` — кода реестр не назвал.
  String? forbiddenCodeFor(String scheme) =>
      forbiddenCodes?[scheme] ?? code;

  List<Map<String, dynamic>> get conflicts => _relations('conflicts');

  List<Map<String, dynamic>> get requires => _relations('requires');

  /// Значения, которые ядро принимает, но узел получает info-код.
  List<Map<String, dynamic>> get advisory => _relations('advisory');

  List<Map<String, dynamic>> _relations(String key) =>
      ((raw[key] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);

  Object? get defaultValue => raw['default'];

  /// Описание элемента массива (`type: array`).
  FieldSchema? get items {
    final it = raw['items'];
    return it is Map ? FieldSchema(it.cast<String, dynamic>()) : null;
  }

  /// Вложенный объект: порядок + поля. Объект без `fields` (например
  /// `transport.headers`) — свободная карта, внутрь санитайзер не смотрит.
  List<String>? get order => (raw['order'] as List?)?.cast<String>();

  Map<String, FieldSchema>? get fields {
    final f = raw['fields'];
    if (f is! Map) return null;
    return {
      for (final e in f.entries)
        e.key as String: FieldSchema((e.value as Map).cast<String, dynamic>()),
    };
  }
}

/// Схема тела записи: порядок ключей + поля. Порядок нормативен — по нему
/// идут и санитайзер, и эмиттер, поэтому список warnings детерминирован
/// (24.1.1).
final class BodySchema {
  const BodySchema({
    required this.core,
    required this.order,
    required this.fields,
  });

  /// Тег ядра, по которому сверен список полей.
  final String core;

  final List<String> order;

  final Map<String, FieldSchema> fields;
}

/// Текст кода предупреждения из `registry/warnings.json`.
final class WarningText {
  const WarningText({
    required this.code,
    required this.severity,
    required this.titleEn,
    required this.titleRu,
    required this.textEn,
    required this.textRu,
    required this.params,
    this.causeEn,
    this.causeRu,
    this.fixEn = const [],
    this.fixRu = const [],
  });

  final String code;

  /// `info` | `warning` | `error`.
  final String severity;

  final String titleEn;
  final String titleRu;
  final String textEn;
  final String textRu;

  /// §467 — «почему так вышло», одной строкой; контракт 1.1.1. Кода без
  /// причины в реестре быть может, и это норма: блок просто не рисуется
  /// (карточка — W2b, раздел 8 спеки 460).
  final String? causeEn;
  final String? causeRu;

  /// §467 — «что сделать», списком шагов. Пустой список = блока нет.
  final List<String> fixEn;
  final List<String> fixRu;

  /// Имена подстановок помимо неявных `path`/`value`.
  final List<String> params;
}

/// Реестр контракта — синглтон, грузится один раз в `main()` до `runApp`.
///
/// Незагруженный реестр — рабочее состояние, а не ошибка: санитайзер
/// пропускает записи, приложение живёт как до §460.
final class ContractRegistry {
  ContractRegistry._();

  static final ContractRegistry I = ContractRegistry._();

  static const _assetRoot = 'assets/contract';

  String _version = '';
  final Map<String, Map<String, dynamic>> _protocols = {};
  final Map<String, Map<String, dynamic>> _shared = {};
  final Map<String, WarningText> _warnings = {};

  /// Кэш раскрытых схем ([schemaFor]). Слот-обёртка, а не `BodySchema?`:
  /// «схемы нет» — тоже результат, и хранить его надо, иначе чужой тип
  /// (`direct`, `selector`) раскрывался бы заново на каждом узле.
  final Map<String, _SchemaSlot> _schemaCache = {};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Версия контракта из `contract/VERSION` (например `1.1.0`).
  String get version => _version;

  /// Загрузка из assets. [loader] — для тестов; по умолчанию `rootBundle`.
  Future<void> load({AssetLoader? loader}) async {
    final read = loader ?? (String p) => rootBundle.loadString(p);
    await _load((rel) => read('$_assetRoot/$rel'));
  }

  /// Загрузка из каталога на диске — путь к КОРНЮ контракта (`contract`),
  /// где лежат `VERSION` и `registry/`. Для юнит-тестов: биндинг Flutter не
  /// нужен, читается та же копия, которую сверяет `check_contract_lock`.
  Future<void> loadFromDirectory(String dir) async {
    await _load((rel) => File('$dir/$rel').readAsString());
  }

  Future<void> _load(Future<String> Function(String rel) read) async {
    _version = (await read('VERSION')).trim();

    for (final entry in _kSharedRefs.entries) {
      // dialer и dialer.common живут в одном файле — читаем один раз.
      if (_shared.containsKey(entry.value)) continue;
      _shared[entry.value] =
          jsonDecode(await read('registry/${entry.value}')) as Map<String, dynamic>;
    }

    for (final scheme in _kProtocolFiles) {
      final data = jsonDecode(await read('registry/protocols/$scheme.json'))
          as Map<String, dynamic>;
      // Ключ — singbox_type записи, а не имя файла: санитайзер получает
      // `type` из тела узла, и для схем-алиасов (hy2 → hysteria2) имя файла
      // сошлось бы не всегда.
      final singboxType = data['singbox_type'] as String? ?? scheme;
      _protocols[singboxType] = data;
    }

    final warnings = jsonDecode(await read('registry/warnings.json'))
        as Map<String, dynamic>;
    final byCode = (warnings['warnings'] as Map).cast<String, dynamic>();
    // `path`/`value` подставляются всегда (text_params_implicit) — в params
    // кодов они не перечислены.
    final implicit =
        ((warnings['text_params_implicit'] as List?) ?? const []).cast<String>();
    for (final e in byCode.entries) {
      final w = (e.value as Map).cast<String, dynamic>();
      _warnings[e.key] = WarningText(
        code: e.key,
        severity: w['severity'] as String? ?? 'warning',
        titleEn: w['title_en'] as String? ?? '',
        titleRu: w['title_ru'] as String? ?? '',
        textEn: w['text_en'] as String? ?? '',
        textRu: w['text_ru'] as String? ?? '',
        // §467 — контракт 1.1.1: причина строкой, способ исправления списком
        // строк. Отсутствие любого из них — норма (реестр наполняется
        // постепенно), поэтому читаются мягко и загрузку не роняют.
        causeEn: w['cause_en'] as String?,
        causeRu: w['cause_ru'] as String?,
        fixEn: _stringList(w['fix_en']),
        fixRu: _stringList(w['fix_ru']),
        params: [
          ...implicit,
          ...((w['params'] as List?) ?? const []).cast<String>(),
        ],
      );
    }

    // Перезагрузка (тесты грузят реестр не один раз) обязана сбросить кэш
    // раскрытых схем: иначе второй `load()` отдавал бы схемы первого.
    _schemaCache.clear();
    _transportCache.clear();

    _loaded = true;
  }

  /// Схема тела по `type` записи sing-box. Ссылки (`ref`) уже развёрнуты —
  /// кроме `transports`, который разворачивается по дискриминатору
  /// `transport.type` в момент санитайзинга ([transportVariant]).
  ///
  /// `null` — схемы нет (реестр не загружен либо тип чужой): санитайзер
  /// такую запись не трогает.
  /// §460 W2a — результат кэшируется по `singbox_type`: разбор раскрывает
  /// `ref`-ы (tls + dialer + multiplex) на КАЖДЫЙ узел, а на подписке в 2000
  /// узлов это 2000 одинаковых разворотов одной и той же схемы. Реестр
  /// иммутабелен после `load()`, схема из него — тоже, поэтому кэш безопасен.
  BodySchema? schemaFor(String singboxType) {
    final cached = _schemaCache[singboxType];
    if (cached != null) return cached.schema;
    final proto = _protocols[singboxType];
    Map<String, dynamic>? body;
    if (proto != null) body = (proto['body'] as Map?)?.cast<String, dynamic>();
    final schema = body == null ? null : _expand(body);
    _schemaCache[singboxType] = _SchemaSlot(schema);
    return schema;
  }

  /// Вариант транспорта по значению дискриминатора (`transport.type`).
  /// `null` — тип неизвестен реестру.
  BodySchema? transportVariant(String type) {
    final cached = _transportCache[type];
    if (cached != null) return cached.schema;
    final schema = _transportVariant(type);
    _transportCache[type] = _SchemaSlot(schema);
    return schema;
  }

  final Map<String, _SchemaSlot> _transportCache = {};

  BodySchema? _transportVariant(String type) {
    final body =
        (_shared['transports.json']?['body'] as Map?)?.cast<String, dynamic>();
    if (body == null) return null;
    final variant = (body['variants'] as Map?)?[type];
    if (variant is! Map) return null;
    final v = variant.cast<String, dynamic>();
    return BodySchema(
      core: body['core'] as String? ?? '',
      order: ((v['order'] as List?) ?? const []).cast<String>(),
      fields: _fieldsOf(v),
    );
  }

  /// Схема общей суб-схемы по имени `ref` (`tls`, `multiplex`, `dialer`,
  /// `dialer.common`). Транспорты сюда не ходят — у них дискриминатор.
  BodySchema? sharedSchema(String ref) {
    final file = _kSharedRefs[ref];
    if (file == null) return null;
    final data = _shared[file];
    if (data == null) return null;
    // `dialer.common` — секция `common` того же файла.
    final section = ref == 'dialer.common' ? 'common' : 'body';
    final body = (data[section] as Map?)?.cast<String, dynamic>();
    if (body == null || body.containsKey('variants')) return null;
    return _expand(body);
  }

  /// Текст кода из `warnings.json`; `null` — кода в реестре нет.
  WarningText? textFor(String code) => _warnings[code];

  /// Разворот секции `body`: `ref` с `inline: true` вливает поля суб-схемы
  /// плоско на место своего слота в `order` (`__dialer`), обычный `ref`
  /// остаётся ссылкой — санитайзер спускается в него по имени.
  BodySchema _expand(Map<String, dynamic> body) {
    final rawFields = _fieldsOf(body);
    final rawOrder = ((body['order'] as List?) ?? const []).cast<String>();

    final order = <String>[];
    final fields = <String, FieldSchema>{};
    for (final key in rawOrder) {
      final f = rawFields[key];
      if (f == null) continue;
      if (f.inline && f.ref != null) {
        final sub = sharedSchema(f.ref!);
        if (sub == null) continue;
        // Поля dialer занимают место слота `__dialer` — ровно там, где
        // структура ядра держит DialerOptions.
        for (final k in sub.order) {
          final sf = sub.fields[k];
          if (sf == null || fields.containsKey(k)) continue;
          order.add(k);
          fields[k] = sf;
        }
        continue;
      }
      order.add(key);
      fields[key] = f;
    }
    // Поля вне `order` (схема их иметь не должна, но молча терять их нельзя:
    // иначе неописанный в order ключ выглядел бы неизвестным и снимался).
    for (final e in rawFields.entries) {
      if (fields.containsKey(e.key)) continue;
      if (e.value.inline) continue;
      order.add(e.key);
      fields[e.key] = e.value;
    }

    return BodySchema(
      core: body['core'] as String? ?? '',
      order: order,
      fields: fields,
    );
  }

  Map<String, FieldSchema> _fieldsOf(Map<String, dynamic> section) {
    final f = section['fields'];
    if (f is! Map) return const {};
    return {
      for (final e in f.entries)
        e.key as String: FieldSchema((e.value as Map).cast<String, dynamic>()),
    };
  }
}

/// Слот кэша схем: отличает «ещё не считали» от «схемы нет».
final class _SchemaSlot {
  const _SchemaSlot(this.schema);

  final BodySchema? schema;
}

/// §467 — массив строк из реестра (`fix_en`/`fix_ru`). Не массив или его
/// отсутствие — пустой список: реестр вправе ехать впереди клиента, и
/// незнакомая форма поля загрузку не роняет.
List<String> _stringList(Object? v) {
  if (v is! List) return const [];
  return [for (final e in v) if (e is String) e];
}

/// §473 — потолок/дефолт `mtu` AmneziaWG-узла ПО РЕЕСТРУ
/// (`wireguard.body.fields.mtu`: `max_when.max`, `default_when.value`).
///
/// Возвращает значение, которое парсер кладёт в модель: потолок, если
/// исходное выше, и дефолт, если поля не было вовсе.
///
/// Живёт здесь, а не рядом с санитайзером, из-за слоёв: читает его
/// `services/parser/uri_utils.dart`, который сам импортирует
/// `body_sanitizer.dart` — импорт в обратную сторону замкнул бы кольцо.
/// Реестру же парсер не нужен, и зависимость односторонняя.
///
/// Функция существует ровно потому, что тело узла из ссылки/INI менять нельзя
/// (эталоны корпуса), а санитайзер разбора тело не переписывает (§460 W2a,
/// граница 1): замену делает по-прежнему парсер, но число 1280 в Dart не
/// остаётся — правило целиком в реестре. Уйдёт вместе с шагом 7 фичи 472.
int awgMtuByRegistry(int? raw) {
  final f = ContractRegistry.I.schemaFor('wireguard')?.fields['mtu'];
  if (raw == null) {
    final dv = f?.defaultWhen?['value'];
    return dv is int ? dv : kAwgMtuFallback;
  }
  final ceiling = f?.maxWhen?['max'];
  // Реестра нет — работает ЗАПАСНОЕ число, а не «потолка нет». Разница не
  // косметическая: без реестра «потолка нет» отдало бы AWG-узлу написанный
  // 1420, туннель поднялся бы и данные по нему не пошли. Молчание тут не
  // безопасно, в отличие от кодов.
  final limit = ceiling is num ? ceiling.toInt() : kAwgMtuFallback;
  return raw > limit ? limit : raw;
}

/// Потолок/дефолт AmneziaWG-MTU, когда реестр не загружен.
///
/// Реестр — не обязательное условие работы приложения (§460: не загрузился —
/// живём как до него), но `mtu` у AWG-узла обязан быть проставлен и ограничен:
/// без этого ядро берёт 1408, туннель поднимается, и данные по нему не идут.
/// Поэтому у ЭТОГО значения запасной путь есть, в отличие от кодов, где
/// молчание безопасно: выдуманный код хуже его отсутствия, а выдуманный MTU
/// здесь — единственный рабочий.
const kAwgMtuFallback = 1280;

/// Файлы `registry/protocols/` — перечислены поимённо: `rootBundle` каталог
/// не листает (AssetManifest дал бы список, но ценой второго формата
/// чтения), а состав меняется только вместе с бампом контракта, и тогда
/// список правится осознанно. Расхождение ловит `registry_load_test`.
const _kProtocolFiles = <String>[
  'anytls',
  'chain',
  'group',
  'http',
  'hysteria',
  'hysteria2',
  'masque',
  'naive',
  'shadowsocks',
  'socks',
  'ssh',
  'tailscale',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'wireguard',
];
