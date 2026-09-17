/// §460 W1 — рендер предупреждений санитайзера из текстов реестра.
///
/// Сам класс [RegistryWarning] живёт в `models/node_warning.dart`: база
/// `NodeWarning` объявлена `sealed`, а Dart 3 разрешает наследование от
/// `sealed` только внутри её библиотеки. Здесь — резолв текста, который
/// классу и нужен: `title_<lang>` для строки узла, `text_<lang>` для
/// карточки, подстановки и severity.
///
/// Тексты — ДАННЫЕ контракта, а не строки UI (24.1.5): приложение своих
/// таблиц не держит, и l10n-чекеры сюда не смотрят.
library;

import '../../models/node_warning.dart' show WarningSeverity;
import 'registry.dart';

/// Язык текста реестра. `zh` падает в `en`, пока лаунчер не добавит третий
/// набор (спека §460 §2.3).
enum RegistryLang { en, ru }

/// Тег активной локали → язык реестра.
RegistryLang registryLangForTag(String tag) =>
    tag == 'ru' ? RegistryLang.ru : RegistryLang.en;

/// Короткая строка кода (⚠ на строке узла). Кода нет в реестре — сам код:
/// молчать нельзя, а выдумывать текст за контракт тем более.
String registryTitle(
  String code,
  RegistryLang lang, {
  String? path,
  String? value,
  Map<String, String> params = const {},
}) {
  final text = ContractRegistry.I.textFor(code);
  if (text == null) return code;
  final raw = lang == RegistryLang.ru ? text.titleRu : text.titleEn;
  if (raw.isEmpty) return code;
  return _substitute(raw, path: path, value: value, params: params);
}

/// Развёрнутый текст кода (карточка узла). Кода нет — пустая строка:
/// карточке нечего показать, и подпись из кода уже стоит заголовком.
String registryText(
  String code,
  RegistryLang lang, {
  String? path,
  String? value,
  Map<String, String> params = const {},
}) {
  final text = ContractRegistry.I.textFor(code);
  if (text == null) return '';
  final raw = lang == RegistryLang.ru ? text.textRu : text.textEn;
  return _substitute(raw, path: path, value: value, params: params);
}

/// Severity кода из реестра; кода нет — `warning` (не глушить незнакомое).
WarningSeverity registrySeverity(String code) {
  switch (ContractRegistry.I.textFor(code)?.severity) {
    case 'info':
      return WarningSeverity.info;
    case 'error':
      return WarningSeverity.error;
    default:
      return WarningSeverity.warning;
  }
}

/// Подстановки `{path}`, `{value}` и произвольные `{<param>}`.
///
/// Незаполненный плейсхолдер остаётся как есть: текст реестра — источник
/// правды, и подменять его на пустоту значило бы врать («поле  снято»).
/// Такое расхождение видно глазами и чинится в реестре.
String _substitute(
  String raw, {
  String? path,
  String? value,
  Map<String, String> params = const {},
}) {
  var out = raw;
  if (path != null) out = out.replaceAll('{path}', path);
  if (value != null) out = out.replaceAll('{value}', value);
  for (final e in params.entries) {
    out = out.replaceAll('{${e.key}}', e.value);
  }
  return out;
}
