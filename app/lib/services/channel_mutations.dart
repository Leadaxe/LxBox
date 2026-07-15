import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import 'settings_storage.dart';

/// §275 — единственная точка мутации каналов для кода приложения.
///
/// Инвариант §248: storage-heal detour-ссылок ОБЯЗАН зеркалиться в in-memory
/// `_entries` контроллера — storage уже вылечен, но `_entries` живёт с init(),
/// и без сброса следующий `_persist()` (rename, toggle члена, авто-refresh)
/// воскресил бы вылеченную ссылку на диске, а `generateConfig()` собрал бы
/// конфиг с ней вопреки показанному юзеру уведомлению.
///
/// Инвариант держался на внимательности в каждом call-site и разъехался:
/// `POST /channels` лечил storage и не зеркалил (heal отменялся следующим
/// persist'ом). Нарушение невидимо — storage корректен, тесты зелёные,
/// расходится только зеркало, а стреляет через несвязанный `_persist()`
/// позже, поэтому ревью его структурно не ловит.
///
/// Здесь heal и ресинк — одна операция, разделить их вызывающий не может.
/// Голые `SettingsStorage.updateChannel/deleteChannel` помечены
/// `@visibleForTesting`: новый вызов из `lib/` теперь жёлтый в IDE и красный
/// в CI-analyze (гоняется на весь проект), то есть «забыл» ловится сразу,
/// а не тихо потом.
///
/// Чего класс НЕ закрывает (осознанно):
/// - `SettingsStorage.setChannels` — сырой bulk-overwrite мимо heal'а;
/// - `sub == null` (контроллер ещё не готов) — ресинк молча пропускается,
///   это законно: без контроллера нет и `_entries`, которые расходятся;
/// - третий род ссылки на канал, буде появится, — против него работает
///   только коммент-инвариант в `server_list.dart`.
class ChannelMutations {
  const ChannelMutations._();

  /// Создать канал. Heal'ов не даёт (новый тег ни на что не ссылается),
  /// поэтому [ChannelHealResult] не возвращает — симметрия с
  /// `SettingsStorage.addChannel`.
  ///
  /// throws [StateError] при лимите `kMaxChannels`.
  static Future<Channel> add({String? label}) =>
      // ignore: invalid_use_of_visible_for_testing_member
      SettingsStorage.addChannel(label: label);

  /// Сохранить канал + зеркальный ресинк. [sub] — контроллер (nullable:
  /// Debug API может отработать до готовности UI).
  ///
  /// throws [StateError] если канала нет в storage.
  static Future<ChannelHealResult> update(
    Channel channel,
    SubscriptionController? sub,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final healed = await SettingsStorage.updateChannel(channel);
    _resync(healed, channel.tag, sub);
    return healed;
  }

  /// Удалить канал + зеркальный ресинк.
  ///
  /// throws [StateError] на vpn-1 (неудаляем).
  static Future<ChannelHealResult> delete(
    String tag,
    SubscriptionController? sub,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final healed = await SettingsStorage.deleteChannel(tag);
    _resync(healed, tag, sub);
    return healed;
  }

  /// Ресинк идемпотентен (`clearDetourChannelRefs` → `healed == null`, когда
  /// чистить нечего), но гейт по счётчику оставлен: он документирует связь
  /// «storage вылечил N ссылок → зеркалим ровно этот tag».
  static void _resync(
    ChannelHealResult healed,
    String tag,
    SubscriptionController? sub,
  ) {
    if (healed.detours > 0) sub?.syncDetourChannelRefsCleared(tag);
  }
}
