import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import 'l10n/locale_controller.dart';
import 'settings_storage.dart';

/// §275 — единственная точка мутации Направлений для кода приложения.
///
/// Инвариант §248: storage-heal detour-ссылок ОБЯЗАН зеркалиться в in-memory
/// `_entries` контроллера — storage уже вылечен, но `_entries` живёт с init(),
/// и без сброса следующий `_persist()` (rename, toggle члена, авто-refresh)
/// воскресил бы вылеченную ссылку на диске, а `generateConfig()` собрал бы
/// конфиг с ней вопреки показанному юзеру уведомлению.
///
/// Инвариант держался на внимательности в каждом call-site и разъехался:
/// `POST /directions` лечил storage и не зеркалил (heal отменялся следующим
/// persist'ом). Нарушение невидимо — storage корректен, тесты зелёные,
/// расходится только зеркало, а стреляет через несвязанный `_persist()`
/// позже, поэтому ревью его структурно не ловит.
///
/// Здесь heal и ресинк — одна операция, разделить их вызывающий не может.
/// Голые `SettingsStorage.updateDirection/deleteDirection` помечены
/// `@visibleForTesting`: новый вызов из `lib/` теперь жёлтый в IDE и красный
/// в CI-analyze (гоняется на весь проект), то есть «забыл» ловится сразу,
/// а не тихо потом.
///
/// Чего класс НЕ закрывает (осознанно):
/// - bulk-overwrite (`setDirections`) heal не даёт — но проходит через явный
///   `bulkReplace` (§292), чтобы `setDirections` тоже стал `@visibleForTesting`;
/// - `sub == null` (контроллер ещё не готов) — ресинк молча пропускается,
///   это законно: без контроллера нет и `_entries`, которые расходятся;
/// - третий род ссылки на Направление, буде появится, — против него работает
///   только коммент-инвариант в `server_list.dart`.
class DirectionMutations {
  const DirectionMutations._();

  /// Создать Направление. Heal'ов не даёт (новый тег ни на что не ссылается),
  /// поэтому [DirectionHealResult] не возвращает — симметрия с
  /// `SettingsStorage.addDirection`.
  ///
  /// throws [StateError] при лимите `kMaxDirections`.
  static Future<Direction> add({String? label}) =>
      // ignore: invalid_use_of_visible_for_testing_member
      SettingsStorage.addDirection(label: label);

  /// Сохранить Направление + зеркальный ресинк. [sub] — контроллер (nullable:
  /// Debug API может отработать до готовности UI).
  ///
  /// throws [StateError] если Направления нет в storage.
  static Future<DirectionHealResult> update(
    Direction direction,
    SubscriptionController? sub,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final healed = await SettingsStorage.updateDirection(direction);
    _resync(healed, direction.tag, sub);
    return healed;
  }

  /// Удалить Направление + зеркальный ресинк.
  ///
  /// throws [StateError] на vpn-1 (неудаляем).
  static Future<DirectionHealResult> delete(
    String tag,
    SubscriptionController? sub,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final healed = await SettingsStorage.deleteDirection(tag);
    _resync(healed, tag, sub);
    return healed;
  }

  /// §292 — bulk-перезапись всего списка Направлений БЕЗ heal'а. Явный heal-free
  /// путь для трёх легитимных call-site'ов, которые не могут повесить ссылку:
  ///   • routing_screen — уже застейдженный список (heal сделан ранее по мутации);
  ///   • routing_srs_cache — staging-буфер экрана (flush mixin'ом на dispose);
  ///   • debug /directions reorder — тот же набор тегов, только порядок.
  /// Существование этого метода позволяет пометить `SettingsStorage.setDirections`
  /// `@visibleForTesting` (§275): голый bulk-overwrite из `lib/` теперь красный
  /// в CI, а осознанно heal-free случай проходит через названный вход.
  static Future<void> bulkReplace(
    List<Direction> directions, {
    bool flush = true,
  }) =>
      // ignore: invalid_use_of_visible_for_testing_member
      SettingsStorage.setDirections(directions, flush: flush);

  /// §292 — локализованные части heal-сообщения из [DirectionHealResult].
  /// Единый источник строк «N rule reference(s) switched to vpn-1» /
  /// «M detour reference(s) reset to None» — раньше дублировались дословно в
  /// `routing_screen._notifyHealed` (сырые строки) и `node_list` (l10n). Обе
  /// части нулевые → пустой список (call-site решает, показывать ли SnackBar).
  /// Обрамление (lead / join-разделитель) остаётся за call-site'ом.
  static List<String> healMessageParts(DirectionHealResult healed) => [
        if (healed.rules > 0)
          getLocalText.s(
              '%s rule reference(s) switched to vpn-1', '${healed.rules}'),
        if (healed.detours > 0)
          getLocalText.s(
              '%s detour reference(s) reset to None', '${healed.detours}'),
      ];

  /// Ресинк идемпотентен (`clearDetourDirectionRefs` → `healed == null`, когда
  /// чистить нечего), но гейт по счётчику оставлен: он документирует связь
  /// «storage вылечил N ссылок → зеркалим ровно этот tag».
  static void _resync(
    DirectionHealResult healed,
    String tag,
    SubscriptionController? sub,
  ) {
    if (healed.detours > 0) sub?.syncDetourDirectionRefsCleared(tag);
  }
}
