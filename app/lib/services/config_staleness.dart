// -----------------------------------------------------------------------------
// §324 — «устарел ли конфиг, который крутит ядро, относительно сохранённого».
//
// Плашка «restart to apply» задаёт именно этот вопрос, но до §324 отвечал на
// него дифф saved-vs-saved (новый собранный конфиг против предыдущего
// сохранённого) — то есть «изменился ли файл». Разница не академическая:
// подписка, отдавшая тот же состав нод, меняет байты конфига (порядок узлов от
// провайдера, суффиксы `allocateTag`, §028 mixed-case SNI рандомит
// `server_name` на КАЖДОЙ сборке) — и плашка вылезала раз в час без причины.
//
// Ответ команды ядра (31.07.2026):
//
//     stale ⟺ FormatConfig(наш текст + override) != GetRunningConfig().Content()
//
// `captureRunningConfig` и `FormatConfig` используют один парсер и один
// энкодер (kernel SPEC 037 §3), поэтому вся нормализация формы — порядок
// полей, `omitempty`, `[] → null` — сворачивается ВНУТРИ ядра. Клиентский
// список «различий, которые игнорируем» не нужен и разъехаться нечему.
//
// Здесь живёт то, что ядро за нас не сделает: наложение `OverrideOptions`
// (`FormatConfig` их не применяет, а снапшот — post-override) и само
// сравнение. Чистые функции без I/O — вызов `Libbox.formatConfig` делает
// `BoxVpnClient.formatConfig`.
// -----------------------------------------------------------------------------

import 'dart:convert';

import 'platform_channels.dart';

/// Что native кладёт в `OverrideOptions` перед `startOrReloadService`.
/// Зеркало `BoxService.buildOverrideOptions` (Kotlin).
///
/// **Инвариант (§324, по образцу §221).** Список полей живёт в ДВУХ местах —
/// здесь и в `buildOverrideOptions`. Появилась четвёртая докрутка в native —
/// обязана появиться здесь, иначе компаратор молча начнёт врать («вечный
/// stale» либо, хуже, пропущенное изменение). Тест
/// `config_staleness_test.dart` держит списки в соответствии.
///
/// Того, что API `OverrideOptions` позволяет, но мы НЕ используем, здесь нет:
/// `excludePackage` native не заполняет никогда.
class OverrideSnapshot {
  const OverrideSnapshot({
    this.includeSelfPackage = false,
    this.autoRedirect = false,
  });

  /// §124 — свой пакет дописывается в `include_package`, **только** в
  /// allow-режиме. В deny нельзя: include + exclude в одном tun → Android
  /// бросает `UnsupportedOperationException`. Native выводит режим из самого
  /// конфига (наличие `include_package` у первого tun-inbound), поэтому здесь
  /// флаг не нужен — [applyOverrides] определяет режим так же.
  final bool includeSelfPackage;

  /// §124/§189 — root-only tproxy из persistent-флага (`BootReceiver
  /// .isAutoRedirect`, default false). Присваивается, НЕ мержится.
  final bool autoRedirect;

  /// Поля, которые зеркалим. Только для теста-инварианта: сверяется со
  /// списком в `buildOverrideOptions`.
  static const mirroredFields = <String>{
    'auto_redirect',
    'include_package',
  };
}

