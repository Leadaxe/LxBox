import 'package:flutter/widgets.dart';

/// §076 — Global `NavigatorObserver` который срабатывает когда home (root
/// route) снова становится top routes (юзер вернулся со всех settings
/// screens обратно).
///
/// Используется для lazy rebuild config'а: home_screen регистрирует
/// handler в `initState`, который при возврате юзера проверяет
/// `subController.configDirty` и запускает `_rebuildAndClearDirty` если
/// нужно.
///
/// Преимущество глобального observer'а перед `RouteObserver` + `RouteAware`:
///   - Не требует от каждого editing screen'а opt-in через mixin.
///   - Срабатывает на **любом** способе возврата (system back, swipe,
///     programmatic `Navigator.pop`, `popUntil`, drawer-driven jump).
///   - Cross-navigation между screens'ами не теряется: pop'ы не на home
///     не fire'ят handler, fire происходит ровно когда `isFirst` previous
///     route становится top'ом.
///
/// Singleton `homeReturnObserver` регистрируется в `MaterialApp.navigatorObservers`.
class HomeReturnObserver extends NavigatorObserver {
  VoidCallback? _handler;

  /// Установить callback. Один handler — home_screen регистрируется в
  /// `initState`, очищается в `dispose`.
  void setHandler(VoidCallback handler) {
    _handler = handler;
  }

  void clearHandler() {
    _handler = null;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    // previousRoute стал top после pop'а. Если он `isFirst` — это root
    // (home). Срабатывает только в этом случае, чтобы handler не fires
    // на pop'ах внутри cross-nav stack'а.
    if (previousRoute?.isFirst == true) {
      _handler?.call();
    }
  }
}

final HomeReturnObserver homeReturnObserver = HomeReturnObserver();
