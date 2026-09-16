/// §453 — TCP keep-alive dial-поля sing-box (ядро ≥ 1.13).
///
/// Живёт на базовом [NodeSpec], а не в каждом `*Spec`: в ядре это часть
/// `DialerOptions`, общей для всех outbound'ов с TCP-дозвоном, а не свойство
/// протокола. `null` вместо spec'а = поля не заданы, эмит ничего не пишет и
/// узел остаётся на дефолтах ядра (первая проба через 5 мин, дальше каждые
/// 75 с — `constant/timeout.go`).
final class TcpKeepAliveSpec {
  /// `disable_tcp_keep_alive` — keep-alive на сокете выключен совсем.
  final bool disabled;

  /// `tcp_keep_alive` — Go-duration («30s»); '' = дефолт ядра.
  final String idle;

  /// `tcp_keep_alive_interval` — Go-duration; '' = дефолт ядра.
  final String interval;

  const TcpKeepAliveSpec({
    this.disabled = false,
    this.idle = '',
    this.interval = '',
  });

  /// Нечего эмитить. Парсеры возвращают `null` вместо такого spec'а, чтобы
  /// узлы без полей давали байт-в-байт прежний emit.
  bool get isEmpty => !disabled && idle.isEmpty && interval.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TcpKeepAliveSpec &&
          other.disabled == disabled &&
          other.idle == idle &&
          other.interval == interval;

  @override
  int get hashCode => Object.hash(disabled, idle, interval);

  @override
  String toString() =>
      'TcpKeepAliveSpec(disabled: $disabled, idle: $idle, interval: $interval)';
}
