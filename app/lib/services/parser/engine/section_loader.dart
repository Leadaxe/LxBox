/// §480 W1 — ЗАГРУЗЧИК СЕКЦИЙ-МАППЕРОВ.
///
/// Секция берётся из РЕЕСТРА контракта, если она там ИСПОЛНЯЕМАЯ, и только
/// иначе — из черновика `assets/contract_draft/uri/`. Порядок именно такой, а
/// не наоборот: как только лаунчер пришлёт секцию контрактом, движок обязан
/// начать исполнять её, не дожидаясь правки кода, — иначе черновик станет
/// вторым источником правды, то есть ровно тем расхождением, ради снятия
/// которого затеяна кампания.
///
/// **Чем исполняемая секция отличается от описательной.** В реестре сегодня
/// у каждого протокола есть секция `uri`, но её читает только генератор
/// документации: там `desc_en`/`impl`/`maps_to` прозой и НЕТ `source` — то
/// есть нет способа получить значение. Признак исполняемости — `mappers`
/// (FROZEN `mappers.<kind>`) либо `source` хотя бы у одной записи
/// ([_isExecutable]).
///
/// Вид источника — параметр ([kind]): `uri` сегодня, `xray`/`singbox`/`conf`
/// волной W5. Загрузчику о них знать нечего, он берёт `mappers.<kind>` как
/// написано.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

import '../../contract/registry.dart';
import 'section.dart';

/// Корень черновых секций. Черновик временный: он живёт до прихода секций
/// контрактом и в реестре не дублируется.
const kDraftRoot = 'assets/contract_draft';

/// Загрузка и кэш секций-мапперов.
///
/// Синглтон по образцу [ContractRegistry]: секции иммутабельны после
/// загрузки, и разбирать их заново на каждый узел подписки нельзя — на 2000
/// узлах это 2000 одинаковых разборов одного JSON.
final class MapperSections {
  MapperSections._();

  static final MapperSections I = MapperSections._();

  /// `<kind>/<singbox_type>` → секция; отсутствие секции тоже кэшируется.
  final Map<String, MapperSection?> _cache = {};

  /// Черновые файлы, уже прочитанные с диска/из ассетов.
  final Map<String, Map<String, dynamic>> _draft = {};

  bool _draftLoaded = false;

  /// Каталог черновиков на диске (тесты) либо `null` — читать из ассетов.
  String? _draftDir;

  /// Прочитать черновики. [dir] — корень черновиков на диске (для тестов и
  /// для CI, где биндинга Flutter нет); по умолчанию — ассеты приложения.
  ///
  /// [files] — имена файлов черновика БЕЗ расширения. Список приходит
  /// снаружи, а не живёт здесь: имена файлов протоколов — это имена схем, а в
  /// пакете движка их быть не должно (греп-страж). Ассеты Flutter в рантайме
  /// не перечисляются, поэтому список явный.
  Future<void> loadDrafts({String? dir, List<String> files = const []}) async {
    _draftDir = dir;
    _draft.clear();
    _cache.clear();
    for (final name in files) {
      final text = await _readDraft('uri/$name.json');
      if (text == null) continue;
      _draft[name] = jsonDecode(text) as Map<String, dynamic>;
    }
    _draftLoaded = true;
  }

  /// Досыпать черновики С ДИСКА синхронно, когда секция понадобилась раньше
  /// явной загрузки.
  ///
  /// Нужно ЮНИТ-ТЕСТАМ: разбор ссылки синхронный, а загрузка ассетов — нет, и
  /// без этого каждый из полусотни тестов, который просто зовёт `parseUri`,
  /// обязан был бы знать про секции и грузить их в `setUpAll`. Знание о
  /// внутреннем устройстве разбора расползлось бы по всему дереву тестов.
  ///
  /// В приложении не работает и не нужен: там нет файловой системы с
  /// ассетами, каталог читается из бандла, и загрузку делает `main()` до
  /// первого разбора. Молчаливый отказ здесь — рабочее состояние.
  void _loadDraftsFromDiskSync() {
    _draftLoaded = true;
    final dir = _draftDir ?? kDraftRoot;
    final root = Directory('$dir/uri');
    if (!root.existsSync()) return;
    for (final f in root.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final name = f.uri.pathSegments.last.replaceAll('.json', '');
      try {
        _draft[name] = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        // Битый черновик — та же «секции нет»: схема идёт прежним путём.
      }
    }
  }

