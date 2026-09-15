import '../../../models/codec/chain_record.dart';
import '../../../models/codec/source_record.dart';
import '../../../models/server_list.dart';
import '../../settings_storage.dart';
import '../../settings_storage_keys.dart';
import '../../url_mask.dart';

/// Сериализатор `_cache` для `GET /state/storage` (§031).
///
/// Модель: **denylist с scrubber'ом**, не allow-list. Философия debug-tool'а —
/// по умолчанию всё видно разработчику, чтобы новые настройки автоматом
/// становились доступны без ручного whitelist'а. Известные чувствительные
/// поля маскируются здесь явно:
///
/// - `vars.debug_token` → `***`
/// - `sources[]` (§439) читаются моделями репозитория и пишутся кодеком
///   записей ([serializeStorageSource]): `url` подписки →
///   `scheme://host/***` (provider token в path), `origin.raw` одиночного
///   сервера → `origin.raw_bytes` (inline URI несут credentials), `nodes[]`
///   папки → `nodes_count` (текст члена несёт credentials, §234). Цепочки
///   идут хвостом как есть — секретов в них нет. Запись, которую репозиторий
///   не читает, в дамп не попадает: скрыть в ней секрет нечем.
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
      kSourcesKey => [
          for (final list in SettingsStorage.serverListsOf(cache))
            serializeStorageSource(list),
          for (final chain in SettingsStorage.chainsOf(cache))
            chainToRecord(chain),
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

/// Запись источника [list] для дампа — запись кодека, в которой секрет
/// заменён по пути записи на том же месте: `url` подписки — маской,
/// `origin.raw` сервера — длиной (`origin.raw_bytes`), `nodes[]` папки —
/// счётчиком (`nodes_count`).
Map<String, Object?> serializeStorageSource(ServerList list) => {
      for (final e in sourceToRecord(list).entries)
        ...switch ((list, e.key)) {
          (SubscriptionServers s, 'url') => {'url': maskSubscriptionUrl(s.url)},
          (UserServer u, 'origin') => {
              'origin': {
                'kind': (e.value as Map)['kind'],
                'raw_bytes': u.rawBody.length,
              },
            },
          (FolderServers f, 'nodes') => {'nodes_count': f.members.length},
          _ => {e.key: e.value},
        },
    };
