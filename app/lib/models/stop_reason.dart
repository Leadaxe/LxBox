/// §279 Phase 0 — типизированная причина аварийного стопа/revoke туннеля.
///
/// Native-wire остаётся строковым (`errorReason` события `Stopped` + флаг
/// `revoked`, Kotlin не трогается); разбор строкового протокола происходит
/// ОДИН раз при ingestion в HomeController. UI ветвится по типу (dialog для
/// [StopPermissionLocation], snackbar для остальных), а не по string-хирургии.
/// Неопознанные строки проходят как [StopError] verbatim (passthrough).
library;

import '../services/l10n/get_local_text.dart';
import '../services/l10n/locale_controller.dart';

sealed class StopReason {
  const StopReason();

  /// Wire-маркер §050 — `BoxService.stopAndAlert("alert:permission_location:…")`.
  static const _permissionLocationMarker = 'alert:permission_location:';

  /// Разбор stop-события. `null` — чистый user-stop (нет причины).
  static StopReason? fromEvent(
      {required bool revoked, required String? errorReason}) {
    if (revoked) return const StopRevoked();
    if (errorReason == null) return null;
    if (errorReason.contains(_permissionLocationMarker)) {
      return StopPermissionLocation(
        permissions:
            errorReason.replaceFirst(_permissionLocationMarker, '').trim(),
        raw: errorReason,
      );
    }
    return StopError(errorReason);
  }

  /// §285 — тело рендера подкласса. [t] — локализатор: активная локаль для
  /// [message], пиненный английский [GetLocalText.en] для [renderEn].
  /// Публичный — переиспользуется композицией из ui_msg.dart (пофайловая
  /// приватность Dart).
  String messageWith(GetLocalText t);

  /// §285 — рендер причины в момент показа (активная локаль).
  String message() => messageWith(getLocalText);

  /// Machine-рендер (Debug API `lastStartError`, AppLog) — пиненный английский.
  String renderEn() => messageWith(GetLocalText.en);

  List<Object?> get props => const [];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StopReason &&
          runtimeType == other.runtimeType &&
          _propsEqual(props, other.props));

  @override
  int get hashCode => Object.hashAll([runtimeType, ...props]);

  @override
  String toString() => '$runtimeType(${props.join(', ')})';
}

bool _propsEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// §276 — VPN-слот забрало другое приложение (native onRevoke).
final class StopRevoked extends StopReason {
  const StopRevoked();

  @override
  String messageWith(GetLocalText t) => t.s("Another VPN app took the system VPN slot (e.g. an always-on VPN). Start again to reconnect.");
}

/// §050 — стоп из-за отсутствующего location-permission (API 30+ требует
/// выдачу через Settings). UI показывает dialog с кнопкой Open Settings.
final class StopPermissionLocation extends StopReason {
  /// Comma-joined список permission'ов из native (payload для диалога).
  final String permissions;

  /// Полный errorReason verbatim — [message] обязан воспроизводить
  /// сегодняшнюю строку byte-в-byte (Debug API `lastStartError`).
  final String raw;

  const StopPermissionLocation({required this.permissions, required this.raw});

  @override
  List<Object?> get props => [permissions, raw];

  @override
  String messageWith(GetLocalText t) => t.s("Stopped: %s", raw);
}

/// Прочие причины стопа — диагностический passthrough native/kernel-строки.
final class StopError extends StopReason {
  final String detail;
  const StopError(this.detail);

  @override
  List<Object?> get props => [detail];

  @override
  String messageWith(GetLocalText t) => t.s("Stopped: %s", detail);
}
