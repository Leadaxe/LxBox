import 'dart:convert';

import '../../../models/server_list.dart';
import '../../settings_storage.dart';
import '../../url_mask.dart';

/// Сериализатор `_cache` для `GET /state/storage` (§031).
///
/// Модель: **denylist с scrubber'ом**, не allow-list. Философия debug-tool'а —
/// по умолчанию всё видно разработчику, чтобы новые настройки автоматом
/// становились доступны без ручного whitelist'а. Известные чувствительные
/// поля маскируются здесь явно:
///
/// - `vars.debug_token` → `***`
/// - источники `server_lists[]` читаются моделями репозитория
///   ([serializeStorageSource]): URL подписки → `scheme://host/***` (provider
///   token в path), тело одиночного сервера → `raw_body_bytes` (inline URI
///   несут credentials), члены папки → `members_count` (§234 — raw члена несёт
///   credentials). Битая запись, которую репозиторий не читает, в дамп не
///   попадает: скрыть в ней секрет нечем.
///
/// Всё остальное — pass-through. Новый ключ без правила попадает в ответ
/// как есть; если он чувствительный — добавить rule здесь и в тесте.
///
/// ⚠️ §219 — этот scrubber НЕ является security-границей, а лишь UX-удобством
/// «не светить секрет случайно в скопированном introspection-дампе». Debug API
/// by design даёт полный root-доступ к секретам (`GET /backup/export` отдаёт
/// `exportRaw()` СЫРЫМ, включая приватники WARP/MASQUE; `/state/subs?reveal=true`
/// снимает URL-маску). Поэтому: `warp_account`/`masque_account` здесь НЕ
/// маскируются намеренно — маскировка тут ничего не «защищает» (те же данные
/// доступны сырыми рядом), а лишь усложняет диагностику. НЕ добавлять скраб
/// этих ключей как «security-фикс» — это ложная граница. См.
/// `docs/api/debug-api-reference.md` → «Security model — root-доступ by design».
Map<String, Object?> serializeStorageCache(Map<String, dynamic> cache) {
  final out = <String, Object?>{};
  for (final e in cache.entries) {
    out[e.key] = switch (e.key) {
      'vars' => _scrubVars(e.value),
      'server_lists' => [
          for (final list in SettingsStorage.serverListsOf(cache))
            serializeStorageSource(list),
        ],
      _ => e.value,
    };
  }
  return out;
}

Object? _scrubVars(dynamic vars) {
  if (vars is! Map) return vars;
  final out = <String, Object?>{};
  for (final e in vars.entries) {
    final k = e.key.toString();
    if (k == 'debug_token') {
      final v = e.value?.toString() ?? '';
      out[k] = v.isEmpty ? '' : '***';
    } else {
      out[k] = e.value;
    }
  }
  return out;
}

/// Запись источника [list] для дампа — запись хранения от репозитория, в
/// которой секрет модели скрыт.
///
/// Секрет гасится в модели, до сериализации (`copyWith`), поэтому в дамп он
/// не попадёт, как бы кодек ни назвал поле. Прежний скраббер угадывал ключи
/// сырого документа: искал `rawBody`, а в хранении лежит `raw_body`, и тело
/// одиночного сервера уходило в дамп целиком.
Map<String, Object?> serializeStorageSource(ServerList list) => switch (list) {
      SubscriptionServers s => SettingsStorage.serverListRecord(
          s.copyWith(url: maskSubscriptionUrl(s.url))),
      UserServer u => _sized(u, u.copyWith(rawBody: ''),
          counter: 'raw_body_bytes', size: u.rawBody.length),
      FolderServers f => _sized(f, f.copyWith(members: const []),
          counter: 'members_count', size: f.members.length),
    };

/// Запись [full], где поля, которые гашение секрета изменило (сверка с записью
/// [blank]), заменены одним счётчиком [counter] на месте первого из них.
/// Какие это поля, говорит сама запись, а не список ключей скраббера.
/// Секрет и так пуст (пустое тело, папка без членов) — счётчик дописывается
/// в конец.
Map<String, Object?> _sized(
  ServerList full,
  ServerList blank, {
  required String counter,
  required int size,
}) {
  final blanked = SettingsStorage.serverListRecord(blank);
  final out = <String, Object?>{};
  for (final e in SettingsStorage.serverListRecord(full).entries) {
    final kept = blanked.containsKey(e.key) &&
        jsonEncode(blanked[e.key]) == jsonEncode(e.value);
    if (kept) {
      out[e.key] = e.value;
    } else {
      out.putIfAbsent(counter, () => size);
    }
  }
  out.putIfAbsent(counter, () => size);
  return out;
}
