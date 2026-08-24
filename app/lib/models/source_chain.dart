// §393 C1 — источник-цепочка хопов (SPEC 110).
//
// Цепочка — это МАРШРУТ («клиент → хоп 1 → хоп 2 → … → цель»), а не точка
// ВЫБОРА между маршрутами. Поэтому она живёт третьим типом ИСТОЧНИКА рядом с
// подпиской и сервером, а Направлением не является (§393 L5 — лаунчер прошёл
// через неверную модель и переносил её, SPEC 110 «Ревизия»).
//
// Для остального приложения цепочка выглядит УЗЛОМ: попадает в общий пул,
// отбирается фильтрами Направлений наравне с серверами подписки, эмитится
// одним outbound'ом типа `chain`.
//
// Канон — `contract/schema/source_chain.schema.json`; эталон реализации —
// `configtypes.SourceChain` лаунчера. Имена полей повторяют ядро
// (`option.ChainOutboundOptions` форка, `option/chain_lx.go`) везде, кроме
// [hops]: ключ ядра `outbounds` рядом с составом группы читался бы как то же
// самое, а смысл у него другой (позиции маршрута, не взаимозаменяемые опции).
// В конфиг [hops] уходит именно под ключом `outbounds` — форма ядра неизменна.

import '../services/json_clone.dart' show deepCloneJson;

/// Значение поля `type` эмитируемого outbound'а. Ядро без тега сборки
/// `with_lx_chain` этот тип не знает и отвергает конфиг ЦЕЛИКОМ (§393 C5).
const String kChainOutboundType = 'chain';

// ── каталог strip ───────────────────────────────────────────────────────────
//
// Ключи каталога ядра (`protocol/chain/transform.go:24-27`). Список ЗАКРЫТ:
// неизвестный ключ ядро считает ошибкой старта, а не опечаткой, которую можно
// пропустить, — поэтому «на всякий случай» сюда добавлять нечего, новый ключ
// появляется только вместе с новой версией ядра.

const String kChainStripTlsFragment = 'tls.fragment';
const String kChainStripMultiplexPadding = 'multiplex.padding';
const String kChainStripXhttpPadding = 'xhttp.padding';
const String kChainStripTlsUtls = 'tls.utls';

/// Каталог `strip` В ПОРЯДКЕ ПОКАЗА В ФОРМЕ (эталон
/// `configtypes.ChainStripKeys`). Снимаемые по умолчанию идут первыми,
/// `tls.utls` — последним: он единственный не снимается по умолчанию и
/// единственный, снятие которого ломает reality-узлы (SPEC 110 T4).
///
/// Порядок нормативен и для ЭМИССИИ: объект `strip` обходится по этому
/// списку, а не по порядку ключей Map, — конфиг должен читаться одинаково
/// на обеих платформах.
const List<String> kChainStripKeys = [
  kChainStripTlsFragment,
  kChainStripMultiplexPadding,
  kChainStripXhttpPadding,
  kChainStripTlsUtls,
];

/// Снимается ли ключ при включённом `strip_evasion` — копия каталога ядра
/// (эталон `configtypes.ChainStripDefault`). Форма показывает по нему
/// исходное состояние галок.
const Map<String, bool> kChainStripDefault = {
  kChainStripTlsFragment: true,
  kChainStripMultiplexPadding: true,
  kChainStripXhttpPadding: true,
  kChainStripTlsUtls: false,
};

/// Источник-цепочка: маршрут через несколько позиций подряд.
///
/// Неизменяемая модель, как [Direction]: мутации идут через [copyWith], а
/// хранение — списком `chains[]` в `lxbox_settings.json` (§393 C2).
class SourceChain {
  const SourceChain({
    required this.tag,
    this.label = '',
    this.enabled = true,
    this.hops = const [],
    this.idleTimeout = '',
    this.stripEvasion,
    this.strip = const {},
    this.rewrite = const {},
  });

  /// Тег будущего outbound'а — он же id записи. Immutable после создания, как
  /// [Direction.tag]: на него ссылаются фильтры Направлений, `route_final` и
  /// позиции ДРУГИХ цепочек.
  final String tag;

  /// Отображаемое имя. Пусто → показываем [tag] (см. [displayLabel]).
  final String label;

  /// Выключенная цепочка не эмитится и не попадает в пул — как выключенная
  /// подписка. Ссылка на неё из другой цепочки деградирует ту цепочку
  /// целиком (`chain_hop_missing`), потому что маршрут без хопа — другой
  /// маршрут.
  final bool enabled;

