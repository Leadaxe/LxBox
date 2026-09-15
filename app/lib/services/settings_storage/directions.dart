part of '../settings_storage.dart';

// §125 — Направления роутинга (`directions[]`) для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Паттерн read-весь-объект → mutate-copy → rewrite-atomically
// идентичен `network.dart:_setGroupPing` (эталон per-group storage).
//
// `directions[]` заменяет `enabled_groups[]` (deprecated) и статичные
// `template.presetGroups` как source-of-truth состава Направлений. Миграция
// (`_migrateDirectionsIfNeeded`) на первом запуске seed'ит directions из template.

/// §248 — счётчики вылеченных ссылок при мутации Направления (SnackBar в UI,
/// тело ответа Debug API). `rules` — route_final/custom-rule → vpn-1
/// (только disable/delete, §274 снял flag-set-триггер); `detours` —
/// overrideDetour/member.detour → нет ссылки (None) при disable/delete/flag-unset;
/// `includes` — §393 A3, `Direction.include` чужих Направлений → тег вычеркнут
/// (только delete, см. [clearIncludeDirectionRefs]).
/// §393 D2 — `chainPositions`: ПОЗИЦИИ цепочек с тегом удалённого Направления
/// (только delete, см. [clearChainHopRefs]). Цепочка при этом ОСТАЁТСЯ —
/// снимается ровно позиция, и потому счётчик обязан быть виден: маршрут 3+
/// хопов после вычистки эмитится укороченным.
/// §441 — `dnsServers`: DNS-серверы, которые называли Направление, → vpn-1,
/// как цель правила (disable/delete): у template — переменная типа
/// `outbound` (`vars.outbound`), у пользовательского — `body.detour`, в
/// корневом списке и в секциях узлов. Без лечения такой сервер выпадает на
/// сборке (Н10), а его DNS-правила становятся отказом.
typedef DirectionHealResult = ({
  int rules,
  int detours,
  int includes,
  int chainPositions,
  int dnsServers,
});

Future<List<Direction>> _getDirections() async {
  final data = await _load();
  final raw = data['directions'] as List<dynamic>? ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(Direction.fromJson).toList();
}

