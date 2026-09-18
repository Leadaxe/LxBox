/// Фича 478 / CANON §9.4 — хранимый вердикт «ядро не приняло этот узел».
///
/// **Новых сущностей нет**: узел выключается тем же флажком, что и рукой
/// человека, а причина живёт записью в списке предупреждений узла:
///
/// ```json
/// {"code": "core_rejected", "params": {"reason": "<текст ядра>"}}
/// ```
///
/// «Выключило ПРИЛОЖЕНИЕ» = у выключенного узла есть эта запись; её
/// отсутствие при выключенности = «выключил человек» (CANON §9.4).
/// Отдельного поля причины НЕ вводится (решение владельца 18.09.2026).
///
/// Хранится ровно этот код — прочие предупреждения по-прежнему вычисляются
/// при разборе (`NodeSpec.warnings` не персистится, `parse_all.dart`).
/// Место хранения — рядом с существующей отметкой о выключении (спека 478
/// раздел 3b): `sources[].warnings` у подписки, `nodes[].warnings` у члена
/// папки, `warnings` на источнике у ручного сервера.
library;

import 'node_warning.dart';

/// Код реестра вердикта. Тексты — из `registry/warnings.json`, своих таблиц
/// приложение не держит (24.1.5).
const kCoreRejectedCode = 'core_rejected';

/// Имя подстановки текста реестра.
const kCoreRejectedReasonParam = 'reason';

/// Одна хранимая запись предупреждения. Форма лаунчера: `code` + `params`,
/// без `path` и без severity (она из реестра).
final class StoredWarning {
  const StoredWarning({required this.code, this.params = const {}});

  final String code;
  final Map<String, String> params;

  /// Дословный текст ядра у вердикта; у прочих кодов — пусто.
  String get reason => params[kCoreRejectedReasonParam] ?? '';

  bool get isCoreRejected => code == kCoreRejectedCode;

  /// Вердикт по тексту ядра (без префикса `initialize …[tag]: `).
  factory StoredWarning.coreRejected(String reason) => StoredWarning(
        code: kCoreRejectedCode,
        params: {kCoreRejectedReasonParam: reason},
      );

  /// Запись → предупреждение узла. Severity берётся реестром по коду.
  RegistryWarning toWarning() =>
      RegistryWarning(code: code, params: params);

  Map<String, dynamic> toJson() => {
        'code': code,
        if (params.isNotEmpty) 'params': {...params},
      };

  /// `null` — запись негодна (не Map, пустой код): молча пропускаем,
  /// хранение чужой мусор не воспроизводит.
  static StoredWarning? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['code'];
    if (code is! String || code.isEmpty) return null;
    final p = raw['params'];
    final params = <String, String>{};
    if (p is Map) {
      for (final e in p.entries) {
        final k = e.key;
        final v = e.value;
        if (k is String && k.isNotEmpty && v != null) params[k] = '$v';
      }
    }
    return StoredWarning(code: code, params: params);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredWarning &&
          code == other.code &&
          _mapEq(params, other.params));

  @override
  int get hashCode => Object.hash(
        code,
        Object.hashAllUnordered(
            params.entries.map((e) => '${e.key}=${e.value}')),
      );

  @override
  String toString() => 'StoredWarning($code, $params)';
}

bool _mapEq(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// Список записей → JSON; пустой список кодируется как отсутствие ключа
/// (решает вызывающий кодек).
List<Map<String, dynamic>> storedWarningsToJson(List<StoredWarning> ws) =>
    [for (final w in ws) w.toJson()];

/// JSON → список записей. Не-список, негодные элементы — отбрасываются.
List<StoredWarning> storedWarningsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <StoredWarning>[];
  for (final e in raw) {
    final w = StoredWarning.fromJson(e);
    if (w != null) out.add(w);
  }
  return out;
}

/// Оверлей подписки: тег-идентичность → записи. Симметричен `disabled`.
Map<String, List<StoredWarning>> storedWarningsMapFromJson(Object? raw) {
  if (raw is! Map || raw.isEmpty) return const {};
  final out = <String, List<StoredWarning>>{};
  for (final e in raw.entries) {
    final k = e.key;
    if (k is! String || k.isEmpty) continue;
    final ws = storedWarningsFromJson(e.value);
    if (ws.isNotEmpty) out[k] = ws;
  }
  return out;
}

Map<String, dynamic> storedWarningsMapToJson(
        Map<String, List<StoredWarning>> m) =>
    {
      for (final e in m.entries)
        if (e.value.isNotEmpty) e.key: storedWarningsToJson(e.value),
    };

/// CANON §9.4 — дубль по коду ЗАМЕЩАЕТСЯ свежим, вердикт идёт ПЕРВЫМ:
/// это приговор уровня узла, а не деградация отдельного поля.
List<StoredWarning> upsertVerdict(
  List<StoredWarning> existing,
  StoredWarning verdict,
) =>
    [verdict, ...existing.where((w) => w.code != verdict.code)];

/// Снять вердикт: остальные записи сохраняются.
List<StoredWarning> dropVerdict(List<StoredWarning> existing) =>
    existing.where((w) => !w.isCoreRejected).toList();
