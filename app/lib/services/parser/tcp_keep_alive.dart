import '../../models/tcp_keep_alive_spec.dart';
import 'uri_utils.dart';

/// §453 — разбор и запись TCP keep-alive dial-полей во всех трёх формах, в
/// которых у нас ходит узел: sing-box JSON, share-URI, Xray JSON.
///
/// Один модуль на все формы — как `transport.dart` с `transportToQuery`:
/// имена ключей и guard на duration должны совпадать во всех точках, иначе
/// round-trip (`parseUri(spec.toUri())`) начнёт терять поля.

/// Go-duration: последовательность «число + единица» (`1h30m`, `30s`,
/// `500ms`). Вне этой формы `badoption.Duration` роняет разбор ВСЕГО конфига,
/// поэтому такое значение отбрасывается на входе.
final _goDuration = RegExp(r'^(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$');

/// Нормализация + guard: голое число → секунды (D-024), затем проверка на
/// Go-duration. Не прошло — пусто; соседние поля это не затрагивает.
String _duration(String raw) {
  final v = normalizeSingboxDuration(raw.trim());
  if (v.isEmpty) return '';
  return _goDuration.hasMatch(v) ? v : '';
}

/// sing-box outbound JSON → spec. `null`, если полей нет: узлы без них дают
/// прежний emit байт-в-байт.
TcpKeepAliveSpec? tcpKeepAliveFromSingbox(Map entry) {
  final s = TcpKeepAliveSpec(
    disabled: entry['disable_tcp_keep_alive'] == true,
    // `toString()` а не каст: ручная правка JSON заносит duration и числом
    // (`"tcp_keep_alive": 30`), и `as String` уронил бы весь узел.
    idle: _duration(entry['tcp_keep_alive']?.toString() ?? ''),
    interval: _duration(entry['tcp_keep_alive_interval']?.toString() ?? ''),
  );
  return s.isEmpty ? null : s;
}

/// spec → sing-box outbound JSON. Пишет только непустое: `disabled: false` и
/// пустые duration'ы ключей не рождают.
void tcpKeepAliveToSingbox(Map<String, dynamic> out, TcpKeepAliveSpec? s) {
  if (s == null) return;
  if (s.disabled) out['disable_tcp_keep_alive'] = true;
  if (s.idle.isNotEmpty) out['tcp_keep_alive'] = s.idle;
  if (s.interval.isNotEmpty) out['tcp_keep_alive_interval'] = s.interval;
}

/// share-URI query → spec. Имена параметров = имена ключей sing-box.
/// Стандарта у share-URI нет, это расширение L×Box по прецеденту AnyTLS
/// (§269): чужие клиенты неизвестные параметры игнорируют, а без URI-формы
/// поле терялось бы на любом пересохранении узла через `toUri()`.
TcpKeepAliveSpec? tcpKeepAliveFromQuery(Map<String, String> q) {
  final raw = (q['disable_tcp_keep_alive'] ?? '').toLowerCase().trim();
  final s = TcpKeepAliveSpec(
    disabled: raw == '1' || raw == 'true',
    idle: _duration(q['tcp_keep_alive'] ?? ''),
    interval: _duration(q['tcp_keep_alive_interval'] ?? ''),
  );
  return s.isEmpty ? null : s;
}

/// spec → share-URI query. Пустая map, когда писать нечего.
Map<String, String> tcpKeepAliveToQuery(TcpKeepAliveSpec? s) {
  if (s == null) return const <String, String>{};
  return <String, String>{
    if (s.disabled) 'disable_tcp_keep_alive': '1',
    if (s.idle.isNotEmpty) 'tcp_keep_alive': s.idle,
    if (s.interval.isNotEmpty) 'tcp_keep_alive_interval': s.interval,
  };
}

// §472 шаг 9 — `tcpKeepAliveFromXraySockopt` снята: перевод секунд Xray в
// duration-строку делает маппер (`mappers/xray_mapper.dart`), а судит
// значение санитайзер по реестру. Единственным вызывающим был прежний
// Xray-конвертер, и он уехал на конвейер шагом 8.
