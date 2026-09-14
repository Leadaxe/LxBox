// §372 — единая точка входа для выбора файла.
//
// На устройствах без системного файлового менеджера (типовой случай —
// Android TV: в прошивках нет DocumentsUI) file_picker не открывает ничего.
// Плагин проверяет `intent.resolveActivity(packageManager)` перед запуском
// (android_file_picker 1.1.1, FileUtils.kt:246) и, не найдя обработчика,
// отвечает `finishWithError("explorer_not_found", ...)` — на Dart-сторону приходит
// PlatformException. Прямые вызовы FilePicker.pickFiles показывали это как
// техническую ошибку («Can't handle the provided file type») либо, где стоял
// общий catch, как ложное «Failed to parse config» — юзер видел тупик, хотя
// рабочая альтернатива (буфер обмена / импорт по URL) в приложении есть.
//
// Обёртка конвертирует ситуацию в доменный исход [PickNoPicker], чтобы UI
// показал подсказку с альтернативой. Отмена юзером — отдельный исход, а не
// ошибка: молча выходим.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../models/ui_msg.dart';
import 'app_log.dart';
import 'error_format.dart';
import 'l10n/locale_controller.dart';
import 'url_launcher.dart';

/// Код ошибки file_picker'а, которым плагин отвечает, когда в системе не
/// нашлось активити под ACTION_OPEN_DOCUMENT / ACTION_GET_CONTENT.
/// §431 — в file_picker 12 (android_file_picker) код сменился с
/// `invalid_format_type` на `explorer_not_found`.
const _noPickerCode = 'explorer_not_found';

/// §431 — выбранный файл, уже прочитанный в память.
///
/// Свой тип вместо `PlatformFile` плагина: в file_picker 12 тот стал
/// `abstract base` без конструктора (§383-путь строил его руками) и потерял
/// синхронный `bytes`. Обёртка читает байты сама, поэтому вызывающим не
/// нужна развилка bytes/path — у них всегда есть [bytes] и [text].
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  /// Имя файла с расширением, как его отдал пикер.
  final String name;

  final Uint8List bytes;

  /// Содержимое как текст. utf8 с `allowMalformed`, не `fromCharCodes`:
  /// тот трактовал байты как UTF-16 code units и ломал кириллицу (§333).
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// Результат попытки выбрать файл.
sealed class PickOutcome {
  const PickOutcome();
}

/// Юзер выбрал файлы. [files] непустой.
class PickedFiles extends PickOutcome {
  const PickedFiles(this.files);

  final List<PickedFile> files;

  PickedFile get single => files.single;
}

/// Юзер закрыл пикер, ничего не выбрав. Не ошибка — вызывающий выходит молча.
class PickCancelled extends PickOutcome {
  const PickCancelled();
}

/// В системе нет файлового менеджера (Android TV). Вызывающий показывает
/// подсказку про буфер обмена / URL вместо технической ошибки.
class PickNoPicker extends PickOutcome {
  const PickNoPicker();
}

/// Прочий сбой пикера. [error] — исходное исключение для логов и
/// formatUserError.
class PickFailed extends PickOutcome {
  const PickFailed(this.error);

  final Object error;
}

/// Обёртка над [FilePicker.pickFiles] с разбором исходов.
///
/// Параметры повторяют используемые в приложении. Байты читаются здесь же:
/// path на SAF-Uri может быть null, а `PlatformFile.bytes` в file_picker 12
/// нет — только `readAsBytes()`.
Future<PickOutcome> pickFileSafely({
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  bool allowMultiple = false,
}) async {
  // §372 — предварительная проверка. На Android TV пикера нет, но intent
  // перехватывает системная заглушка frameworkpackagestubs: она показывает
  // тост и отменяет выбор, из-за чего пик неотличим от «юзер передумал».
  // Ошибка invalid_format_type (ветка PickFailed ниже) в этом случае НЕ
  // возникает — плагин видит обработчика и спокойно стартует intent.
  // Поэтому спрашиваем платформу заранее. DEVICE-VERIFIED на эмуляторе
  // Android TV: без этой проверки кнопка импорта была немой.
  // §383 — спрашиваем не «есть ли пикер», а КАКОЙ action он обслуживает.
  // Файловые менеджеры старой школы (Total Commander на 7.x) отвечают только
  // на GET_CONTENT, и §372-детект по одному OPEN_DOCUMENT считал их
  // отсутствующими — импорт был закрыт при установленном менеджере.
  final action = await UrlLauncher.filePickerAction();
  if (action == null) {
    AppLog.I.warning('[pick] no real file manager (TV stub only)');
    return const PickNoPicker();
  }
  if (action == UrlLauncher.actionGetContent) {
    // Плагин для FileType.any жёстко строит OPEN_DOCUMENT и переключаться не
    // умеет — идём своим пиком через канал.
    return _pickViaGetContent(
      allowedExtensions: allowedExtensions,
      allowMultiple: allowMultiple,
    );
  }
  try {
    // allowMultiple deprecated в пользу pickFile(); один вход с параметром
    // проще двух веток.
    final picked = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      // ignore: deprecated_member_use
      allowMultiple: allowMultiple,
    );
    if (picked.isEmpty) return const PickCancelled();
    final files = <PickedFile>[];
    for (final f in picked) {
      files.add(PickedFile(name: f.name, bytes: await f.readAsBytes()));
    }
    return PickedFiles(files);
  } on PlatformException catch (e) {
    if (e.code == _noPickerCode) {
      AppLog.I.warning('[pick] no file manager on device (${e.code})');
      return const PickNoPicker();
    }
    AppLog.I.warning('[pick] platform error: $e');
    return PickFailed(e);
  } catch (e) {
    AppLog.I.warning('[pick] failed: $e');
    return PickFailed(e);
  }
}