/// Наложить `OverrideOptions` на [configJson] так же, как это делает ядро в
/// `daemon/instance.go:92-101`.
///
/// Возвращает НОВЫЙ JSON-текст (вход не мутируется). Если текст не парсится —
/// возвращает его как есть: пусть `formatConfig` на нём и споткнётся, решение
/// об ошибке принимает один слой, а не два.
///
/// Четыре грабли, названные командой ядра, — все воспроизведены здесь:
///
/// 1. **только ПЕРВЫЙ tun-inbound** (в цикле ядра стоит `break`), не все;
/// 2. `auto_redirect` — **присваивание**, перетирает значение профиля;
/// 3. `include_package` — **`append`**: пакеты профиля остаются, свой
///    дописывается ПОСЛЕ них. Порядок значим для байтового сравнения — не
///    сортировать и не дедуплицировать;
/// 4. **нет tun-inbound → не применять ничего.**
///
/// Пятую — `Listable[string]` с одним элементом сериализуется голой строкой,
/// а не массивом из одного — воспроизводить НЕ нужно: результат уходит в
/// `formatConfig`, и правило применится само с обеих сторон.
String applyOverrides(String configJson, OverrideSnapshot override) {
  final Map<String, dynamic> config;
  try {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) return configJson;
    config = decoded;
  } catch (_) {
    return configJson;
  }

  final inbounds = config['inbounds'];
  if (inbounds is! List) return configJson; // грабля 4

  // Грабля 1 — первый tun-inbound и только он.
  Map<String, dynamic>? tun;
  for (final i in inbounds) {
    if (i is Map<String, dynamic> && i['type'] == 'tun') {
      tun = i;
      break;
    }
  }
  if (tun == null) return configJson; // грабля 4

  // Грабля 2 — присваивание. Ядро пишет поле безусловно, поэтому и мы: false
  // тоже значение (профиль мог держать true, override его перетирает).
  //
  // `omitempty` у `auto_redirect` (option/tun.go) означает, что false из
  // канонической формы выпадет — но это забота formatConfig, не наша. Пишем
  // ровно то, что ядро положило в структуру.
  tun['auto_redirect'] = override.autoRedirect;

  // §124 — allow-режим определяется наличием `include_package` у ЭТОГО tun'а
  // (та же проверка, что в `buildOverrideOptions`). В deny native свой пакет не
  // добавляет вовсе.
  final isAllowMode = tun.containsKey('include_package');
  if (override.includeSelfPackage && isAllowMode) {
    // Грабля 3 — append в конец, без сортировки и дедупликации.
    final existing = tun['include_package'];
    final packages = <String>[
      if (existing is List) ...existing.map((e) => '$e')
      else if (existing is String) existing,
      PlatformChannels.packageName,
    ];
    tun['include_package'] = packages;
  }

  return jsonEncode(config);
}

/// Вердикт сравнения. Три состояния, а не bool: «не смогли ответить» обязано
/// отличаться от «равны», иначе на любом сбое ядра плашка молча исчезнет.
enum StalenessVerdict {
  /// Канонические формы совпали — ядро крутит семантически тот же конфиг.
  /// Плашка не нужна.
  ///
  /// Не криптографическое равенство: в принципе два разных текста могут дать
  /// одну каноническую форму. Это ЖЕЛАЕМОЕ поведение — такие тексты поднимают
  /// идентичное ядро. Обратной ошибки (сказать «равны», когда семантика
  /// разошлась) схема не делает.
  fresh,

  /// Формы разошлись — рестарт/reload реально что-то изменит. Плашка нужна.
  stale,

  /// Ответить нельзя: ядро не отдало каноническую форму или снапшот
  /// (невалидный конфиг, старое ядро без метода, attached-путь, timeout).
  /// Вызывающий деградирует консервативно — показывает плашку.
  unknown,
}

/// Сравнить каноническую форму сохранённого конфига с формой работающего.
///
/// [canonicalSaved] — `formatConfig(applyOverrides(saved, override))`.
/// [runningSnapshot] — `GetRunningConfig().Content()`, уже канонический
/// (ядро отдаёт его тем же энкодером).
///
/// `null` с любой стороны → [StalenessVerdict.unknown]. Ядро подтвердило, что
/// консервативный дефолт корректен: лучше лишняя плашка, чем пропущенное
/// изменение.
StalenessVerdict compareCanonical({
  required String? canonicalSaved,
  required String? runningSnapshot,
}) {
  if (canonicalSaved == null || canonicalSaved.isEmpty) {
    return StalenessVerdict.unknown;
  }
  if (runningSnapshot == null || runningSnapshot.isEmpty) {
    return StalenessVerdict.unknown;
  }
  return canonicalSaved == runningSnapshot
      ? StalenessVerdict.fresh
      : StalenessVerdict.stale;
}
