// §393 C5 — умеет ли установленное ядро outbound'ы типа `chain` (SPEC 110).
//
// Тип живёт в форке за тегом сборки `with_lx_chain`
// (`sing-box-lx include/lx_chain.go`). Ядро без него отвергает конфиг
// ЦЕЛИКОМ:
//
//     FATAL decode config: outbounds[2]: unknown outbound type: chain
//
// То есть ОДНА настроенная цепочка оставила бы пользователя вообще без VPN, а
// не без одного маршрута. Отсюда гейт: сборка спрашивает ДО эмиссии и
// деградирует цепочку (`chain_unsupported_by_core`), а не отдаёт ядру «пусть
// разберётся».
//
// ЧЕМ ГЕЙТ МОБИЛЫ ОТЛИЧАЕТСЯ ОТ ЛАУНЧЕРНОГО. Лаунчер запускает
// `sing-box version` и читает строку `Tags:` — то есть спрашивает у ядра
// прямо, есть ли `with_lx_chain` (`core/core_chain_capability.go`). На мобиле
// ядро — это НЕ бинарь, а вкомпилированный AAR (libbox), и списка тегов
// сборки он наружу не отдаёт вовсе: `Libbox.version()` возвращает ровно
// `constant.Version`, то есть git-тег релиза без ведущего `v`
// (`experimental/libbox/setup.go:111`, ldflags
// `cmd/internal/build_shared/tag.go`). Единственный доступный шов — версия,
// и гейт сравнивает её с релизом, в котором тег впервые попал в AAR:
// **v1.14.0-lx.27-rc.5** (`sing-box-lx cmd/internal/build_libbox/main.go:93`).
//
// ВЕРДИКТ КОНСЕРВАТИВЕН — ровно как у naive-пробы лаунчера: строка версии
// пустая, не разобралась или имеет неожиданный вид → считаем, что поддержка
// ЕСТЬ. Деградировать на догадке нельзя: это отняло бы у пользователя рабочий
// маршрут, а конфиг, отвергнутый ядром, пользователь хотя бы увидит ошибкой
// старта. Обратная ошибка (тихо выкинуть цепочку у ядра, которое её умеет)
// не диагностируется вообще.

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Минимальный релиз ядра с типом `chain` в AAR: `1.14.0-lx.27-rc.5`.
/// Строка — без ведущего `v`, как её отдаёт `Libbox.version()`.
const String kChainMinCoreVersion = '1.14.0-lx.27-rc.5';

/// Разобранная версия ядра форка: `<major>.<minor>.<patch>-lx.<lx>[-rc.<rc>]`.
///
/// Отдельный тип, а не кортеж строк: сравнение версий строкой — классическая
/// ошибка («rc.10» < «rc.5» лексикографически), и держать порядок в одном
/// месте безопаснее, чем повторять его на каждом колл-сайте.
class CoreVersion implements Comparable<CoreVersion> {
  const CoreVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.lx,
    required this.rc,
  });

  final int major;
  final int minor;
  final int patch;

  /// Номер ревизии форка (`-lx.N`).
  final int lx;

  /// Номер release candidate (`-rc.M`). `null` = финальный релиз, и он
  /// СТАРШЕ любого своего rc: `1.14.0-lx.27` новее `1.14.0-lx.27-rc.9`.
  final int? rc;

  /// Разбор строки `Libbox.version()`.
  ///
  /// `null`, если строка не похожа на версию форка: без `-lx.N` это апстрим
  /// sing-box или неизвестная сборка, и вердикт по ней выносит вызывающий
  /// (см. [coreSupportsChain] — он в этом случае fail-open'ит).
  ///
  /// Терпимо к ведущему `v` (тег репозитория) и к хвосту после номера rc
  /// (`-lx.27-rc.5-g1a2b3c4` — сборка не с тега, `build_shared/tag.go`
  /// дописывает короткий хеш коммита): хвост игнорируется, потому что он
  /// говорит «после этого rc», а не «до».
  static CoreVersion? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = _re.firstMatch(s.startsWith('v') ? s.substring(1) : s);
    if (m == null) return null;
    return CoreVersion(
      major: int.parse(m.group(1)!),
      minor: int.parse(m.group(2)!),
      patch: int.parse(m.group(3)!),
      lx: int.parse(m.group(4)!),
      rc: m.group(5) == null ? null : int.parse(m.group(5)!),
    );
  }

  // `$` намеренно нет: сборка не с тега несёт хвост `-g<hash>`.
  static final RegExp _re =
      RegExp(r'^(\d+)\.(\d+)\.(\d+)-lx\.(\d+)(?:-rc\.(\d+))?');

  @override
  int compareTo(CoreVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (lx, other.lx),
    ]) {
      final c = pair.$1.compareTo(pair.$2);
      if (c != 0) return c;
    }
    // Финальный релиз старше любого своего rc: отсутствие rc = +∞.
    final a = rc, b = other.rc;
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  @override
  String toString() =>
      '$major.$minor.$patch-lx.$lx${rc == null ? '' : '-rc.$rc'}';
}