Future<void> _setDirections(List<Direction> directions, {bool flush = true}) async {
  final data = await _load();
  data['directions'] = directions.map((c) => c.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// Создать Направление.
///
/// §393 A3 — лимита на количество БОЛЬШЕ НЕТ (паритет с лаунчером:
/// `configtypes.NextDirectionTag` потолка не имеет, а прежние 10 были
/// следствием интерфейса, не модели). [kMaxDirections] остался границей
/// дефолтных имён «VPN ①..VPN ⑩»: одиннадцатое получает честное «VPN 11».
///
/// [tag] — пользовательский тег; по умолчанию первый свободный `vpn-N`
/// ([nextDirectionTag]). Валидируется [directionTagConflict] (непустой после
/// trim, не служебный, не дубль, не тёзка чьего-либо `<tag>-auto`) — при
/// конфликте [StateError] с машинным кодом причины в тексте.
Future<Direction> _addDirection({String? label, String? tag}) async {
  final directions = (await _getDirections()).toList();
  final used = directions.map((c) => c.tag).toList();
  final wanted = (tag ?? nextDirectionTag(used)).trim();
  final conflict = directionTagConflict(wanted, used);
  if (conflict != null) {
    throw StateError('direction tag "$wanted" rejected: $conflict');
  }
  // §198/§393 A3 — дефолтный label: «VPN ⓝ» для автовыданного `vpn-N`,
  // сам тег для произвольного (выдумывать «VPN» для `ru-exit` — врать).
  final ch = Direction(
      tag: wanted, label: label ?? defaultLabelForTag(wanted), enabled: true);
  directions.add(ch);
  await _setDirections(directions);
  return ch;
}

Future<DirectionHealResult> _updateDirection(Direction direction) async {
  final directions = (await _getDirections()).toList();
  final i = directions.indexWhere((c) => c.tag == direction.tag);
  if (i < 0) throw StateError('direction not found: ${direction.tag}');
  // §202 — переход enabled: true → false делает Направление невалидной мишенью
  // (как удаление): билдер деградирует только ВЫХЛОП конфига, а route_final /
  // custom-rule outbound в storage остаются висеть на выключенном теге →
  // «надо идти пересохранять». Лечим storage сразу (route_final / правило →
  // vpn-1). Решение B (28.06.2026): необратимо — повторное включение Направления
  // НЕ воскрешает старую ссылку (правила привязаны к активной конфигурации).
  //
  // §248/§274 — flag-unset лечит detour-ссылки → '' (Направление уходит из пикера
  // §239, ссылки на него как detour-мишень теряют смысл). Flag-SET rules НЕ
  // лечит (§274): detour-флаг — разрешение, Направление остаётся валидной целью
  // правил. Disable лечит ОБА рода (Направление перестаёт быть какой-либо
  // мишенью). Та же необратимость Решения B.
  final was = directions[i];
  directions[i] = direction;
  final disabling = was.enabled && !direction.enabled;
  final flagUnset = was.isDetour && !direction.isDetour;
  var rules = 0;
  var detours = 0;
  var dnsServers = 0;
  if (disabling || flagUnset) {
    await _setDirections(directions, flush: false); // единый flush ниже
    if (disabling) {
      final healed = await _healDirectionRefs(direction.tag);
      rules = healed.rules;
      dnsServers = healed.dnsServers;
    }
    detours = await _healDetourDirectionRefs(direction.tag);
    await _save();
  } else {
    await _setDirections(directions);
  }
  // §393 A3 — include-ссылки на ВЫКЛЮЧЕННОЕ Направление НЕ лечим, в отличие от
  // rules/detours. Асимметрия намеренная и держится на обратимости:
  // выключение — состояние, а не исчезновение. Цель остаётся в списке,
  // форма рисует её чекбоксом (снятым), билдер деградирует ВЫХЛОП с
  // warning'ом, и включение обратно немедленно возвращает рабочий состав.
  // Вычистить `include` здесь значило бы применить необратимость Решения B
  // (§202) к обратимому действию: пользователь вернул бы галку и обнаружил
  // пустой состав, не понимая, куда делись опции.
  return (
    rules: rules,
    detours: detours,
    includes: 0,
    chainPositions: 0,
    dnsServers: dnsServers,
  );
}

/// Удалить Направление. vpn-1 неудаляем (throws). Любая ссылка на удалённый tag
/// (route_final / custom-rule outbound / §441 переменные типа `outbound`
/// template-серверов DNS и пресетов → vpn-1; §248 detour-ссылки → '';
/// §393 A3 include-ссылки → вычеркнуты) немедленно лечится для
/// UI-консистентности; билдер дополнительно схлопывает dangling при сборке
/// (§172-паттерн).
Future<DirectionHealResult> _deleteDirection(String tag) async {
  if (tag == 'vpn-1') throw StateError('vpn-1 is not deletable');
  var directions = (await _getDirections()).toList()
    ..removeWhere((c) => c.tag == tag);
  // §393 A3 — include-ссылки живут В САМОМ списке Направлений, а не в чужом
  // storage-ключе: чистим их ДО записи, одной перезаписью, а не отдельным
  // read-modify-write поверх только что сохранённого списка.
  final (:healed, :count) = clearIncludeDirectionRefs(directions, tag);
  directions = healed;
  await _setDirections(directions, flush: false); // единый flush ниже
  final (:rules, :dnsServers) = await _healDirectionRefs(tag);
  final detours = await _healDetourDirectionRefs(tag);
  await _healPingOptionsGroupRefs(tag);
  await _save();
  return (
    rules: rules,
    detours: detours,
    includes: count,
    chainPositions: 0,
    dnsServers: dnsServers,
  );
}

/// §408 — снятие per-direction override'а ping/URLTest (`ping_options.groups`)
/// удалённого Направления. Пятый род ссылки на тег Направления, до §408
/// единственный без heal'а: карта переживала удаление, ключ оставался висеть
/// сиротой, и создание нового Направления с тем же тегом молча наследовало
/// чужие URL и timeout.
///
/// Только на УДАЛЕНИИ, не на disable и не на снятии detour-флага. Асимметрия
/// та же, что у `include` (§393 A3): выключение — состояние, а не исчезновение;
/// Направление остаётся в списке, его строка ping-настроек осмысленна, и
/// включение обратно должно вернуть ровно то, что было. Удаление же
/// необратимо (Решение B §202) — возвращать нечему.
///
/// Ссылка «на Направление» = его тег ИЛИ тег auto-двойника `<tag>-auto`, как в
/// [_healDirectionRefs]. UI ключ-двойник не создаёт (диалог §040 пишет
/// `state.selectedGroup`, а он приходит из `selectorGroupTags` — только
/// selector'ы, urltest в список не попадает), но Debug API
/// `PUT /settings/ping_options/groups/{tag}` тег не валидирует вовсе, и
/// правленный бэкап приносит что угодно.
///
/// Счётчика наружу не даёт и в [DirectionHealResult] не входит: остальные
/// четыре рода меняют МАРШРУТ (правило поехало на vpn-1, detour сброшен,
/// опция вычеркнута, хоп цепочки снят) — про такое пользователю говорят.
/// Ping-override — настройка ИЗМЕРЕНИЯ узлов удалённого Направления;
/// сообщать «сброшен 1 ping-override» о сущности, которой больше нет, —
/// шум в том же SnackBar'е.
///
/// Всё flush:false — атомарный `_save()` на вызывающем.
Future<void> _healPingOptionsGroupRefs(String deletedTag) async {
  final autoTag = '$deletedTag-auto';
  final data = await _load();
  final opts = data['ping_options'];
  if (opts is! Map<String, dynamic>) return;
  if (!_dropPingGroupKeys(opts, (t) => t == deletedTag || t == autoTag)) return;
  data['ping_options'] = opts;
  SettingsStorage._cache = data;
}

/// Перевод rules-ссылок на Направление → 'vpn-1'. Вызывается, когда Направление
/// перестаёт быть валидной route-мишенью: удалён (§125 F4.5) или выключен
/// (§202). Detour-flag-set больше НЕ триггер (§274: флаг — разрешение,
/// Направление остаётся целью правил). Возвращает число вылеченных ссылок.
/// Всё flush:false — атомарный `_save()` на вызывающем.
///
/// §248 — ссылка «на Направление» = его тег ИЛИ тег auto-двойника `<tag>-auto`:
/// UI-пикеры двойник не предлагают, но Debug API / правленный backup могут
/// записать что угодно.
///
/// §441 (SPEC 129 §6, D-114) — значение переменной типа `outbound` в записи —
/// одиночная цель по имени того же класса: у пресета (любое имя этого типа
/// по объявлению шаблона, `outbound` — всегда) и у template-сервера DNS
/// (`vars.outbound`; сервер вне шаблона — ключ `outbound` по имени). Лечится
/// так же → vpn-1, затем Н4: vpn-1, равное умолчанию объявления, снимает ключ
/// (сервер снова следует шаблону). Detour DNS (D-114) — `body.detour`
/// пользовательского сервера, корневого и в секциях узлов, — туда же.
/// `rules` — правила (одно на правило), `dnsServers` — DNS-серверы.
Future<({int rules, int dnsServers})> _healDirectionRefs(
    String deletedTag) async {
  final autoTag = '$deletedTag-auto';
  final retarget = directionRefRetarget(deletedTag, 'vpn-1');
  final decls = await loadRecordVarDecls();
  var count = 0;
  // route_final
  final routeFinal = await SettingsStorage.getRouteFinal();
  if (routeFinal == deletedTag || routeFinal == autoTag) {
    await SettingsStorage.saveRouteFinal('vpn-1', flush: false);
    count++;
  }
  // custom-rule outbounds: inline/srs — поле `outbound`; preset — переменные
  // типа `outbound` в `varsValues` (§033 Expansion §5, §441), без heal они
  // уезжали в expandPreset dangling-тегом → fatal DanglingOutboundRef, VPN не
  // стартует; json — '' (deletedTag всегда непустой, не сматчит).
  // reject/direct-out — не direction-tag'и, под deletedTag не подпадут.
  // Build-time страховки для rule-outbound НЕТ (healDanglingDetours §172 чинит
  // только detour-поля, валидатор §141 P0.1 блокирует, не лечит) —
  // storage-heal здесь единственное самолечение.
  final rules = await SettingsStorage.getCustomRules();
  var changed = false;
  final healed = rules.map((r) {
    final next = r is CustomRulePreset
        ? retargetPresetOutboundVars(r, decls, retarget)
        : (r.outbound == deletedTag || r.outbound == autoTag)
            ? r.withOutbound('vpn-1')
            : r;
    if (!identical(next, r)) {
      changed = true;
      count++;
    }
    return next;
  }).toList();
  if (changed) {
    await SettingsStorage.saveCustomRules(healed, flush: false);
  }
  return (
    rules: count,
    dnsServers: await _healDnsServerDirectionRefs(retarget, decls),
  );
}

/// §441 — ссылки DNS-серверов на Направление по [retarget]: корневой список
/// ([retargetDnsServerDirectionRefs]: переменные типа `outbound` template,
/// `body.detour` user) и секции узлов ([retargetSectionsDnsDetours]).
/// Возвращает число вылеченных серверов. flush:false — атомарный `_save()` на
/// вызывающем; зеркало секций в контроллере — `DirectionMutations`.
Future<int> _healDnsServerDirectionRefs(
  Map<String, String> retarget,
  RecordVarDecls decls,
) async {
  var count = 0;
  final servers = await SettingsStorage.getDnsServers();
  var rootCount = 0;
  final healedServers = <DnsServerRef>[];
  for (final s in servers) {
    final next = retargetDnsServerDirectionRefs(s, decls, retarget);
    if (!identical(next, s)) rootCount++;
    healedServers.add(next);
  }
  if (rootCount > 0) {
    await SettingsStorage.saveDnsServers(healedServers, flush: false);
  }
  count += rootCount;

  final lists = await _getServerLists();
  var listsChanged = false;
  final healedLists = <ServerList>[];
  for (final l in lists) {
    final r = retargetSectionsDnsDetours(l, retarget);
    if (r.healed != null) {
      listsChanged = true;
      count += r.count;
    }
    healedLists.add(r.healed ?? l);
  }
  if (listsChanged) await _saveServerLists(healedLists, flush: false);
  return count;
}

/// §248 — сброс detour-ссылок на Направление → нет ссылки (None): overrideDetour
/// одиночки/подписки/папки + личные `FolderMember.detour`. Вызывается, когда
/// Направление перестаёт быть detour-мишенью: галка detour снята, Направление выключен
/// или удалён. Необратимо (Решение B §202). Возвращает число сброшенных.
///
/// Ссылка «на Направление» — корневая `{tag}` с tag ИЛИ `<tag>-auto`
/// (двойник); пара адресует узел контейнера и Направлением не бывает (D-112).
/// Всё flush:false — атомарный `_save()` на вызывающем.
Future<int> _healDetourDirectionRefs(String tag) async {
  final lists = await _getServerLists();
  var count = 0;
  var changed = false;
  final healed = <ServerList>[];
  for (final l in lists) {
    // Общее ядро с in-memory ресинком контроллера (server_list.dart).
    final r = clearDetourDirectionRefs(l, tag);
    if (r.healed != null) {
      changed = true;
      count += r.count;
      healed.add(r.healed!);
    } else {
      healed.add(l);
    }
  }
  if (changed) await _saveServerLists(healed, flush: false);
  return count;
}

// ---------------------------------------------------------------------------
// §125 F0.3 / §393 A2 — one-shot миграция состава Направлений.
//
// Легаси-пару `channels`/`channels_migrated` здесь больше не видно: её
// переименовывает миграция формы хранения (§439,
// `storage_migration/migrate_storage.dart`) при чтении файла и на входах
// импорта. Из легаси здесь остаётся `enabled_groups` (seed старейших установок).
//
// Три ветки (в порядке проверки):
//   1. `directions` есть            → no-op (нормальный второй и далее запуск);
//   2. `directions_migrated == true` → мигрировано-и-опустошено (юзер удалил все
//      Направления кроме… либо список вычистили): НЕ пересеивать, только
//      перештамповать маркер;
//   3. иначе                        → чистая установка ИЛИ старейшая, где есть
//      только `enabled_groups`: seed из template (legacy-цепочка сохранена
//      целиком — `getEnabledGroups()` ниже), затем `directions_migrated`.
//
// §267 — сид собирается из `default_directions` (плоский список tag/label/enabled)
// + общего json-шаблона `direction`; auto-подгруппа заводится когда
// `direction.include` содержит роль `auto`.
//
// Идемпотентна: любой повторный вызов после любой ветки уходит в ветку 1 или 2.
// Зовётся на старте (main() init) ДО первого чтения Направлений и ПОСЛЕ restore
// внутреннего бэкапа (`BackupService.applyImport` — архив без Направлений
// получает seed, §393 порядок restore→migrate).
// ---------------------------------------------------------------------------

/// §393 A3 — продуктовый инвариант «vpn-1 существует и включён», закреплённый
/// в ЕДИНСТВЕННОЙ точке, через которую проходят ВСЕ пути загрузки состава:
/// старт (`main()` init), restore внутреннего бэкапа (`applyImport` →
/// migrate) и Debug API `/backup/import`. Все трое зовут
/// [_migrateDirectionsIfNeeded].
///
/// Зачем понадобилось. До §393 A3 инвариант держался КОНСТРУКТИВНО: теги были
/// только `vpn-N`, `vpn-1` сеялся миграцией и был неудаляем/невыключаем —
/// список без него нельзя было построить. A3 снял ограничение на форму тега
/// (`ru-exit` легален) и открыл правленый импорт, и список без `vpn-1` стал
/// конструируемым: достаточно подсунуть `{"directions":[{"tag":"ru-exit"}]}`.
/// А целятся в `vpn-1` жёстко:
///   • `_healDirectionRefs` — `saveRouteFinal('vpn-1')` и `withOutbound('vpn-1')`;
///   • билдер — деградация dangling `route_final` → `'vpn-1'`
///     (`build_config.dart`, «switched to vpn-1»).
/// Без записи-мишени каждый из них пишет висячую ссылку, а висячий
/// `route.final` — fatal на старте ядра: VPN не поднимается вовсе.
///
/// Дёшево: проверка идёт по СЫРОМУ списку (`map['tag']`), без
/// `Direction.fromJson` — на самом частом пути (ветка 1, vpn-1 на месте) это
/// один линейный проход и ноль записей на диск. Возвращает `true`, только
/// если запись вставлена — вызывающий решает, сохранять ли.
///
/// Вставляем ПЕРВОЙ: `vpn-1` — умолчание всех heal'ов, и в списке Направлений
/// (он же порядок эмиссии, он же область видимости `include`) умолчание
/// должно быть видно всем. Чужие записи сохраняются как есть, в своём порядке.
bool _ensureRequiredDirection(Map<String, dynamic> data) {
  final raw = data['directions'];
  if (raw is! List) return false;
  for (final e in raw) {
    if (e is Map && e['tag'] == 'vpn-1') return false;
  }
  data['directions'] = [
    Direction(
      tag: 'vpn-1',
      label: defaultLabelForTag('vpn-1'),
      enabled: true,
    ).toJson(),
    ...raw,
  ];
  return true;
}

/// §408 — one-shot уборка осиротевших ключей `ping_options.groups`.
///
/// Дыра предсуществующая: до §408 heal'а у карты не было вовсе, и у любого,
/// кто когда-либо удалял Направление с персональными URL/timeout, ключ лежит
/// в storage до сих пор. Новый heal чинит только будущие удаления — уже
/// накопленных сирот он не видит.
///
/// Живёт В МИГРАЦИИ Направлений, а не отдельной one-shot записью с
/// собственным guard'ом, ровно по причине [_ensureRequiredDirection]:
/// [_migrateDirectionsIfNeeded] — ЕДИНСТВЕННАЯ точка, через которую проходят
/// ВСЕ пути загрузки состава (старт `main()`, restore внутреннего бэкапа,
/// Debug API `/backup/import`), и только там список Направлений заведомо
/// финальный. Отдельный guard-ключ вдобавок был бы вреден: сироту приносит и
/// восстановленный архив (бэкап несёт `ping_options` целиком — он в
/// allowlist'е §221), а one-shot с guard'ом отработал бы один раз до restore
/// и больше никогда.
///
/// Гонки с «ещё не загруженной сущностью» нет: `directions` и `ping_options`
/// лежат в ОДНОМ файле, читаются одним `_load()`, и на момент вызова список
/// Направлений в `data` уже приведён к финальному виду всеми ветками
/// миграции (включая seed и [_ensureRequiredDirection]). Живым считается тег
/// Направления ЛЮБОГО состояния, включая выключенное, плюс его двойник
/// `<tag>-auto`: выключение обратимо, override переживает его (см.
/// [_healPingOptionsGroupRefs]).
///
/// Дёшево и по сырым данным (`map['tag']`, без `Direction.fromJson`).
/// Возвращает `true`, только если что-то снято, — вызывающий решает, писать
/// ли на диск. На самом частом пути (карты `groups` нет вовсе) выходит на
/// первой же проверке.
bool _pruneOrphanPingGroups(Map<String, dynamic> data) {
  final opts = data['ping_options'];
  if (opts is! Map<String, dynamic>) return false;
  if (opts['groups'] is! Map<String, dynamic>) return false;
  final alive = <String>{};
  final raw = data['directions'];
  if (raw is List) {
    for (final e in raw) {
      if (e is Map) {
        final tag = e['tag'];
        if (tag is String && tag.isNotEmpty) {
          alive.add(tag);
          alive.add('$tag-auto');
        }
      }
    }
  }
  if (!_dropPingGroupKeys(opts, (t) => !alive.contains(t))) return false;
  data['ping_options'] = opts;
  return true;
}

Future<void> _migrateDirectionsIfNeeded(
  GroupTemplates gt, {
  Map<String, String> varDefaults = const {},
}) async {
  final data = await _load();

  // 1. Уже на новом ключе — не трогаем (самый частый путь).
  if (data['directions'] is List) {
    var dirty = false;
    if (_ensureRequiredDirection(data)) dirty = true;
    if (_pruneOrphanPingGroups(data)) dirty = true; // §408
    if (dirty) {
      SettingsStorage._cache = data;
      await _save();
    }
    return;
  }

  // 2. Мигрировано-и-пусто: список Направлений отсутствует ОСОЗНАННО. Пере-сеять
  //    из шаблона = воскресить удалённое, поэтому только штампуем маркер.
  if (data['directions_migrated'] == true) {
    data['directions_migrated'] = true;
    // §408 — ветка «мигрировано-и-пусто»: Направлений НЕТ осознанно, значит
    // осиротела ВСЯ карта. Пусть уходит вместе с ними.
    _pruneOrphanPingGroups(data);
    SettingsStorage._cache = data;
    await _save();
    return;
  }

  // 3. Seed из template. Legacy-цепочка `enabled_groups[]` сохранена: старейшие
  //    установки имеют ТОЛЬКО её, и она задаёт enabled вместо defaultEnabled.
  final enabled = await SettingsStorage.getEnabledGroups(); // legacy set
  final hasAuto = gt.direction.include.contains('auto');
  final directions = <Direction>[];
  for (final dc in gt.defaultDirections) {
    final isEnabled = dc.tag == 'vpn-1'
        ? true // vpn-1 форсим (продуктовый инвариант)
        : (enabled.isEmpty ? dc.defaultEnabled : enabled.contains(dc.tag));
    final auto = hasAuto
        ? _seedAutoFromTemplate(gt.auto, varDefaults: varDefaults)
        : null;
    directions.add(
        Direction.seedFromDefault(dc, gt.direction, enabled: isEnabled, auto: auto));
  }

  data['directions'] = directions.map((c) => c.toJson()).toList();
  data['directions_migrated'] = true;
  _pruneOrphanPingGroups(data); // §408
  SettingsStorage._cache = data;
  await _save();
}

/// `DirectionAuto` из `group_templates.auto` (urltest-шаблон). ВНИМАНИЕ: `options`
/// здесь — СЫРОЙ template (`@urltest_*`-плейсхолдеры НЕ резолвены — var-
/// substitution идёт позже, в билдере). Поэтому значения могут быть
/// `"@urltest_tolerance"`-строкой, числом ИЛИ числом-в-строке. Парсим терпимо:
/// нерезолвенный `@`-плейсхолдер или мусор → [varDefaults] той же переменной.
///
/// §327 — на плейсхолдере раньше срабатывали литералы в коде (`50`, `'5m'`), и
/// в Направления на чистой установке садились значения, расходившиеся с шаблоном
/// (`urltest_tolerance: 30`, `urltest_interval: 15m`). Теперь `@var` резолвится
/// по `default_value` — единственному источнику дефолта.
/// idle_timeout="30m", interrupt=false (мягкий urltest) — своих var не имеют.
DirectionAuto _seedAutoFromTemplate(
  AutoTemplate at, {
  Map<String, String> varDefaults = const {},
}) {
  final opts = at.options;

  /// `"@urltest_x"` → `default_value` этой var (или null, если её нет).
  String? fromVar(Object? v) {
    if (v is! String || !v.startsWith('@')) return null;
    final d = varDefaults[v.substring(1)];
    return (d != null && d.isNotEmpty) ? d : null;
  }

  // Строка-значение, но не нерезолвенный `@var`-плейсхолдер.
  String? str(Object? v) {
    if (v is! String || v.isEmpty || v.startsWith('@')) return null;
    return v;
  }

  // tolerance из num / числа-в-строке; плейсхолдер/мусор → null.
  int? toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String && !v.startsWith('@')) return int.tryParse(v.trim());
    return null;
  }

  // Порядок: значение из template.options → default_value его `@var` →
  // дефолт `DirectionAuto` (последний рубеж, если var из шаблона исчезла).
  const fallback = DirectionAuto();
  return DirectionAuto(
    url: str(opts['url']) ?? fromVar(opts['url']) ?? fallback.url,
    interval: str(opts['interval']) ?? fromVar(opts['interval']) ?? fallback.interval,
    tolerance: toInt(opts['tolerance']) ??
        int.tryParse(fromVar(opts['tolerance']) ?? '') ??
        fallback.tolerance,
    idleTimeout: fallback.idleTimeout,
    interruptExistConnections: fallback.interruptExistConnections,
  );
}
