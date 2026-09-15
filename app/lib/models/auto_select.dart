/// §322 — членство узла автовыбора и его параметры.
///
/// Вынесено из `node_spec.dart`: там 14 транспортных протоколов, а это —
/// правила отбора и настройки urltest, другая природа. `AutoSelectSpec`
/// живёт в `node_spec.dart` (он вариант sealed `NodeSpec`), а его начинка
/// здесь.
library;

import 'package:collection/collection.dart';

import 'direction.dart' show UrltestMode, StickyHashKey, kDefaultStickyHash;
import 'node_link.dart';

// ════════════════════════════════════════════════════════════════════════════
// Членство
// ════════════════════════════════════════════════════════════════════════════

/// Как узел автовыбора набирает пул. Три режима (§322 §3.1):
/// «все члены контейнера» = [RuleMembers] с пустым include.
sealed class AutoSelectMembership {
  const AutoSelectMembership();
}

/// Правило: include набирает, exclude вычитает. Оба — regex по итоговому тегу
/// узла И по его синонимам (§321 P6). Пустой include = все члены контейнера.
final class RuleMembers extends AutoSelectMembership {
  final String include;
  final String exclude;

  const RuleMembers({this.include = '', this.exclude = ''});

  /// §322 §3.2 — `selector: ["proxy","backup"]` → `^(proxy|backup)`.
  /// Xray матчит теги **префиксом** (документация routing.html), поэтому
  /// якорим в начало и экранируем спецсимволы: тег провайдера — литерал.
  factory RuleMembers.fromXraySelector(List<String> selector) {
    final parts = selector
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(RegExp.escape)
        .toList();
    if (parts.isEmpty) return const RuleMembers();
    return RuleMembers(include: '^(${parts.join('|')})');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RuleMembers &&
          include == other.include &&
          exclude == other.exclude);

  @override
  int get hashCode => Object.hash(include, exclude);
}

/// Явный список: пользователь отметил членов галочками. Хранит ссылки на
/// членов своего контейнера (D-112, NODE_LINK §2): [NodeLink.folderId] — `id`
/// папки, [NodeLink.tag] — сырой тег члена (до префикса папки). Финальный тег
/// вычисляет только сборка (`resolveAutoSelectMembers`).
///
/// У группы из тела подписки или многоузлового сервера `folderId` пуст: такой
/// член адресует свой контейнер (NODE_LINK §5.1 № 8), в хранение группа не
/// пишется — она производна от тела.
final class ExplicitMembers extends AutoSelectMembership {
  final List<NodeLink> members;

  const ExplicitMembers(this.members);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExplicitMembers &&
          const ListEquality<NodeLink>().equals(members, other.members));

  @override
  int get hashCode => const ListEquality<NodeLink>().hash(members);
}

/// §322 — regexp по умолчанию для `poolBadge`: первый флаг-эмодзи в имени
/// узла. Флаг — пара Regional Indicator Symbol (U+1F1E6…U+1F1FF), отсюда `{2}`.
const String kDefaultPoolBadge = r'[\u{1F1E6}-\u{1F1FF}]{2}';

// ════════════════════════════════════════════════════════════════════════════
// Параметры urltest
// ════════════════════════════════════════════════════════════════════════════

/// Верхняя граница `pool_tolerance` — ядро SPEC 019, device-verified (§208).
const int kMaxPoolTolerance = 15000;

/// Параметры автовыбора. Зеркалит `DirectionAuto` (§208), но живёт на узле:
/// у Направления это настройка выхода, здесь — суть самого узла.
class AutoSelectParams {
  final String url;
  final String interval;
  final int tolerance;
  final String idleTimeout;
  final UrltestMode mode;
  final int pool;
  final int poolTolerance;
  final List<StickyHashKey> stickyHash;

  /// §208 — рвать ли живые соединения при смене выбранного узла. Дефолт ядра
  /// `false`: старые соединения доживают на прежнем узле, новые открываются
  /// на новом. Эмитим всегда (как Направление), чтобы значение было видно в конфиге.
  final bool interruptExistConnections;

