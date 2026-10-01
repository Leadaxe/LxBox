import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/parser/uri_utils.dart'
    show kMaxDetourDepth, maxAmneziaLinkLength, maxURILength;
import 'package:lxbox/services/parser/utls_fingerprint.dart';

// Sync-тесты реестра контракта (SPEC 103, фаза 2), сторона LxBox.
// Парные к core/config/subscription/registry_sync_test.go.
//
// Реестр объявлен нормативным источником словарей (D-020), но нормативность
// без проверки — просто текст: словарь в коде уезжает, реестр остаётся, и обе
// стороны расходятся молча. На Go-стороне такой тест сразу нашёл gecko,
// который добавили в парсер, но забыли внести в allowlists.json.


Map<String, dynamic> _loadAllowlists() {
  final file = File('$kRegistryRoot/registry/allowlists.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (data['allowlists'] as Map).cast<String, dynamic>();
}

List<String> _values(Map<String, dynamic> allowlists, String name) {
  final entry = allowlists[name];
  expect(entry, isNotNull, reason: 'в реестре нет списка "$name"');
  return ((entry as Map)['values'] as List).cast<String>();
}

void _checkAllowlist(String name, Set<String> code, Map<String, dynamic> reg) {
  final registry = _values(reg, name).toSet();
  final missingInRegistry = code.difference(registry).toList()..sort();
  final missingInCode = registry.difference(code).toList()..sort();

  expect(missingInRegistry, isEmpty,
      reason: '$name: код принимает значения, которых нет в реестре — '
          'реестр нормативен (D-020): либо внести, либо убрать из кода');
  expect(missingInCode, isEmpty,
      reason: '$name: реестр объявляет значения, которых код не принимает');
}

/// Коды LX Backup, которые эмитит СТОРОНА ЛАУНЧЕРА, а LxBox — нет.
///
/// Список явный, а не «чего нет в коде, то и не наше»: молчаливый пропуск
/// превратил бы тест в декорацию — забытый на мобиле код выглядел бы ровно
/// как чужой. Обоснование берётся из поля `side` реестра и из описания кода:
/// это границы, которых у мобилы нет (свёртка папки в группу с явным тегом,
/// маска тегов подписки, локальные Направления источника).
const _launcherOnlyBackupCodes = <String>{
  // tag.mask подписки — поле модели лаунчера; у мобилы prefix/postfix.
  'backup_tag_mask_dropped',
  // Локальные Направления ИСТОЧНИКА — упразднённый класс лаунчера.
  'backup_local_direction_dropped',
  // Контракт 1.0.1, ответ LxBox 5 (TASKS_LXBOX.md §17.8): неизвестную строку
  // include LxBox хранит и на импорте молчит, предупреждает сборка (кейс
  // v10_direction_include.expected.lxbox.json).
  'backup_direction_include_dropped',
};

Map<String, dynamic> _loadBackupWarnings() {
  final file = File('$kRegistryRoot/registry/backup_warnings.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (data['warnings'] as Map).cast<String, dynamic>();
}

/// Все константы kWarn* из lib/services/lx_backup.dart.
///
/// Перечислены поимённо: рефлексии по константам библиотеки в Dart нет, а
/// парсить исходник значило бы проверять текст, а не то, что скомпилировано.
/// Новая константа, забытая здесь, вылезет второй половиной сверки —
/// реестр объявит код, которого «код не эмитит».
const _codesInCode = <String>{
  kWarnUnknownOutbound,
  kWarnFinalDropped,
  kWarnUnknownPreset,
  kWarnVarSkipped,
  kWarnUnknownField,
  kWarnExtensionsDropped,
  kWarnFieldTypeMismatch,
  kWarnSourceFlagDropped,
  kWarnLabelDropped,
  kWarnSourceIdentityDropped,
  kWarnLocalOnlyDropped,
  kWarnDirectionExists,
  kWarnChainExists,
  kWarnDnsEntrySkipped,
  kWarnWarpSkipped,
  // §438 — чтение контракта 1.0: отбраковка записи секции узла (норма B3) и
  // запись `sources[]` вида, которому здесь нет места (читатель отвергает
  // её тем же кодом, что писатель, BACKUP.md §2).
  kWarnSectionRecordDropped,
  kWarnSourceKindUnsupported,
  kWarnGroupDegraded,
};

void main() {
  final allowlists = _loadAllowlists();

  group('contract registry sync', () {
    // uTLS: чужой отпечаток валит ВЕСЬ конфиг, словарь обязан совпадать.
    test('utls_fingerprints', () {
      _checkAllowlist('utls_fingerprints', kUtlsFingerprints, allowlists);
    });

    // §547 A2 — allowlist `hysteria2_obfs` в коде больше не зеркалится:
    // `kHysteria2ObfsTypes` снят, obfs судит enum реестра.

    // §401 — словарь кодов LX Backup. Сверка ДВУСТОРОННЯЯ: односторонняя
    // ловила бы только «код есть в коде, но нет в реестре» и молчала бы о
    // противоположном — коде, который реестр объявил, а мобила не эмитит
    // (потеря, о которой пользователю никто не скажет).
    test('backup_warnings ↔ kWarn*', () {
      final registry = _loadBackupWarnings();
      final registryCodes = registry.keys.toSet();

      // Код в приложении, которого нет в реестре, — либо забытая запись
      // реестра, либо самодеятельность: словарь нормативен (D-020).
      final missingInRegistry =
          _codesInCode.difference(registryCodes).toList()..sort();
      expect(missingInRegistry, isEmpty,
          reason: 'коды эмитятся приложением, но реестр их не знает — '
              'внести в registry/backup_warnings.json или убрать из кода');

      // Обратная сторона: реестр объявил код, а LxBox его не эмитит.
      // Законно ТОЛЬКО если это сторона лаунчера и она названа явно.
      final missingInCode = registryCodes
          .difference(_codesInCode)
          .difference(_launcherOnlyBackupCodes)
          .toList()
        ..sort();
      expect(missingInCode, isEmpty,
          reason: 'реестр объявляет коды, которых LxBox не эмитит и которые '
              'не отнесены к стороне лаунчера — либо реализовать, либо '
              'внести в _launcherOnlyBackupCodes с обоснованием');

      // Список «чужих» не должен протухать: код, доехавший до мобилы,
      // обязан выйти из него, иначе исключение станет вечным.
      final staleForeign =
          _launcherOnlyBackupCodes.intersection(_codesInCode).toList()..sort();
      expect(staleForeign, isEmpty,
          reason: 'код объявлен «стороной лаунчера», но LxBox его эмитит');

      // Каждый чужой код обязан существовать в реестре: опечатка в списке
      // исключений иначе тихо ослабила бы обе сверки.
      final unknownForeign =
          _launcherOnlyBackupCodes.difference(registryCodes).toList()..sort();
      expect(unknownForeign, isEmpty,
          reason: 'в _launcherOnlyBackupCodes код, которого нет в реестре');
    });

    // Значение вне словаря обязано отвергаться — иначе allowlist декоративен.
    test('значения вне словаря отвергаются', () {
      expect(normalizeUtlsFingerprintValue('garbage').junk, isTrue);
    });

    // §514 / контракт 1.1.50 (D133-52) — ЛИМИТЫ. Расхождение сторон по пределу
    // длины ссылки закрыто волной 1.1.50 (у лаунчера стояло 8192, канон —
    // 65536), и с этого номера у обеих сторон значение одно. Константа
    // остаётся константой намеренно: предел работает НА ВХОДЕ конвейера, до
    // того как реестр вообще загружен (`parseUri` зовётся и из тестов без
    // ассетов), — но она обязана СОВПАДАТЬ с реестром, иначе расхождение
    // вернётся молча, как уже было.
    test('лимиты реестра совпадают с константами кода', () {
      final file = File('$kRegistryRoot/registry/limits.json');
      final limits = ((jsonDecode(file.readAsStringSync())
              as Map<String, dynamic>)['limits'] as Map)
          .cast<String, dynamic>();
      int value(String name) {
        final e = limits[name];
        expect(e, isNotNull, reason: 'в реестре нет лимита "$name"');
        return ((e as Map)['value'] as num).toInt();
      }

      expect(maxURILength, value('max_uri_length'),
          reason: 'предел длины ссылки разошёлся с реестром: у сторон он '
              'общий с контракта 1.1.50, и расхождение означает, что длинная '
              'валидная ссылка принимается одним приложением и отбивается '
              'другим');
      expect(maxAmneziaLinkLength, value('amnezia_link_max_bytes'),
          reason: 'потолок сырой vpn://-ссылки разошёлся с реестром');
      expect(kMaxDetourDepth, value('max_detour_chain'),
          reason: 'предел длины цепочки релеев разошёлся с реестром');
    });
  });
}