/// §383 — пик через собственный `ACTION_GET_CONTENT` (нативная сторона).
///
/// Путь для устройств, где `OPEN_DOCUMENT` не обслуживается: `file_picker`
/// для `FileType.any` умеет только его. Результат приводится к [PlatformFile],
/// поэтому вызывающие о развилке не знают.
///
/// [allowedExtensions] фильтруем сами: `GET_CONTENT` с `*/*` отдаёт что угодно,
/// а call-site'ы вроде импорта конфига ждут конкретное расширение. Отказ —
/// [PickFailed] с внятным текстом, а не молчаливое «отменено».
///
/// Результат приводится к [PickedFile] — тому же типу, что у плагинного пути.
Future<PickOutcome> _pickViaGetContent({
  List<String>? allowedExtensions,
  bool allowMultiple = false,
}) async {
  try {
    final picked =
        await UrlLauncher.pickFilesViaGetContent(allowMultiple: allowMultiple);
    if (picked == null || picked.isEmpty) return const PickCancelled();
    final files = <PickedFile>[];
    for (final item in picked) {
      final name = item['name'] as String? ?? 'config';
      final bytes = item['bytes'] as Uint8List?;
      if (bytes == null) {
        AppLog.I.warning('[pick] GET_CONTENT returned no bytes for $name');
        continue;
      }
      if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
        final allowed =
            allowedExtensions.map((e) => e.toLowerCase().replaceAll('.', ''));
        if (!allowed.contains(ext)) {
          AppLog.I.warning('[pick] GET_CONTENT: extension "$ext" not allowed');
          continue;
        }
      }
      files.add(PickedFile(name: name, bytes: bytes));
    }
    if (files.isEmpty) {
      // Юзер что-то выбрал, но всё отсеялось: расширение не то либо файл не
      // читается. Молчать нельзя — иначе выглядит как «кнопка не работает».
      final hint = allowedExtensions != null && allowedExtensions.isNotEmpty
          ? getLocalText.s('Select a %s file', allowedExtensions.join(', '))
          : getLocalText.s('Cannot read the selected file');
      return PickFailed(Exception(hint));
    }
    AppLog.I.info('[pick] GET_CONTENT ok: ${files.length} file(s)');
    return PickedFiles(files);
  } on PlatformException catch (e) {
    AppLog.I.warning('[pick] GET_CONTENT platform error: $e');
    return PickFailed(e);
  } catch (e) {
    AppLog.I.warning('[pick] GET_CONTENT failed: $e');
    return PickFailed(e);
  }
}

/// Текст подсказки для [PickNoPicker] — для snackbar-поверхностей, которые
/// показывают готовую строку. Контроллеры, хранящие UiMsg в состоянии,
/// используют напрямую `ErrMsg(ErrKey.noFileManager)` — тот же ключ словаря,
/// но с ленивым рендером (§285).
String get noFileManagerHint => const ErrMsg(ErrKey.noFileManager).render();

/// Текст для не-успешного исхода, который UI показывает снекбаром, либо null
/// для [PickCancelled] (юзер сам закрыл пикер — молчим) и [PickedFiles].
///
/// Общий разбор для экранов: `final msg = pickProblemText(outcome); if (msg
/// != null) showSnack(msg);`
String? pickProblemText(PickOutcome outcome) => switch (outcome) {
      PickedFiles() || PickCancelled() => null,
      PickNoPicker() => noFileManagerHint,
      PickFailed(:final error) =>
        getLocalText.s("Error: %s", formatUserError(error).render()),
    };
