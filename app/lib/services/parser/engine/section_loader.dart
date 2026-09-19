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
import 'document.dart';
import 'interpreter.dart' show detectMatchesJson;
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

  /// Черновые файлы, уже прочитанные с диска/из ассетов. Ключ —
  /// `<каталог>/<имя>`: у одного протокола черновиков столько же, сколько
  /// видов источника, и класть их в одно пространство имён нельзя.
  final Map<String, Map<String, dynamic>> _draft = {};

  bool _draftLoaded = false;

  /// Каталог черновиков на диске (тесты) либо `null` — читать из ассетов.
  String? _draftDir;

  /// Прочитать черновики. [dir] — корень черновиков на диске (для тестов и
  /// для CI, где биндинга Flutter нет); по умолчанию — ассеты приложения.
  ///
  /// [files] — пути черновика БЕЗ расширения, вида `<каталог>/<имя>`, где
  /// каталог это вид источника; имя без каталога читается как `uri/<имя>`,
  /// а если такого файла нет — как файл КОРНЯ черновика. Список приходит
  /// снаружи, а не живёт здесь: имена файлов протоколов — это имена схем, а
  /// в пакете движка их быть не должно (греп-страж). Ассеты Flutter в
  /// рантайме не перечисляются, поэтому список явный.
  ///
  /// Имя без каталога читается как `uri/<имя>` — так короче писался список
  /// волны W1, когда вид источника был один.
  Future<void> loadDrafts({String? dir, List<String> files = const []}) async {
    _draftDir = dir;
    _draft.clear();
    _cache.clear();
    _documents = null;
    for (final name in files) {
      final rel = name.contains('/') ? name : 'uri/$name';
      var text = await _readDraft('$rel.json');
      var key = rel;
      if (text == null && !name.contains('/')) {
        // Файл КОРНЯ черновика (реестр видов документа): он не принадлежит
        // ни одному виду источника, поэтому каталога у него нет.
        text = await _readDraft('$name.json');
        key = name;
      }
      if (text == null) continue;
      _draft[key] = jsonDecode(text) as Map<String, dynamic>;
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
    for (final sub in const ['uri', 'xray', 'singbox', 'conf', '']) {
      final root = Directory(sub.isEmpty ? dir : '$dir/$sub');
      if (!root.existsSync()) continue;
      for (final f in root.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        final name = f.uri.pathSegments.last.replaceAll('.json', '');
        final key = sub.isEmpty ? name : '$sub/$name';
        try {
          _draft[key] =
              jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        } catch (_) {
          // Битый черновик — та же «секции нет».
        }
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

  /// §480 W6 — РЕЕСТР ВИДОВ ДОКУМЕНТА; `null` — реестра нет, и опознание
  /// идёт прежним рукописным путём.
  ///
  /// Черновик лежит в корне (`documents.json`), без каталога вида источника:
  /// он не принадлежит ни одному виду, он их ВЫБИРАЕТ.
  DocumentRegistry? get documents {
    if (_documents != null) return _documents;
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    final raw = ContractRegistry.I.rawShared('sources.json') ??
        _draft['documents'] ??
        _draft['uri/documents'];
    if (raw == null) return null;
    return _documents = DocumentRegistry.fromJson(raw);
  }

  DocumentRegistry? _documents;

  /// Типы тела, у которых есть секция вида [kind].
  ///
  /// Состав берётся из ЧЕРНОВИКА и РЕЕСТРА вместе, без списка в коде: имена
  /// протоколов в пакете движка не живут (греп-страж), и «знать, какие
  /// секции бывают» значило бы завести их здесь.
  List<String> typesFor(String kind) {
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    final out = <String>{};
    final prefix = '$kind/';
    for (final key in _draft.keys) {
      if (!key.startsWith(prefix)) continue;
      final name = key.substring(prefix.length);
      // Общий блок (`tls`, `transports`) секцией протокола не является.
      if (_draft[key]?['mappers'] == null) continue;
      out.add(name);
    }
    for (final name in ContractRegistry.I.protocolNames) {
      final proto = ContractRegistry.I.rawProtocol(name);
      final mappers = (proto?['mappers'] as Map?)?.cast<String, dynamic>();
      final section = (mappers?[kind] as Map?)?.cast<String, dynamic>();
      if (section != null) out.add(name);
    }
    final list = out.toList()..sort();
    return list;
  }

  /// **ОПОЗНАНИЕ ЭЛЕМЕНТА** (§2 НОРМЫ): какой секции принадлежит объект.
  ///
  /// Побеждает секция с меньшим `priority` у `detect`; ветка `default: true`
  /// НИКОГДА не конкурирует с настоящим предикатом (иначе «всё остальное»
  /// выигрывало бы у точного признака). Ровно одна секция на элемент —
  /// инвариант, который проверяет линтер корпуса.
  MapperSection? matchJson(String kind, Map<String, dynamic> element) {
    MapperSection? best;
    var bestPriority = 1 << 30;
    MapperSection? fallback;
    for (final type in typesFor(kind)) {
      final section = sectionFor(kind, type);
      if (section == null) continue;
      final d = section.detect;
      if (d == null) continue;
      if (d['default'] == true) {
        fallback ??= section;
        continue;
      }
      if (!detectMatchesJson(d, element)) continue;
      final pr = (d['priority'] as num?)?.toInt() ?? 0;
      if (pr < bestPriority) {
        best = section;
        bestPriority = pr;
      }
    }
    return best ?? fallback;
  }

  /// Все секции вида [kind], чей `detect` опознал элемент. Нужен ЛИНТЕРУ:
  /// «ровно одна секция» — красное при нуле и при двух.
  List<MapperSection> matchJsonAll(String kind, Map<String, dynamic> element) {
    final out = <MapperSection>[];
    for (final type in typesFor(kind)) {
      final section = sectionFor(kind, type);
      final d = section?.detect;
      if (section == null || d == null || d['default'] == true) continue;
      if (detectMatchesJson(d, element)) out.add(section);
    }
    return out;
  }

  MapperSection? _build(String kind, String singboxType) {
    // Черновики нужны и тогда, когда сама секция нашлась в реестре: оверлеи
    // общих блоков лежат там же, и без них блок соберётся без наших
    // отступлений.
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    final raw = _rawSection(kind, singboxType);
    if (raw == null) return null;
    final section =
        MapperSection.fromJson(kind, singboxType, _sectionRefs(raw));
    return section.include.isEmpty ? section : _withIncludes(section);
  }

  /// Раскрыть `{"$ref": …}` у записей САМОЙ секции.
  ///
  /// Именованная таблица `value_map` живёт в общем файле (`tls.fp_dialect`),
  /// и до сих пор ссылка разворачивалась ТОЛЬКО при сборке общего блока
  /// ([_withRefs]). Запись схемы, которая перекрывает одноимённую запись
  /// блока (у `fp` так делают те схемы, где пустое значение означает
  /// `random`), уносила ссылку с собой нераскрытой — и таблица переставала
  /// исполняться совсем: `hellofirefox_auto` доезжал до тела как есть, а
  /// санитайзер закрытого набора возвращал первое значение.
  ///
  /// Развернуть ссылку у схемы дешевле, чем копировать таблицу в каждую
  /// секцию: копия и есть тот второй источник правды, ради снятия которого
  /// затеяна кампания.
  Map<String, dynamic> _sectionRefs(Map<String, dynamic> raw) {
    final rawParams = (raw['params'] as Map?)?.cast<String, dynamic>();
    if (rawParams == null) return raw;
    Map<String, dynamic>? patched;
    for (final e in rawParams.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final m = v.cast<String, dynamic>();
      final vm = m['value_map'];
      if (vm is! Map) continue;
      final ref = vm[r'$ref'];
      if (ref is! String) continue;
      // `<файл>.<имя блока>`: таблица лежит в блоках общего файла, и найти
      // её можно только там, где этот файл доступен, — здесь.
      final parts = ref.split('.');
      if (parts.length < 2) continue;
      final shared = _draftShared(parts.first) ?? _registryShared(parts.first);
      final target = (shared?['blocks'] as Map?)?[parts.last];
      if (target is! Map) continue;
      (patched ??= {...rawParams})[e.key] = {
        ...m,
        'value_map': target.cast<String, dynamic>(),
      };
    }
    return patched == null ? raw : {...raw, 'params': patched};
  }

  /// Сырой JSON секции: сперва реестр (если исполняемая), затем черновик.
  ///
  /// Черновик-ОВЕРЛЕЙ (`_overlay: true`) секцию не заменяет, а накладывается
  /// на неё: в нём лежат только те ключи, которые у нас обязаны быть иными.
  Map<String, dynamic>? _rawSection(String kind, String singboxType) {
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    // Черновик вида источника лежит в своём каталоге; `uri` — исторически
    // и в плоском пространстве имён тоже.
    final file = _draft['$kind/$singboxType'] ??
        (kind == 'uri' ? _draft[singboxType] : null);
    final draft =
        ((file?['mappers'] as Map?)?[kind] as Map?)?.cast<String, dynamic>();

    final fromRegistry = _registrySection(kind, singboxType);
    // Реестра нет — идёт ПОЛНЫЙ черновик (волны, написанные вперёд синка).
    if (fromRegistry == null) return draft;
    // Реестр есть, а черновик не оверлей — реестр нормативен.
    if (draft == null || file?['_overlay'] != true) return fromRegistry;
    // Оверлей: только те ключи, которые у нас обязаны быть иными.
    return _mergeOverlay(fromRegistry, draft);
  }

  Map<String, dynamic>? _registrySection(String kind, String singboxType) {
    final proto = ContractRegistry.I.rawProtocol(singboxType);
    if (proto == null) return null;
    final mappers = (proto['mappers'] as Map?)?.cast<String, dynamic>();
    // Секция под FROZEN-ключом `mappers.<вид>` исполняема ПО ОПРЕДЕЛЕНИЮ —
    // проверять её записи не нужно и НЕЛЬЗЯ: у секции вида `singbox`
    // пустая `params` это нормальное конечное состояние (норма §8a, вход
    // уже в каноне ядра), а вся её работа — `detect`, `body_source` и
    // `unknown_key`. Требуй мы записи, такая секция считалась бы
    // отсутствующей, и элемент не достался бы никому.
    final section = (mappers?[kind] as Map?)?.cast<String, dynamic>();
    if (section != null) return section;
    // Описательная секция `uri` реестра исполняемой НЕ считается: у её
    // записей нет `source`, то есть нет способа получить значение. Здесь
    // проверка обязательна — ключ `<вид>` в корне протокола не FROZEN, и под
    // ним лежит проза для генератора документации.
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
  /// Конфликт имени — собственная запись схемы ЗАМЕНЯЕТ запись блока: общий
  /// блок даёт запись с одним набором написаний, схема вправе объявить свой,
  /// и переопределение обязано работать. Заменяет, а не дополняет: две
  /// записи с одним `source` читали бы параметр дважды и писали бы путь
  /// дважды, а тонкая настройка схемы (`priority`, `sets`) при этом
  /// действовала бы только у второй — а бывает запись, у которой вся суть
  /// в её МЕСТЕ в таблице (снятие пути обязано идти последним).
  ///
  /// Ключи в плоском наборе НЕСУТ ИМЯ БЛОКА (`tls.security`), потому что у
  /// разных блоков и разных транспортов бывают одноимённые записи, ведущие в
  /// разные поля. Переопределением считается совпадение ИМЕНИ ПАРАМЕТРА **и
  /// ИСТОЧНИКА**: одно имя над РАЗНЫМИ источниками — это две разные записи, а
  /// не спор. Живой случай: у одной схемы `security` читает шифр из данных
  /// пользователя, у общего блока `security` — вид TLS из настроек потока, и
  /// обе записи обязаны отработать.
  MapperSection _withIncludes(MapperSection section) {
    final merged = <String, MapperParam>{};
    final own = <String>{
      for (final p in section.params.values) ..._overrideKeys(p),
    };
    for (final ref in section.include) {
      for (final e in _blockParams(ref).entries) {
        if (_overrideKeys(e.value).any(own.contains)) continue;
        merged[e.key] = e.value;
      }
    }
    for (final e in section.params.entries) {
      merged[e.key] = e.value;
    }
    return section.withParams(merged);
  }

  /// Ключи, по которым запись СПОРИТ с одноимённой записью блока.
  ///
  /// Ключ — имя параметра плюс ОДИН источник, и ключей у записи столько,
  /// сколько источников она объявила: спор решается по любому совпадению.
  /// Запись с источниками ПО ФОРМАМ иначе не спорила бы вовсе — плоский
  /// `source` у неё пуст, и ключ вырождался бы в одно имя.
  ///
  /// Живой случай: у схемы-контейнера `security` объявлен картой по формам
  /// (`json.scy`/`json.security` у контейнера, `userinfo.user` у cleartext), а
  /// у блока `tls` — как `query.security`. Контейнер раскладывается ПЛОСКИМ
  /// СЛОЕМ, и `json.security` с `query.security` адресуют один и тот же ключ:
  /// не сочти их спором — и запись блока включила бы узлу TLS по значению,
  /// которое на деле шифр канала.
  static Iterable<String> _overrideKeys(MapperParam p) sync* {
    // `\u0000` СЕНТИНЕЛОМ, а не сырым байтом: NUL, попав в исходник
    // литералом, делает файл бинарным для grep, и правка перестаёт
    // находиться поиском.
    const sep = '\u0000';
    final all = <String>{
      ...p.source,
      for (final l in p.sourceByForm.values) ...l,
    };
    if (all.isEmpty) {
      yield '${p.name}$sep';
      return;
    }
    for (final src in all) {
      // Пространство источника для спора НЕ различается: у формы-контейнера
      // `json.<ключ>` и `query.<ключ>` — одно имя в одном плоском слое.
      final bare = src.startsWith('json.')
          ? src.substring('json.'.length)
          : src.startsWith('query.')
              ? src.substring('query.'.length)
              : src;
      yield '${p.name}$sep$bare';
    }
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

    // Общий блок живёт ОДНИМ файлом на все диалекты (`blocks.uri`,
    // `blocks.xray`), поэтому каталог у него не по виду источника.
    //
    // Источник — ПОЛНЫЙ черновик, если он есть, иначе реестр. Поверх обоих
    // ложится ОВЕРЛЕЙ (`_overlay: true`): он несёт не весь блок, а только те
    // записи, которые у нас обязаны вести себя иначе, и каждая такая запись
    // — красный кейс, переданный лаунчеру. Полная копия блока ради одной
    // правки была бы вторым источником правды и протухла бы на первом синке.
    final draft = _draftShared(fileName);
    final overlay = draft != null && draft['_overlay'] == true ? draft : null;
    final file = (overlay == null ? draft : null) ?? _registryShared(fileName);
    if (file == null) return const {};
    final blocks = (file['blocks'] as Map?)?.cast<String, dynamic>();
    var byDialect = (blocks?[dialect] as Map?)?.cast<String, dynamic>();
    if (byDialect == null) return const {};

    if (overlay != null) {
      final ov = ((overlay['blocks'] as Map?)?[dialect] as Map?)
          ?.cast<String, dynamic>();
      if (ov != null) byDialect = _mergeOverlay(byDialect, ov);
    }

    final out = <String, MapperParam>{};
    for (final e in byDialect.entries) {
      final v = e.value;
      // Запись-`null` — ОБЪЯВЛЕННОЕ «знаем, читать нечего» (контракт 1.1.34
      // §31.2). Параметр назван, значит незнакомым он не является и кода не
      // даёт ни на одном входе; источника у него нет, поэтому в тело он не
      // едет. Пропусти её молча — и такие параметры общих блоков уезжали бы
      // в `uri_param_unknown`, то есть объявленное молчание звучало бы
      // потерей (два живых кейса корпуса ссылок).
      if (v == null) {
        out['$fileName.${e.key}'] =
            MapperParam.fromJson(e.key, const {'source': <String>[]});
        continue;
      }
      // `note` и прочая проза записью не является.
      if (v is! Map) continue;
      final m = v.cast<String, dynamic>();
      if (m.containsKey('source')) {
        // Ключ в плоском наборе — С ИМЕНЕМ БЛОКА (`tls.security`), потому что
        // одноимённая запись бывает и у схемы: `security` схемы это шифр, а
        // `security` общего блока — вид TLS, и ведут они в разные поля тела.
        // Без разведения запись схемы затирала бы селектор блока, и TLS-блок
        // у такой схемы не появлялся бы вовсе. ИМЯ ПАРАМЕТРА при этом
        // остаётся коротким: по нему читаются написания.
        out['$fileName.${e.key}'] = MapperParam.fromJson(
            e.key, _withAliases(e.key, _withRefs(m, blocks!), fileName));
        continue;
      }
      // Группа записей (`$selector`, `ws`, `http`…).
      for (final g in m.entries) {
        final gv = g.value;
        if (gv is! Map) continue;
        final gm = gv.cast<String, dynamic>();
        if (!gm.containsKey('source')) continue;
        out['$fileName.${e.key}.${g.key}'] = MapperParam.fromJson(
            g.key, _withAliases(g.key, _withRefs(gm, blocks!), fileName));
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
      _draftShared(fileName),
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

  /// Наложить оверлей на блок реестра: запись оверлея ЗАМЕЩАЕТ одноимённую
  /// запись реестра целиком, группы сливаются по имени.
  ///
  /// Замещение целиком, а не слияние полей записи: «снять `implies`» иначе не
  /// выразить, а именно это и нужно в обоих сегодняшних отступлениях.
  static Map<String, dynamic> _mergeOverlay(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final out = {...base};
    for (final e in overlay.entries) {
      final ov = e.value;
      final b = out[e.key];
      // Группа записей (`ws`, `http`): сливаем поимённо, иначе оверлей одной
      // записи снёс бы всю группу.
      if (ov is Map && b is Map && !ov.containsKey('source')) {
        out[e.key] = {...b.cast<String, dynamic>(), ...ov.cast<String, dynamic>()};
      } else {
        out[e.key] = ov;
      }
    }
    return out;
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

  /// Черновик общего блока: он один на все диалекты, и каталог у него может
  /// быть любой (исторически `uri/`).
  Map<String, dynamic>? _draftShared(String fileName) {
    if (!_draftLoaded) _loadDraftsFromDiskSync();
    for (final key in ['uri/$fileName', fileName, 'xray/$fileName']) {
      final f = _draft[key];
      if (f != null && f['blocks'] is Map) return f;
    }
    return null;
  }

  /// Общий файл реестра (`tls.json`, `transports.json`), когда черновика нет:
  /// блоки приезжают контрактом раньше секций протоколов.
  Map<String, dynamic>? _registryShared(String fileName) =>
      ContractRegistry.I.rawShared('$fileName.json');

}
