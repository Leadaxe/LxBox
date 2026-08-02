/// §322 — членство узла автовыбора и его параметры.
///
/// Вынесено из `node_spec.dart`: там 14 транспортных протоколов, а это —
/// правила отбора и настройки urltest, другая природа. `AutoSelectSpec`
/// живёт в `node_spec.dart` (он вариант sealed `NodeSpec`), а его начинка
/// здесь.
library;

import 'channel.dart' show UrltestMode, StickyHashKey, kDefaultStickyHash;

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
}

/// Явный список: пользователь отметил членов галочками. Хранит §321-идентичности
/// (`protocol|server|port|credential`), НЕ теги — тег локален для элемента
/// подписки и после дедупа не сохраняется.
final class ExplicitMembers extends AutoSelectMembership {
  final List<String> keys;

  const ExplicitMembers(this.keys);
}

// ════════════════════════════════════════════════════════════════════════════
// URI-форма (§322 §7)
// ════════════════════════════════════════════════════════════════════════════

/// §322 — regexp по умолчанию для `poolBadge`: первый флаг-эмодзи в имени
/// узла. Флаг — пара Regional Indicator Symbol (U+1F1E6…U+1F1FF), отсюда `{2}`.
const String kDefaultPoolBadge = r'[\u{1F1E6}-\u{1F1FF}]{2}';

/// Схема синтетического URI узла автовыбора.
///
/// Формы `autogroup://` в природе не существует — она нужна, чтобы группа
/// хранилась в папке тем же механизмом, что обычные члены (`FolderMember.raw`
/// → парсинг при загрузке). Это НЕ переносимая ссылка: правило внутри
/// написано под состав своей папки, вставленное в чужую оно наберёт другие
/// узлы. UI не даёт её скопировать (§2).
const String kAutoGroupScheme = 'autogroup';

/// `autogroup://?name=…&include=…&mode=…#Label`
///
/// Пустые и дефолтные параметры не пишем — URI остаётся читаемым, а `fromUri`
/// подставит те же дефолты из [AutoSelectParams].
String autoGroupToUri(
  String label,
  AutoSelectMembership membership,
  AutoSelectParams params, [
  String poolBadge = kDefaultPoolBadge,
]) {
  const d = AutoSelectParams();
  final q = <String, String>{};

  switch (membership) {
    case ExplicitMembers(:final keys):
      // §352 — ключ = `protocol|server|port|credential`, а credential может
      // нести запятую (пароль ss/trojan) — сырой join(',') ломал раскрой на
      // fromUri, член молча выпадал после рестарта. Экранируем per-key.
      q['members'] = keys.map(_escapeMemberKey).join(',');
    case RuleMembers(:final include, :final exclude):
      if (include.isNotEmpty) q['include'] = include;
      if (exclude.isNotEmpty) q['exclude'] = exclude;
  }

  if (params.mode != d.mode) q['mode'] = params.mode.wire;
  if (params.url != d.url) q['url'] = params.url;
  if (params.interval != d.interval) q['interval'] = params.interval;
  if (params.tolerance != d.tolerance) q['tolerance'] = '${params.tolerance}';
  if (params.idleTimeout != d.idleTimeout) q['idle_timeout'] = params.idleTimeout;
  if (params.interruptExistConnections != d.interruptExistConnections) {
    q['interrupt'] = '1';
  }
  if (params.mode == UrltestMode.roundRobin) {
    q['pool'] = '${params.pool}';
    if (params.poolTolerance != d.poolTolerance) {
      q['pool_tolerance'] = '${params.poolTolerance}';
    }
    q['sticky'] = params.stickyHash.map((k) => k.wire).join(',');
  }

  // §322 — UI-only: в конфиг не уходит, но храниться должен (это настройка
  // пользователя). Дефолт не пишем — короче URI.
  if (poolBadge != kDefaultPoolBadge) q['badge'] = poolBadge;

  final query = q.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  final frag = label.isEmpty ? '' : '#${Uri.encodeComponent(label)}';
  return '$kAutoGroupScheme://?$query$frag';
}

/// §352 — узкое экранирование ключа-члена для `members=`-списка: только
/// разделитель `,` и сам escape-символ `%`. НЕ Uri.encodeComponent: полный
/// percent-decode на fromUri бросал бы ArgumentError на легаси-ключах с
/// голым `%` в credential. Старые URI с чистыми ключами (без `%`/`,`)
/// проходят unescape как есть — миграция не нужна; ключи с запятой и до
/// §352 были битыми (член выпадал), рабочих состояний не регрессируем.
String _escapeMemberKey(String k) =>
    k.replaceAll('%', '%25').replaceAll(',', '%2C');

String _unescapeMemberKey(String k) =>
    k.replaceAll('%2C', ',').replaceAll('%25', '%');

/// Разбор `autogroup://`. `null` — не наша схема.
///
/// Отсутствие `members` означает режим правила: пустые `include`/`exclude` —
/// это «все члены контейнера», валидная конфигурация.
({
  String label,
  AutoSelectMembership membership,
  AutoSelectParams params,
  String poolBadge,
})? autoGroupFromUri(String raw) {
  final s = raw.trim();
  if (!s.toLowerCase().startsWith('$kAutoGroupScheme://')) return null;
  final uri = Uri.tryParse(s);
  if (uri == null) return null;

  final q = uri.queryParameters;
  const d = AutoSelectParams();

  final rawMembers = q['members'];
  final membership = rawMembers != null
      ? ExplicitMembers(rawMembers
          .split(',')
          .map((e) => _unescapeMemberKey(e.trim()))
          .where((e) => e.isNotEmpty)
          .toList())
      : RuleMembers(
          include: q['include'] ?? '',
          exclude: q['exclude'] ?? '',
        );

  final sticky = q['sticky'];
  final params = AutoSelectParams(
    url: q['url'] ?? d.url,
    interval: q['interval'] ?? d.interval,
    tolerance: int.tryParse(q['tolerance'] ?? '') ?? d.tolerance,
    idleTimeout: q['idle_timeout'] ?? d.idleTimeout,
    interruptExistConnections: q['interrupt'] == '1',
    mode: UrltestMode.fromWire(q['mode']),
    pool: int.tryParse(q['pool'] ?? '') ?? d.pool,
    poolTolerance:
        clampPoolTolerance(int.tryParse(q['pool_tolerance'] ?? '') ?? d.poolTolerance),
    // Пустая строка ≠ отсутствие: `sticky=` — осознанно снятые чипы, и
    // эмиссия превратит их в sentinel ["none"] (§208/§210).
    stickyHash: sticky == null
        ? d.stickyHash
        : sticky
            .split(',')
            .map((k) => StickyHashKey.fromWire(k.trim()))
            .whereType<StickyHashKey>()
            .toList(),
  );

  return (
    label: Uri.decodeComponent(uri.fragment),
    membership: membership,
    params: params,
    poolBadge: q['badge'] ?? kDefaultPoolBadge,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// Параметры urltest
// ════════════════════════════════════════════════════════════════════════════

/// Верхняя граница `pool_tolerance` — ядро SPEC 019, device-verified (§208).
const int kMaxPoolTolerance = 15000;

/// Параметры автовыбора. Зеркалит `ChannelAuto` (§208), но живёт на узле:
/// у канала это настройка выхода, здесь — суть самого узла.
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
  /// на новом. Эмитим всегда (как канал), чтобы значение было видно в конфиге.
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
