part of '../settings_storage.dart';

// §393 B7 — блобы `extensions.<чужое приложение>` из LX Backup.
//
// BACKUP.md §1: принимающая сторона обязана сохранить чужой блоб НЕТРОНУТЫМ
// до следующего экспорта («лаунчер — новое поле state v6; LxBox — новый ключ
// allowlist»). Это тот самый ключ.
//
// Зачем отдельный ключ, а не «положить в extensions при экспорте на лету».
// Круг launcher→LxBox→launcher проходит через ИМПОРТ на телефон: если блоб не
// лёг на диск, следующий экспорт с телефона его не восстановит, и настройки
// лаунчера (цепочки хопов SPEC 110, skip-фильтры, локальные outbound'ы)
// исчезнут — молча, потому что мобила о них ничего не знает и предъявить
// пользователю ничего не может.
//
// Вынесено `part`'ом по образцу `directions.dart`/`chains.dart` — та же
// библиотека, тот же доступ к `_load`/`_save`/`_cache`.
//
// НЕ config-significant: содержимое ключа в конфиг ядра не попадает вообще
// никогда — это транзитный груз для чужого приложения.

/// §393 B7 — чужие блобы: `{"launcher": {...}}`. Ключ `lxbox` сюда не
/// попадает — своё применяется полями импорта.
Future<Map<String, dynamic>> _getLxBackupExtensions() async {
  final data = await _load();
  final raw = data['lx_backup_extensions'];
  if (raw is! Map) return const {};
  return raw.cast<String, dynamic>();
}

/// Сохраняет чужие блобы. Merge ПО ПРИЛОЖЕНИЮ: приехавший блоб замещает
/// прежний блоб ТОГО ЖЕ приложения целиком (он его снимок, а не дельта), но
/// блоб приложения, которого в этом файле не было, остаётся на месте —
/// импорт из лаунчера не должен стирать груз какой-нибудь третьей стороны.
///
/// Пустой [blobs] — no-op, а не очистка: «файл ничего не привёз» и «файл
/// требует всё забыть» — разные вещи, и вторая никем не выражается.
Future<void> _setLxBackupExtensions(
  Map<String, dynamic> blobs, {
  bool flush = true,
}) async {
  if (blobs.isEmpty) return;
  final data = await _load();
  final prior = data['lx_backup_extensions'];
  final merged = <String, dynamic>{
    if (prior is Map) ...prior.cast<String, dynamic>(),
  };
  for (final e in blobs.entries) {
    // Своё приложение в чужих блобах — ошибка вызывающего; молча не
    // сохраняем, иначе экспорт положил бы в `extensions.lxbox` копию себя.
    if (e.key == kLxAppLxBox) continue;
    merged[e.key] = e.value;
  }
  data['lx_backup_extensions'] = merged;
  SettingsStorage._cache = data;
  if (flush) await _save();
}
