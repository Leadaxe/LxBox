import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §460 W2b — страж зеркала документации контракта (`docs/contract/`).
///
/// Карточка предупреждения даёт ссылку «Learn more» на страницу кода в НАШЕМ
/// репозитории (`contractWarningDocUrl`). Ссылка собирается из кода
/// арифметически, поэтому её адрес всегда «выглядит рабочим» — а вот приедет
/// ли по нему нужный раздел, видно только здесь: у кода, потерявшего якорь на
/// странице, ссылка молча уводит в начало файла.
///
/// Проверяется зеркало, а не источник: пользователь открывает именно его.
/// Совпадение зеркала с копией контракта файл-в-байт — дело
/// `tool/check_contract_lock.dart`; здесь — что состав зеркала отвечает
/// реестру, который едет в APK.
///
/// Тесты идут из `app/`, страницы лежат в корне репозитория — отсюда `../`.
const _docsRoot = '../docs/contract';
const _assetsRoot = 'assets/contract';

/// Коды реестра, которых в зеркале ЗАКОННО нет — долг ЧУЖОГО генератора.
///
/// Страницы собирает `contract/tools/gendocs` лаунчера, а `sync_contract.sh`
/// копирует `docs/generated/**` байт в байт (свой генератор не заводится —
/// иначе побайтовое совпадение не вышло бы). Значит реестр может уехать
/// вперёд страниц: у лаунчера код приезжает в `registry/warnings.json`
/// отдельной правкой, а `docs/generated/` пересобирается позже своим
/// прогоном. Подделывать страницу у нас нельзя — она тут же разойдётся с
/// копией контракта, и это поймает `tool/check_contract_lock.dart`.
///
/// Цена послабления — ссылка «Learn more» по этому коду уводит в начало
/// страницы, пока лаунчер не пересоберёт generated. Список держать пустым:
/// каждая запись снимается ближайшим синком, который принесёт страницы.
// Пусто с контракта 1.1.42: лаунчер пересобрал docs/generated, и якорь
// `password_empty` приехал зеркалом. Долгов перед gendocs нет.
const _awaitingLauncherGendocs = <String>{};

void main() {
  final warningsMd = File('$_docsRoot/warnings.md');
  final readme = File('$_docsRoot/README.md');
  final registry = File('$_assetsRoot/registry/warnings.json');
  // Зеркала может не быть только вместе с реестром: реестр в git, так что на
  // практике skip не срабатывает — он для дерева без синхронизации.
  final skip = warningsMd.existsSync() && registry.existsSync()
      ? null
      : 'зеркало документации не синхронизировано (tool/sync_contract.sh)';

  group('§460 W2b — зеркало документации контракта', () {
    test('у каждого кода реестра есть якорь в warnings.md', () {
      final codes = ((jsonDecode(registry.readAsStringSync())
              as Map<String, dynamic>)['warnings'] as Map<String, dynamic>)
          .keys
          .toList()
        ..sort();
      expect(codes, isNotEmpty, reason: 'реестр без кодов — так не бывает');

      // gendocs ставит явный `<a id="<code>"></a>` перед заголовком раздела.
      // Явный якорь, а не slug заголовка: коды содержат подчёркивания, и
      // GitHub-slug у них совпадает с кодом, но полагаться на это правило
      // GitHub'а значит зависеть от чужого рендерера.
      final text = warningsMd.readAsStringSync();
      final anchors = RegExp(r'<a id="([^"]+)"></a>')
          .allMatches(text)
          .map((m) => m.group(1)!)
          .toSet();

      final missing = codes
          .where((c) =>
              !anchors.contains(c) && !_awaitingLauncherGendocs.contains(c))
          .toList();
      expect(missing, isEmpty,
          reason: 'коды реестра без якоря в docs/contract/warnings.md: '
              '$missing — ссылка «Learn more» по ним уведёт в начало страницы. '
              'Пересоберите зеркало: bash app/tool/sync_contract.sh');

      // Послабление одноразовое: как только лаунчер пересоберёт страницы,
      // запись обязана уйти, иначе список переживёт свой долг молча.
      final stale =
          _awaitingLauncherGendocs.where(anchors.contains).toList()..sort();
      expect(stale, isEmpty,
          reason: 'якорь у этих кодов в зеркале УЖЕ есть — уберите их из '
              '_awaitingLauncherGendocs: $stale');
    });

    test('версия в README зеркала равна assets/contract/VERSION', () {
      final version = File('$_assetsRoot/VERSION').readAsStringSync().trim();
      expect(version, isNotEmpty);
      expect(readme.existsSync(), isTrue,
          reason: 'README зеркала пишет sync_contract.sh — его нет');
      expect(readme.readAsStringSync(), contains('`$version`'),
          reason: 'README зеркала называет не ту версию контракта, что едет в '
              'APK: страницы и реестр разъехались');
    });
  }, skip: skip);
}
