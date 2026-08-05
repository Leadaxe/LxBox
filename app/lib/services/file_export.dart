// §374 — единая точка входа для сохранения файла на устройство.
//
// Зеркало file_import.dart (§372). Экспорт бэкапа раньше умел только
// Share.shareXFiles: файл писался в кэш и отдавался системе «поделиться».
// На устройствах без файлового менеджера в share-sheet нет пункта
// «сохранить в файлы», и бэкап сохранить было некуда — жалоба юзера.
//
// Здесь два пути сохранения:
//   1. SAF ACTION_CREATE_DOCUMENT через FilePicker.saveFile — системный
//      «Сохранить как». Плагин сам пишет байты в выбранный Uri.
//   2. MediaStore-запись в публичную Downloads (API 29+) — там, где
//      SAF-диалога нет вовсе.
//
// ГРАБЛЯ (та же, что в §372): saveFile возвращает null и при отмене
// юзером, и когда intent перехватила TV-заглушка frameworkpackagestubs —
// она показывает тост и отвечает RESULT_CANCELED, так что ошибка
// invalid_format_type даже не возникает. Различить исходы постфактум
// нельзя, поэтому наличие пикера проверяется ЗАРАНЕЕ, как в pickFileSafely.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../models/ui_msg.dart';
import 'app_log.dart';
import 'error_format.dart';
import 'l10n/locale_controller.dart';
import 'url_launcher.dart';

/// Код ошибки file_picker'а, когда в системе не нашлось активити под
/// ACTION_CREATE_DOCUMENT. Тот же код, что у pickFiles (§372).
const _noPickerCode = 'invalid_format_type';

/// Результат попытки сохранить файл.
sealed class SaveOutcome {
  const SaveOutcome();
}

/// Сохранено через системный диалог. [name] — имя файла; полный путь не
/// отдаём: saveFile возвращает path SAF-Uri (`/document/primary:Download/…`),
/// а не путь в файловой системе, и показывать его юзеру бессмысленно.
class SavedToFile extends SaveOutcome {
  const SavedToFile(this.name);

  final String name;
}

/// Сохранено в публичную папку Downloads. [name] — фактическое имя,
/// с учётом разведения коллизий MediaStore'ом.
class SavedToDownloads extends SaveOutcome {
  const SavedToDownloads(this.name);

  final String name;
}

/// Юзер закрыл диалог сохранения. Не ошибка — вызывающий выходит молча.
class SaveCancelled extends SaveOutcome {
  const SaveCancelled();
}

/// Сохранять некуда: нет ни файлового менеджера, ни MediaStore (API 28-).
class SaveNoTarget extends SaveOutcome {
  const SaveNoTarget();
}

/// Прочий сбой. [error] — исходное исключение для логов и formatUserError.
class SaveFailed extends SaveOutcome {
  const SaveFailed(this.error);

  final Object error;
}

/// Сохранение через системный диалог «Сохранить как» (SAF).
///
/// Возвращает [SaveNoTarget], если настоящего файлового менеджера на
/// устройстве нет — до запуска intent'а, иначе заглушка вернёт исход,
/// неотличимый от отмены.
Future<SaveOutcome> saveFileSafely({
  required String fileName,
  required String content,
}) async {
  if (!await UrlLauncher.hasRealFilePicker()) {
    AppLog.I.warning('[save] no real file manager (TV stub only)');
    return const SaveNoTarget();
  }
  try {
    final path = await FilePicker.saveFile(
      fileName: fileName,
      bytes: utf8.encode(content),
    );
    if (path == null) return const SaveCancelled();
    return SavedToFile(fileName);
  } on PlatformException catch (e) {
    if (e.code == _noPickerCode) {
      AppLog.I.warning('[save] no file manager on device (${e.code})');
      return const SaveNoTarget();
    }
    AppLog.I.warning('[save] platform error: $e');
    return SaveFailed(e);
  } catch (e) {
    AppLog.I.warning('[save] failed: $e');
    return SaveFailed(e);
  }
}

/// Сохранение в публичную папку Downloads (API 29+).
Future<SaveOutcome> saveToDownloadsSafely({
  required String fileName,
  required String content,
}) async {
  try {
    final saved = await UrlLauncher.saveToDownloads(
      fileName: fileName,
      content: content,
    );
    if (saved == null) {
      AppLog.I.warning('[save] MediaStore write returned null');
      return const SaveNoTarget();
    }
    return SavedToDownloads(saved);
  } catch (e) {
    AppLog.I.warning('[save] downloads failed: $e');
    return SaveFailed(e);
  }
}

/// Текст для не-успешного исхода, либо null для успехов и [SaveCancelled]
/// (юзер сам закрыл диалог — молчим).
///
/// Успехи возвращают null намеренно: снекбар успеха складывается на месте
/// вызова (нужен размер бэкапа), а здесь — только проблемные ветки.
String? saveProblemText(SaveOutcome outcome) => switch (outcome) {
      SavedToFile() || SavedToDownloads() || SaveCancelled() => null,
      SaveNoTarget() => const ErrMsg(ErrKey.noFileManager).render(),
      SaveFailed(:final error) =>
        getLocalText.s("Export failed: %s", formatUserError(error).render()),
    };