  /// Позиции В ПОРЯДКЕ ПАКЕТА: `[0]` — первый хоп от клиента, последняя —
  /// та, чей адрес видит цель.
  ///
  /// НЕ «кто через кого»: у `detour` стрелка смотрит в обратную сторону, и
  /// перепутать их значит собрать РАБОТАЮЩИЙ, но не тот маршрут (SPEC 110
  /// T3) — ошибка, которую пользователь заметит только по геолокации.
  ///
  /// Позицией может быть узел, группа подписки, Направление, служебный тег
  /// шаблона или ДРУГАЯ ЦЕПОЧКА (только позицией 0 и только объявленная ВЫШЕ
  /// по списку — этим порядком исключены циклы между цепочками).
  ///
  /// Инварианты ядра (`protocol/chain/chain.go:85-100`): минимум две
  /// позиции, непустые, без повторов, без ссылки на саму цепочку. Нарушение
  /// ЛЮБОГО не даёт стартовать ВСЕМУ конфигу, а не одной цепочке, — поэтому
  /// проверяет их [chainEmitError], и не прошедшая цепочка не эмитится вовсе.
  final List<String> hops;

  /// Простой, после которого звено без живых соединений удаляется.
  /// Пусто = умолчание ядра (5m), `"0s"` = жить до остановки.
  final String idleTimeout;

  /// Снимать ли у звеньев односторонние приёмы обхода DPI.
  ///
  /// Nullable ради ТРЁХЗНАЧНОСТИ, а не «для красоты»: `null` = «умолчание
  /// ядра» (true, ключ в конфиг не пишется), `false` = «пользователь
  /// выключил явно» (ключ пишется). Обычный bool не отличил бы одно от
  /// другого, и явное выключение молча превращалось бы в умолчание при
  /// смене дефолта ядра. Та же причина, что у `interrupt_exist_connections`
  /// лаунчера.
  final bool? stripEvasion;

  /// Точечный патч поверх [stripEvasion]: `false` — не снимать, `true` —
  /// снимать дополнительно. Ключи ТОЛЬКО из [kChainStripKeys].
  final Map<String, bool> strip;

  /// JSON merge-patch (RFC 7396) поверх опций узла, ключ — тип outbound'а.
  /// Применяется к звеньям (позиции со второй) после strip.
  ///
  /// Формой не правится и правиться не должен: произвольный патч по всем
  /// типам протоколов урезанная форма молча потеряла бы. `null`-значение
  /// внутри патча УДАЛЯЕТ ключ (RFC 7396) — поэтому хранится и переживает
  /// round-trip как есть, без «чистки пустого».
  final Map<String, dynamic> rewrite;

  /// Имя для показа. Пустой label → сам тег: выдумывать имя цепочке, которую
  /// пользователь не назвал, значило бы врать о её содержимом.
  String get displayLabel => label.isNotEmpty ? label : tag;

  /// Умолчание ядра: отсутствие ключа = true.
  bool get stripEvasionEnabled => stripEvasion ?? true;

  SourceChain copyWith({
    String? label,
    bool? enabled,
    List<String>? hops,
    String? idleTimeout,
    bool? stripEvasion,
    bool clearStripEvasion = false,
    Map<String, bool>? strip,
    Map<String, dynamic>? rewrite,
  }) =>
      SourceChain(
        tag: tag, // immutable — не параметр copyWith (как у Direction)
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
        hops: hops ?? this.hops,
        idleTimeout: idleTimeout ?? this.idleTimeout,
        stripEvasion:
            clearStripEvasion ? null : (stripEvasion ?? this.stripEvasion),
        strip: strip ?? this.strip,
        rewrite: rewrite ?? this.rewrite,
      );

