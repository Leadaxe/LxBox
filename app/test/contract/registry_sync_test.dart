import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/parser/hysteria2_obfs.dart';
import 'package:lxbox/services/parser/utls_fingerprint.dart';

// Sync-тесты реестра контракта (SPEC 103, фаза 2), сторона LxBox.
// Парные к core/config/subscription/registry_sync_test.go.
//
// Реестр объявлен нормативным источником словарей (D-020), но нормативность
// без проверки — просто текст: словарь в коде уезжает, реестр остаётся, и обе
// стороны расходятся молча. На Go-стороне такой тест сразу нашёл gecko,
// который добавили в парсер, но забыли внести в allowlists.json.

const _contractRoot = 'contract';

Map<String, dynamic>? _loadAllowlists() {
  final file = File('$_contractRoot/registry/allowlists.json');
  if (!file.existsSync()) return null; // контракт не синхронизирован
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
  // side: export — «вид источника, которого схема не знает». У мобилы
  // провайдерских групп как отдельного вида источника нет.
  'backup_source_kind_unsupported',
  // tag.mask подписки — поле модели лаунчера; у мобилы prefix/postfix.
  'backup_tag_mask_dropped',
  // Локальные Направления ИСТОЧНИКА — упразднённый класс лаунчера.
  'backup_local_direction_dropped',
  // side: export — явный тег замены папки/подписки; свёртки у мобилы нет.
  'backup_replace_tag_derived',
};

/// Коды LxBox, которых в реестре пока НЕТ.
///
/// Это долг контракта, а не разрешение расходиться: реестр объявлен
/// нормативным словарём (D-020), и код, живущий только в приложении,
/// вторая сторона не увидит. Пока владелец контракта их не завёл, тест
/// держит список явным — чтобы долг был виден, а не растворился.
const _notYetInRegistry = <String>{
  'backup_dns_entry_skipped',
  'backup_warp_skipped',
};

Map<String, dynamic>? _loadBackupWarnings() {
  final file = File('$_contractRoot/registry/backup_warnings.json');
  if (!file.existsSync()) return null;
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
};

void main() {
  final allowlists = _loadAllowlists();
  if (allowlists == null) return;

  group('contract registry sync', () {
    // uTLS: чужой отпечаток валит ВЕСЬ конфиг, словарь обязан совпадать.
    test('utls_fingerprints', () {
      _checkAllowlist('utls_fingerprints', kUtlsFingerprints, allowlists);
    });

    test('hysteria2_obfs', () {
      _checkAllowlist('hysteria2_obfs', kHysteria2ObfsTypes, allowlists);
    });

    // §401 — словарь кодов LX Backup. Сверка ДВУСТОРОННЯЯ: односторонняя
    // ловила бы только «код есть в коде, но нет в реестре» и молчала бы о
    // противоположном — коде, который реестр объявил, а мобила не эмитит
    // (потеря, о которой пользователю никто не скажет).
    test('backup_warnings ↔ kWarn*', () {
      final registry = _loadBackupWarnings();
      expect(registry, isNotNull, reason: 'нет registry/backup_warnings.json');

      final registryCodes = registry!.keys.toSet();

      // Код в приложении, которого нет в реестре, — либо забытая запись
      // реестра, либо самодеятельность: словарь нормативен (D-020).
      final missingInRegistry =
          _codesInCode.difference(registryCodes).difference(_notYetInRegistry).toList()
            ..sort();
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

      // То же для долга реестра: код, который владелец контракта завёл,
      // обязан выйти из списка-заглушки.
      final staleDebt =
          _notYetInRegistry.intersection(registryCodes).toList()..sort();
      expect(staleDebt, isEmpty,
          reason: 'код уже есть в реестре — убрать из _notYetInRegistry');

      // Каждый чужой код обязан существовать в реестре: опечатка в списке
      // исключений иначе тихо ослабила бы обе сверки.
      final unknownForeign =
          _launcherOnlyBackupCodes.difference(registryCodes).toList()..sort();
      expect(unknownForeign, isEmpty,
          reason: 'в _launcherOnlyBackupCodes код, которого нет в реестре');
    });

    // Значение вне словаря обязано отвергаться — иначе allowlist декоративен.
    test('значения вне словаря отвергаются', () {
      expect(kHysteria2ObfsTypes.contains('nonsense'), isFalse);
      expect(normalizeUtlsFingerprintValue('garbage').junk, isTrue);
    });
  });
}
