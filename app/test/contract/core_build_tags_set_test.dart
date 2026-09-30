// §591 (025-CONTRACT_REGISTRY, доп. пункт «Зеркало build-тегов — ручная
// копия»): `core_build_tags_pin_test` в node_core_gate_test.dart сверяет
// только версию (`kCoreBuildTagsPin` == `android/libbox.version`). Этот тест
// разбирает документированный набор тегов AAR из `docs/KERNEL.md` («## AAR
// build tags», блок ```…``` после «NOT in the client:») и сверяет его
// ПОЛНОСТЬЮ (состав, не только длину) с `kCoreBuildTags`. Падает, если набор
// тегов разошёлся с докой молча — второе полукольцо зеркала, которого не
// хватало.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';

/// Достаёт список тегов из блока ```…``` под заголовком «## AAR build tags»
/// в `docs/KERNEL.md`. Теги перечислены через запятую, возможно на нескольких
/// строках, с висячей запятой в конце.
Set<String> _tagsFromKernelDoc(String markdown) {
  final headingIdx = markdown.indexOf('## AAR build tags');
  expect(headingIdx, greaterThanOrEqualTo(0),
      reason: 'docs/KERNEL.md: заголовок "## AAR build tags" не найден — '
          'документ переструктурирован, сверься вручную');
  final afterHeading = markdown.substring(headingIdx);
  final fenceStart = afterHeading.indexOf('```');
  expect(fenceStart, greaterThanOrEqualTo(0),
      reason: 'docs/KERNEL.md: под "## AAR build tags" нет блока ```…``` '
          'с тегами');
  final fenceBodyStart = fenceStart + 3;
  final fenceEnd = afterHeading.indexOf('```', fenceBodyStart);
  expect(fenceEnd, greaterThan(fenceBodyStart),
      reason: 'docs/KERNEL.md: блок тегов не закрыт');
  final body = afterHeading.substring(fenceBodyStart, fenceEnd);
  final tags = body
      .split(RegExp(r'[,\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  expect(tags, isNotEmpty,
      reason: 'docs/KERNEL.md: блок тегов распознан пустым');
  return tags;
}

void main() {
  test('набор build-тегов из docs/KERNEL.md совпадает с kCoreBuildTags', () {
    final doc = File('../docs/KERNEL.md');
    expect(doc.existsSync(), isTrue,
        reason: 'docs/KERNEL.md не найден относительно app/ — '
            'тест ожидает путь ../docs/KERNEL.md');
    final docTags = _tagsFromKernelDoc(doc.readAsStringSync());

    final onlyInDoc = docTags.difference(kCoreBuildTags);
    final onlyInCode = kCoreBuildTags.difference(docTags);

    expect(onlyInDoc, isEmpty,
        reason: 'docs/KERNEL.md перечисляет теги, которых нет в '
            'kCoreBuildTags (core_chain_capability.dart): $onlyInDoc — '
            'либо бамп ядра забыл обновить код, либо дока опережает код');
    expect(onlyInCode, isEmpty,
        reason: 'kCoreBuildTags содержит теги, которых нет в документации '
            'docs/KERNEL.md: $onlyInCode — обнови "## AAR build tags" или '
            'проверь, что тег действительно есть в sharedTags AAR');
  });
}