  Future<String?> _readDraft(String rel) async {
    final dir = _draftDir;
    try {
      if (dir != null) return await File('$dir/$rel').readAsString();
      if (kIsWeb) return await rootBundle.loadString('$kDraftRoot/$rel');
      return await rootBundle.loadString('$kDraftRoot/$rel');
    } catch (_) {
      return null;
    }
  }

  /// Секция вида [kind] для типа тела [singboxType]; `null` — секции нет, и
  /// схема идёт прежним путём (рукописным маппером).
  MapperSection? sectionFor(String kind, String singboxType) {
    final key = '$kind/$singboxType';
    if (_cache.containsKey(key)) return _cache[key];
    final built = _build(kind, singboxType);
    _cache[key] = built;
    return built;
  }

  /// Есть ли исполняемая секция — по ней диспетчер решает, идти движком или
  /// рукописным маппером.
  bool has(String kind, String singboxType) =>
      sectionFor(kind, singboxType) != null;

  MapperSection? _build(String kind, String singboxType) {
    final raw = _rawSection(kind, singboxType);
    if (raw == null) return null;
    final section = MapperSection.fromJson(kind, singboxType, raw);
    return section.include.isEmpty ? section : _withIncludes(section);
  }

  /// Сырой JSON секции: сперва реестр (если исполняемая), затем черновик.
  Map<String, dynamic>? _rawSection(String kind, String singboxType) {
    final fromRegistry = _registrySection(kind, singboxType);
    if (fromRegistry != null) return fromRegistry;
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    final file = _draft[singboxType];
    if (file == null) return null;
    final mappers = (file['mappers'] as Map?)?.cast<String, dynamic>();
    final section = (mappers?[kind] as Map?)?.cast<String, dynamic>();
    return section;
  }

  Map<String, dynamic>? _registrySection(String kind, String singboxType) {
    final proto = ContractRegistry.I.rawProtocol(singboxType);
    if (proto == null) return null;
    final mappers = (proto['mappers'] as Map?)?.cast<String, dynamic>();
    final section = (mappers?[kind] as Map?)?.cast<String, dynamic>();
    if (section != null && _isExecutable(section)) return section;
    // Описательная секция `uri` реестра исполняемой НЕ считается: у её
    // записей нет `source`, то есть нет способа получить значение.
    final legacy = (proto[kind] as Map?)?.cast<String, dynamic>();
    if (legacy != null && _isExecutable(legacy)) return legacy;
    return null;
  }

  /// Признак исполняемости: `params` с `source` хотя бы у одной записи.
  static bool _isExecutable(Map<String, dynamic> section) {
    final params = (section['params'] as Map?)?.cast<String, dynamic>();
    if (params == null) return false;
    for (final v in params.values) {
      if (v is Map && v.containsKey('source')) return true;
    }
    return false;
  }

  /// Вмонтировать блоки `include` (FROZEN): `"tls#uri"`, `"transports#uri"`.
  ///
  /// Записи блока становятся ОБЪЯВЛЕННЫМИ параметрами секции — отсюда и
  /// правило «параметры общих файлов не попадают в `uri_param_unknown`»:
  /// отдельного списка исключений не заводится, они просто есть в таблице.
  ///
  /// Конфликт имени — собственная запись схемы побеждает: общий блок даёт
  /// запись с одним набором написаний, схема вправе объявить свой, и
  /// переопределение обязано работать.
  MapperSection _withIncludes(MapperSection section) {
    final merged = <String, MapperParam>{};
    for (final ref in section.include) {
      for (final e in _blockParams(ref).entries) {
        merged[e.key] = e.value;
      }
    }
    for (final e in section.params.entries) {
      merged[e.key] = e.value;
    }
    return section.withParams(merged);
  }