/// §393 C5 — знает ли ядро версии [coreVersion] тип outbound'а `chain`.
///
/// Fail-open на всём, что не удалось разобрать (пустая строка — ядро не
/// ответило; апстримная версия без `-lx.N`; мусор): см. шапку файла.
bool coreSupportsChain(String coreVersion) {
  final v = CoreVersion.parse(coreVersion);
  if (v == null) return true;
  final min = CoreVersion.parse(kChainMinCoreVersion)!;
  return v.compareTo(min) >= 0;
}

/// EN-строка предупреждения `chain_unsupported_by_core` (реестр
/// `registry/warnings.json`, параметры `version` + `tag`).
///
/// Версия ядра — В ТЕКСТЕ, как у лаунчера: пользователю, у которого цепочка
/// не работает, нужно понять, какое именно ядро у него стоит и что оно должно
/// уметь. «Ядро не поддерживает» без версии не даёт сделать следующий шаг.
String chainUnsupportedByCoreLine(String tag, String coreVersion) {
  final shown = coreVersion.trim().isEmpty ? 'of unknown version' : coreVersion.trim();
  return 'Hop chain "$tag" was skipped: the VPN core ($shown) is older than '
      '$kChainMinCoreVersion and does not know the "chain" outbound type — '
      'it would reject the whole config. Update the app to get a newer core.';
}

/// Сессионный кэш строки `Libbox.version()`.
///
/// Версия ядра в пределах запуска приложения не меняется — оно вкомпилировано
/// в APK. Кэш нужен не ради скорости, а ради ДЕТЕРМИНИЗМА сборки: конфиг
/// пересобирается на каждое изменение подписки, и если один вызов
/// MethodChannel'а отвалится по таймауту (ядро занято стартом туннеля),
/// цепочки молча исчезнут из ОДНОЙ пересборки и вернутся в следующей —
/// «мигающий» маршрут диагностировать невозможно.
///
/// Пустая строка НЕ кэшируется: она означает «ядро не ответило», а не
/// «версии нет», и следующая сборка обязана спросить снова.
class CoreVersionCache {
  CoreVersionCache._();

  static String _cached = '';

  /// Строка версии ядра; пусто, если ядро ни разу не ответило.
  static String get value => _cached;

  /// Спросить ядро, если ещё не спрашивали. [read] — источник строки
  /// (в приложении `BoxVpnClient.getCoreVersion`, в тестах — заглушка).
  static Future<String> ensure(Future<String> Function() read) async {
    if (_cached.isNotEmpty) return _cached;
    try {
      final v = (await read()).trim();
      if (v.isNotEmpty) _cached = v;
      return v;
    } catch (_) {
      // Fail-open: пустая строка → `coreSupportsChain` разрешает цепочки.
      return '';
    }
  }

  @visibleForTesting
  static void resetForTest([String value = '']) => _cached = value;
}
