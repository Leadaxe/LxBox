/// §613 (ядро SPEC 114) — вердикт по пирам WG/AWG-узла из ответа
/// `GetWireGuardStatus`. Ядро вердикта «на связи» не выносит: его выводит
/// потребитель по `endpointState`, возрасту хендшейка и росту rx между
/// опросами (руководство ядра `114-WG_PEER_STATUS/CONSUMERS.md` §2, §3.6).
library;

import '../vpn/cc_channel.dart';
import 'l10n/locale_controller.dart';

/// Время жизни ключа сессии WireGuard (`reject_after_time`), секунды.
const int kWgRejectAfterDefault = 180;

/// Интервал опроса статуса, пока окно узла открыто.
const Duration kWgStatusPollInterval = Duration(seconds: 2);

/// Состояния узла, при которых показывается секция пиров.
bool wgPeersSectionVisible(String endpointState) =>
    endpointState == CcEndpointState.up ||
    endpointState == CcEndpointState.asleep ||
    endpointState == CcEndpointState.disabled;

/// Порог «сессия действует»: верхняя граница `reject_after_time` тела узла
/// (число или диапазон `"min-max"`), без поля — [kWgRejectAfterDefault].
int wgRejectAfterSeconds(Map<String, dynamic>? body) {
  final v = body?['reject_after_time'];
  if (v is num && v > 0) return v.toInt();
  if (v is String) {
    final upper = int.tryParse(v.trim().split('-').last.trim());
    if (upper != null && upper > 0) return upper;
  }
  return kWgRejectAfterDefault;
}

/// Прежние значения rx по ключу пира — признак «rx растёт» между опросами.
/// Значение меньше прежнего (пересборка устройства обнулила счётчики) —
/// новая база, а не рост.
class WgRxTracker {
  final Map<String, int> _last = {};

  /// Запоминает [rx] пира и отвечает, вырос ли он с прошлого опроса.
  bool grew(String publicKey, int rx) {
    final prev = _last[publicKey];
    _last[publicKey] = rx;
    return prev != null && rx > prev;
  }
}

enum WgPeerVerdictKind {
  /// Сессия действует.
  connected,

  /// Хендшейк старше порога, rx стоит.
  noSession,

  /// Хендшейка не было с момента сборки устройства.
  neverConnected,

  /// Узел спит: время хендшейка — с момента до сна.
  asleep,

  /// Узел выключен вручную (SPEC 106).
  disabled,
}

class WgPeerVerdict {
  const WgPeerVerdict(this.kind, [this.ageSeconds = 0]);

  final WgPeerVerdictKind kind;

  /// Возраст хендшейка для [WgPeerVerdictKind.noSession].
  final int ageSeconds;

  @override
  bool operator ==(Object other) =>
      other is WgPeerVerdict &&
      other.kind == kind &&
      other.ageSeconds == ageSeconds;

  @override
  int get hashCode => Object.hash(kind, ageSeconds);

  @override
  String toString() => 'WgPeerVerdict($kind, $ageSeconds)';
}

/// Вердикт по пиру: таблица §2 руководства ядра для `up`, §3.6 — для
/// `asleep`/`disabled`. [rxGrew] — rx вырос с прошлого опроса.
WgPeerVerdict wgPeerVerdict({
  required String endpointState,
  required CcWireGuardPeer peer,
  required bool rxGrew,
  required int nowUnix,
  int rejectAfterSeconds = kWgRejectAfterDefault,
}) {
  if (endpointState == CcEndpointState.disabled) {
    return const WgPeerVerdict(WgPeerVerdictKind.disabled);
  }
  if (endpointState == CcEndpointState.asleep) {
    return const WgPeerVerdict(WgPeerVerdictKind.asleep);
  }
  if (peer.lastHandshakeUnix <= 0) {
    return const WgPeerVerdict(WgPeerVerdictKind.neverConnected);
  }
  final age = nowUnix - peer.lastHandshakeUnix;
  final ageSeconds = age < 0 ? 0 : age;
  if (ageSeconds <= rejectAfterSeconds || rxGrew) {
    return const WgPeerVerdict(WgPeerVerdictKind.connected);
  }
  return WgPeerVerdict(WgPeerVerdictKind.noSession, ageSeconds);
}

/// Возраст хендшейка: `42 s ago` / `3 min ago` / `2 h ago`; `0` — `never`.
String wgHandshakeAgeLabel(int lastHandshakeUnix, int nowUnix) {
  if (lastHandshakeUnix <= 0) return getLocalText.s("never");
  return wgAgeLabel(nowUnix - lastHandshakeUnix);
}

/// Возраст в секундах подписью `42 s ago` / `3 min ago` / `2 h ago`.
String wgAgeLabel(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  if (s < 60) return getLocalText.s("%s s ago", '$s');
  if (s < 3600) return getLocalText.s("%s min ago", '${s ~/ 60}');
  return getLocalText.s("%s h ago", '${s ~/ 3600}');
}

String wgPeerVerdictLabel(WgPeerVerdict v) => switch (v.kind) {
  WgPeerVerdictKind.connected => getLocalText.s("connected"),
  WgPeerVerdictKind.neverConnected => getLocalText.s("never connected"),
  WgPeerVerdictKind.noSession => getLocalText.s(
    "no active session (last handshake %s)",
    wgAgeLabel(v.ageSeconds),
  ),
  WgPeerVerdictKind.asleep => getLocalText.s("asleep"),
  WgPeerVerdictKind.disabled => getLocalText.s("turned off manually"),
};

/// Строка секции при пустом списке пиров — по `endpointState` (§3.6).
String wgEmptyPeersLabel(String endpointState) => switch (endpointState) {
  CcEndpointState.neverBuilt => getLocalText.s("not started"),
  CcEndpointState.building => getLocalText.s("starting"),
  CcEndpointState.asleep ||
  CcEndpointState.tornDown => getLocalText.s("asleep"),
  CcEndpointState.disabled => getLocalText.s("turned off manually"),
  CcEndpointState.down => getLocalText.s("stopped"),
  _ => getLocalText.s("No peers"),
};