  /// Записи блока по ссылке `"<файл>#<диалект>"` (`"tls#uri"`,
  /// `"transports#xray"`).
  ///
  /// Раскладка у лаунчера: `blocks.<диалект>` — либо плоская карта записей
  /// (tls), либо карта ГРУПП (transports: `$selector`, `ws`, `http`, …). Обе
  /// формы разворачиваются в один плоский набор записей: группа — это только
  /// способ читать файл глазами, вариантность выражена `when` у самих
  /// записей, и движку группа не нужна.
  ///
  /// Имена записей в плоском наборе разводятся по ГРУППЕ (`ws.path` против
  /// `http.path`): у разных транспортов одноимённые параметры ведут в разные
  /// поля тела, и склеить их в одну запись нельзя.
  Map<String, MapperParam> _blockParams(String ref) {
    final hash = ref.indexOf('#');
    final fileName = hash < 0 ? ref : ref.substring(0, hash);
    final dialect = hash < 0 ? 'uri' : ref.substring(hash + 1);

    final file = _draft[fileName] ?? _registryShared(fileName);
    if (file == null) return const {};
    final blocks = (file['blocks'] as Map?)?.cast<String, dynamic>();
    final byDialect = (blocks?[dialect] as Map?)?.cast<String, dynamic>();
    if (byDialect == null) return const {};

    final out = <String, MapperParam>{};
    for (final e in byDialect.entries) {
      final v = e.value;
      // `note` и прочая проза записью не является.
      if (v is! Map) continue;
      final m = v.cast<String, dynamic>();
      if (m.containsKey('source')) {
        out[e.key] =
            MapperParam.fromJson(e.key, _withAliases(e.key, _withRefs(m, blocks!), fileName));
        continue;
      }
      // Группа записей (`$selector`, `ws`, `http`…).
      for (final g in m.entries) {
        final gv = g.value;
        if (gv is! Map) continue;
        final gm = gv.cast<String, dynamic>();
        if (!gm.containsKey('source')) continue;
        out['${e.key}.${g.key}'] =
            MapperParam.fromJson(g.key, _withAliases(g.key, _withRefs(gm, blocks!), fileName));
      }
    }
    return out;
  }

  /// Дополнить запись `aliases` из ОПИСАТЕЛЬНОЙ части того же файла.
  ///
  /// Написания имени объявлены один раз — в словаре `<блок>.params.<имя>`
  /// (`tls.params.insecure` — девять написаний), и исполняемая запись их не
  /// дублирует: у неё об этом сказано прозой в `impl`. Дублировать список в
  /// данных нельзя — он разъехался бы на первом же новом написании, ровно как
  /// разъехались таблицы у обеих сторон до кампании.
  Map<String, dynamic> _withAliases(
    String name,
    Map<String, dynamic> param,
    String fileName,
  ) {
    if (param.containsKey('aliases')) return param;
    // Черновик несёт только `blocks`; словарь написаний лежит в
    // ОПИСАТЕЛЬНОЙ части того же файла реестра, которая у нас есть всегда.
    for (final file in [
      _draft[fileName],
      ContractRegistry.I.rawShared('$fileName.json'),
    ]) {
      if (file == null) continue;
      for (final top in file.values) {
        if (top is! Map) continue;
        final params = (top['params'] as Map?)?.cast<String, dynamic>();
        final decl = (params?[name] as Map?)?.cast<String, dynamic>();
        final aliases = decl?['aliases'];
        if (aliases is List && aliases.isNotEmpty) {
          return {...param, 'aliases': aliases};
        }
      }
    }
    return param;
  }

  /// Раскрыть `{"$ref": "tls.fp_dialect"}` — именованную таблицу `value_map`.
  ///
  /// Ссылка адресует блок ТОГО ЖЕ файла (`<файл>.<имя блока>`), поэтому
  /// разворачивается здесь, при сборке секции: движку ссылок видеть не
  /// нужно, он исполняет уже раскрытую таблицу.
  static Map<String, dynamic> _withRefs(
    Map<String, dynamic> param,
    Map<String, dynamic> blocks,
  ) {
    final vm = param['value_map'];
    if (vm is! Map) return param;
    final ref = vm[r'$ref'];
    if (ref is! String) return param;
    final target = blocks[ref.split('.').last];
    if (target is! Map) return param;
    return {...param, 'value_map': target.cast<String, dynamic>()};
  }

  /// Общий файл реестра (`tls.json`, `transports.json`), когда черновика нет:
  /// блоки приезжают контрактом раньше секций протоколов.
  Map<String, dynamic>? _registryShared(String fileName) =>
      ContractRegistry.I.rawShared('$fileName.json');

}
