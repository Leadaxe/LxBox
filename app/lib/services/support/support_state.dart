import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// §105 — persist-состояние support-message фичи. **Отдельный файл**
/// (`support_state.json` в documents), НЕ `lxbox_settings.json`:
/// счётчик активного времени флашится каждую минуту работы туннеля, а
/// mtime settings-файла участвует в §076 configDirty-сравнении — писали бы
/// мы туда, каждый старт дирявил бы конфиг и гонял лишний rebuild.
///
/// Поля (§356): `active_seconds` (суммарное tunnel-up время),
/// `session_credited` (сколько секунд текущей сессии туннеля уже зачислено —
/// нативный учёт), `read` (`{id сообщения → версия приложения при
/// «Прочитал»}`), `baseline_seconds`/`baseline_version` (точка отсчёта
/// `min_active_hours`; двигается при смене версии и «Прочитал»),
/// `snooze_after_seconds` («Later» — порог активного времени для повтора),
/// `cache_json` (последний удачно скачанный support.json — офлайн-показ).
/// v1-ключ `dismissed_id` мёртв — игнорируется, не мигрируется.
class SupportState {
  SupportState._();
  static final SupportState I = SupportState._();

  Map<String, dynamic>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/support_state.json');
  }

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (!f.existsSync()) return _cache = <String, dynamic>{};
      final decoded = jsonDecode(await f.readAsString());
      return _cache =
          decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      // Битый/недоступный файл — стартуем с нуля (потеря не критична:
      // счётчик доберётся заново, кампания покажется чуть позже).
      return _cache = <String, dynamic>{};
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_cache), flush: true);
    } catch (_) {
      // best-effort — следующая запись доедет.
    }
  }

  Future<int> getInt(String key) async =>
      ((await _load())[key] as num?)?.toInt() ?? 0;

  Future<String> getString(String key) async =>
      (await _load())[key] as String? ?? '';

  /// §356 — строковая карта (ключ `read`). Не-map / битое → пустая.
  Future<Map<String, String>> getStringMap(String key) async {
    final v = (await _load())[key];
    if (v is! Map) return <String, String>{};
    return v.map((k, val) => MapEntry(k.toString(), val.toString()));
  }

  Future<void> set(String key, Object value) async {
    (await _load())[key] = value;
    await _save();
  }

  /// §356 — несколько ключей одной записью на диск (атомарность пары
  /// baseline_seconds/baseline_version и read/baseline при «Прочитал»).
  Future<void> setAll(Map<String, Object> values) async {
    (await _load()).addAll(values);
    await _save();
  }

  /// Для тестов — сбросить in-memory кэш (файл перечитается).
  void resetCacheForTesting() => _cache = null;
}