  const AutoSelectParams({
    this.url = 'https://cp.cloudflare.com/generate_204',
    this.interval = '15m',
    this.tolerance = 50,
    this.idleTimeout = '30m',
    this.mode = UrltestMode.leastTest,
    this.pool = 3,
    this.poolTolerance = 0,
    this.stickyHash = kDefaultStickyHash,
    this.interruptExistConnections = false,
  });

  AutoSelectParams copyWith({
    String? url,
    String? interval,
    int? tolerance,
    String? idleTimeout,
    UrltestMode? mode,
    int? pool,
    int? poolTolerance,
    List<StickyHashKey>? stickyHash,
    bool? interruptExistConnections,
  }) =>
      AutoSelectParams(
        url: url ?? this.url,
        interval: interval ?? this.interval,
        tolerance: tolerance ?? this.tolerance,
        idleTimeout: idleTimeout ?? this.idleTimeout,
        mode: mode ?? this.mode,
        pool: pool ?? this.pool,
        poolTolerance:
            poolTolerance == null ? this.poolTolerance : clampPoolTolerance(poolTolerance),
        stickyHash: stickyHash ?? this.stickyHash,
        interruptExistConnections:
            interruptExistConnections ?? this.interruptExistConnections,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AutoSelectParams &&
          url == other.url &&
          interval == other.interval &&
          tolerance == other.tolerance &&
          idleTimeout == other.idleTimeout &&
          mode == other.mode &&
          pool == other.pool &&
          poolTolerance == other.poolTolerance &&
          const ListEquality<StickyHashKey>()
              .equals(stickyHash, other.stickyHash) &&
          interruptExistConnections == other.interruptExistConnections);

  @override
  int get hashCode => Object.hash(url, interval, tolerance, idleTimeout, mode,
      pool, poolTolerance, const ListEquality<StickyHashKey>().hash(stickyHash),
      interruptExistConnections);

  /// Поля sing-box для `type: urltest`.
  ///
  /// §208 — балансировщик живёт во ВЛОЖЕННОМ `balancer{}` (ядро SPEC 019), а
  /// не плоско: плоские `pool`/`pool_tolerance` ядро отвергает как unknown
  /// field, и конфиг не стартует целиком. `balancer` без `round_robin` роняет
  /// старт так же — поэтому оба только под round_robin.
  ///
  /// §210 — пустой `sticky_hash` НЕ выключает липкость: ядро ре-маршалит
  /// конфиг и схлопывает `[]`→nil, неотличимо от «поле опущено» → дефолт
  /// `["process","domain"]`. Выключение — sentinel `["none"]`.
  Map<String, dynamic> toJson() => {
        'url': url,
        'interval': interval,
        'tolerance': tolerance,
        'idle_timeout': idleTimeout,
        'interrupt_exist_connections': interruptExistConnections,
        if (mode == UrltestMode.roundRobin) ...{
          'mode': mode.wire,
          'balancer': <String, dynamic>{
            'pool': pool,
            'pool_tolerance': poolTolerance,
            'sticky_hash': stickyHash.isEmpty
                ? const ['none']
                : stickyHash.map((k) => k.wire).toList(),
          },
        },
      };

}

int clampPoolTolerance(int v) => v < 0 ? 0 : (v > kMaxPoolTolerance ? kMaxPoolTolerance : v);

// ════════════════════════════════════════════════════════════════════════════
// Матчинг правила (§322 §3.1)
// ════════════════════════════════════════════════════════════════════════════

/// Проходит ли кандидат с именами [names] через include/exclude правила.
///
/// Единая точка для билдера (`resolveAutoSelectMembers`, матчит по итоговому
/// тегу и синонимам) и для превью в редакторе (матчит по видимому имени).
/// Раньше логика жила в обоих местах копиями — превью могло разойтись с тем,
/// что реально соберётся.
///
/// Правила уже скомпилированы: `null` = «не задано» (не «не совпало»), см.
/// инвариант в `safe_regex.dart`.
bool ruleAccepts(Iterable<String> names, RegExp? include, RegExp? exclude) {
  final hit = include == null || names.any(include.hasMatch);
  if (!hit) return false;
  return !(exclude != null && names.any(exclude.hasMatch));
}