  /// Разбор записи storage / канона схемы.
  ///
  /// Терпимо к мусору на ЧТЕНИИ (правленый файл, restore из чужого бэкапа,
  /// Debug API): не-строки в [hops] и неизвестные ключи [strip] отсеиваются
  /// здесь, а не разгребаются билдером. Но отсеивается только то, что не
  /// имеет смысла: пустая после trim позиция и дубль остаются — их ловит
  /// [chainEmitError] и деградирует цепочку ЦЕЛИКОМ с внятной причиной,
  /// потому что молча «починенный» маршрут — это другой маршрут.
  factory SourceChain.fromJson(Map<String, dynamic> json) {
    final tag = (json['tag'] as String? ?? '').trim();
    return SourceChain(
      tag: tag,
      label: json['label'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      hops: [
        for (final h in (json['hops'] as List? ?? const []))
          if (h is String) h,
      ],
      idleTimeout: json['idle_timeout'] as String? ?? '',
      // Трёхзначность: ключа нет → null (умолчание ядра), не-bool → тоже
      // null (мусор не должен читаться как явное выключение).
      stripEvasion: json['strip_evasion'] is bool
          ? json['strip_evasion'] as bool
          : null,
      strip: {
        for (final key in kChainStripKeys)
          if ((json['strip'] as Map?)?[key] is bool)
            key: (json['strip'] as Map)[key] as bool,
      },
      rewrite: (deepCloneJson(json['rewrite']) as Map?)?.cast<String, dynamic>() ??
          const {},
    );
  }

  /// Запись в storage. Round-trip обязан быть точным: `strip_evasion`
  /// пишется, ТОЛЬКО когда пользователь высказался (null = умолчание ядра),
  /// пустые каталоги ключа не создают — иначе умолчание и явный выбор стали
  /// бы неотличимы уже в файле.
  Map<String, dynamic> toJson() => {
        'tag': tag,
        'label': label,
        'enabled': enabled,
        'hops': hops,
        if (idleTimeout.isNotEmpty) 'idle_timeout': idleTimeout,
        if (stripEvasion != null) 'strip_evasion': stripEvasion,
        if (strip.isNotEmpty)
          'strip': {
            for (final key in kChainStripKeys)
              if (strip.containsKey(key)) key: strip[key],
          },
        if (rewrite.isNotEmpty) 'rewrite': deepCloneJson(rewrite),
      };
}

/// §393 C1 — почему цепочку [c] нельзя выпустить в конфиг; пусто = можно.
/// Порт `ChainEmitError` лаунчера (`core/config/chain_generator.go:54`,
/// код реестра `chain_invalid`).
///
/// Проверяются РОВНО инварианты ядра и в тех же словах: сообщение уезжает
/// пользователю, а сверять его с чужим текстом ошибки ядра тому, кто читает
/// лог, невозможно. Каждое из этих условий не даёт стартовать ВСЕМУ конфигу
/// (`protocol/chain/chain.go:85-100`), поэтому не прошедшая цепочка не
/// становится узлом вовсе: отдать её ядру «пусть само разберётся» значило бы
/// оставить пользователя без VPN, а не без одного маршрута.
String chainEmitError(SourceChain c) {
  final hops = c.hops;
  if (hops.isEmpty) return 'chain is empty: no positions set';
  if (hops.length < 2) {
    return 'chain has a single position: the core needs at least two';
  }
  final seen = <String>{};
  for (var i = 0; i < hops.length; i++) {
    final hop = hops[i];
    if (hop.trim().isEmpty) return 'position ${i + 1} is empty';
    if (hop == c.tag) return 'position ${i + 1} references the chain itself';
    if (!seen.add(hop)) return 'position ${i + 1} repeats "$hop"';
  }
  for (final typeName in c.rewrite.keys) {
    if (typeName.trim().isEmpty) return 'rewrite: empty outbound type name';
  }
  for (final key in c.strip.keys) {
    if (!kChainStripDefault.containsKey(key)) {
      return 'strip: unknown key "$key" '
          '(allowed: ${kChainStripKeys.join(', ')})';
    }
  }
  return '';
}

/// §393 C3 — sing-box outbound типа `chain` для цепочки [c].
/// Порт `ChainOutboundObject` лаунчера (`chain_generator.go:96`).
///
/// Ключ ядра — `outbounds`, наше поле — [SourceChain.hops] (см. комментарий у
/// типа). Порядок позиций сохраняется дословно: это порядок ПАКЕТА, и
/// сортировка/дедуп здесь были бы не нормализацией, а сменой маршрута.
Map<String, dynamic> chainOutboundObject(SourceChain c) => {
      'tag': c.tag,
      'type': kChainOutboundType,
      'outbounds': [...c.hops],
      if (c.idleTimeout.trim().isNotEmpty) 'idle_timeout': c.idleTimeout.trim(),
      if (c.stripEvasion != null) 'strip_evasion': c.stripEvasion,
      if (c.strip.isNotEmpty)
        'strip': {
          // По каталогу, а не по порядку ключей Map: для ядра он не важен,
          // а для читаемости конфига и сверки с лаунчером — важен.
          for (final key in kChainStripKeys)
            if (c.strip.containsKey(key)) key: c.strip[key],
        },
      if (c.rewrite.isNotEmpty) 'rewrite': deepCloneJson(c.rewrite),
    };

/// §393 C1 — первый свободный `chain-N` среди [usedTags]. Тот же приём, что
/// [nextDirectionTag]: первая свободная позиция, а не «максимум + 1», — после
/// удаления средней цепочки номера не должны уползать вверх.
String nextChainTag(Iterable<String> usedTags) {
  final used = usedTags.toSet();
  for (var i = 1;; i++) {
    final tag = 'chain-$i';
    if (!used.contains(tag)) return tag;
  }
}
