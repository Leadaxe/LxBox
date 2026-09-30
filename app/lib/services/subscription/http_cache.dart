import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Кэш последнего HTTP-ответа подписки (body + headers). Используется
/// `SubscriptionDetailScreen → Source` чтобы показать реальный запрос,
/// а не реконструкцию из `SubscriptionMeta`.
///
/// Файлы:
///   app_support/sub_cache/`<hash>`          — сырое тело (как пришло по HTTP)
///   app_support/sub_cache/`<hash>`.headers  — JSON `{header: value, ...}`
///
/// §603 — `<hash>` = sha256(url) в hex. Прежний ключ `url.hashCode` (32 бита)
/// давал коллизии и не обещан стабильным между версиями Dart; файлы под ним
/// переименовываются в новый ключ при первом обращении ([_migrateLegacy]).
class HttpCache {
  HttpCache._();

  @visibleForTesting
  static String keyFor(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  /// Ключ до §603. Только для переноса старых файлов.
  @visibleForTesting
  static String legacyKeyFor(String url) => url.hashCode.toRadixString(16);

  static String _hash(String url) => keyFor(url);

  /// §603 — одноразовый перенос файлов старого ключа под новый. Переносим, а
  /// не прогреваем заново: у файловой подписки снапшот — единственная копия
  /// данных. Новый файл уже есть → старый не нужен, удаляем. Best-effort.
  static Future<void> _migrateLegacy(Directory dir, String url) async {
    final legacy = legacyKeyFor(url);
    final key = keyFor(url);
    for (final suffix in const ['', '.headers']) {
      try {
        final old = File('${dir.path}/$legacy$suffix');
        if (!old.existsSync()) continue;
        final target = File('${dir.path}/$key$suffix');
        if (target.existsSync()) {
          await old.delete();
        } else {
          await old.rename(target.path);
        }
      } catch (_) {
        // best-effort: кэш опционален
      }
    }
  }

  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}/sub_cache');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  static Future<void> save(
    String url,
    String body,
    Map<String, String> headers,
  ) async {
    final dir = await _dir();
    final key = _hash(url);
    await _migrateLegacy(dir, url);
    // §101 — атомарно (tmp → rename): save вызывается unawaited, kill
    // процесса mid-write не должен оставить обрезанное тело (rehydrate
    // распарсит его в 0 нод при «живом» lastNodeCount).
    await _writeAtomic('${dir.path}/$key', body);
    await _writeAtomic('${dir.path}/$key.headers', jsonEncode(headers));
  }

  /// Монотонный суффикс tmp-файлов: конкурентные save одного URL не должны
  /// красть tmp друг у друга (rename бросал бы PathNotFound в unawaited).
  static int _tmpSeq = 0;

  static Future<void> _writeAtomic(String path, String content) async {
    final tmp = File('$path.${_tmpSeq++}.tmp');
    try {
      // Директория могла исчезнуть между _dir() и записью (в тестах — очистка
      // temp между кейсами; на устройстве — clear cache). recursive:true
      // идемпотентен, не бросает если уже есть.
      await tmp.parent.create(recursive: true);
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(path);
    } catch (_) {
      // Кэш опционален (save вызывается unawaited, §101). Провал записи не
      // должен ни ронять поток, ни всплывать как unhandled из unawaited-future.
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

  static Future<String?> loadBody(String url) async {
    try {
      final dir = await _dir();
      await _migrateLegacy(dir, url);
      final f = File('${dir.path}/${_hash(url)}');
      if (!f.existsSync()) return null;
      // await обязателен: без него ошибка чтения пролетит мимо catch ниже
      // и вместо null прилетит исключение вызывающему (lint
      // unawaited_return_in_try_block, Flutter 3.47).
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, String>?> loadHeaders(String url) async {
    try {
      final dir = await _dir();
      await _migrateLegacy(dir, url);
      final f = File('${dir.path}/${_hash(url)}.headers');
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// §603 — скопировать кэш [from] под [to] (смена адреса подписки без
  /// фетча: прежние узлы живут до первого успешного обновления по новому
  /// адресу). Кэша [from] нет или у [to] уже свой — ничего не делаем.
  static Future<void> copy(String from, String to) async {
    if (from == to) return;
    if (await loadBody(to) != null) return;
    final body = await loadBody(from);
    if (body == null) return;
    await save(to, body, await loadHeaders(from) ?? const {});
  }

  /// §129 — удалить кэш (тело + headers) осиротевшего ключа. Используется при
  /// смене источника подписки: старый url больше не адресуется, его снапшот
  /// не нужен. Best-effort: отсутствие файлов — не ошибка.
  static Future<void> remove(String url) async {
    try {
      final dir = await _dir();
      await _migrateLegacy(dir, url);
      final key = _hash(url);
      final body = File('${dir.path}/$key');
      final headers = File('${dir.path}/$key.headers');
      if (body.existsSync()) await body.delete();
      if (headers.existsSync()) await headers.delete();
    } catch (_) {
      // best-effort
    }
  }
}
