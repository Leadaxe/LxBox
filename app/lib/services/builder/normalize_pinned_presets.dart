import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../selectable_to_custom.dart';

/// §264 — нормализация pinned-пресетов в списке custom rules.
///
/// Locked+pinned пресет (напр. `traffic-processing`, `pinned: 0`) — продуктовый
/// инвариант: он ДОЛЖЕН присутствовать и стоять на своей позиции, независимо от
/// того, что в storage (fresh install, backup-restore, ручная правка Debug API,
/// апгрейд со старого storage где пресета ещё не было).
///
/// Критично для порядка `route.rules`: `traffic-processing` несёт
/// `sniff`/`hijack-dns`/`resolve`, а `sniff` обязан быть ПЕРВЫМ правилом
/// (извлекает домен до матчинга роутинга). `applyAllCustomRules` эмитит правила
/// в storage-order, поэтому pinned-пресет должен физически идти первым.
///
/// Делает:
/// 1. **Seed** — для каждого pinned-пресета шаблона, которого нет в списке,
///    добавляет его (enabled по `defaultEnabled`). Апгрейд-safe: старые юзеры
///    получают новый pinned-пресет.
/// 2. **Sort** — pinned-пресеты в начало по возрастанию `pinned`-индекса,
///    остальные правила сохраняют относительный порядок после них.
///
/// Значения vars существующего пресета сохраняются (seed только если его нет).
/// Идемпотентна: повторный вызов на нормализованном списке ничего не меняет.
List<CustomRule> normalizePinnedPresets(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
  WizardTemplate template,
) {
  // pinned-пресеты шаблона, отсортированные по индексу (0 первым).
  final pinnedSpecs = selectableRules.where((r) => r.isPinned).toList()
    ..sort((a, b) => (a.pinned ?? 0).compareTo(b.pinned ?? 0));
  if (pinnedSpecs.isEmpty) return customRules;

  final pinnedIds = {for (final s in pinnedSpecs) s.presetId};

  // Уже присутствующие pinned-пресеты (по presetId) — сохраняем их запись
  // (varsValues/enabled юзера). Остальные правила — «хвост».
  final existingPinned = <String, CustomRule>{};
  final tail = <CustomRule>[];
  for (final cr in customRules) {
    final pid = switch (cr) {
      CustomRulePreset(:final presetId) => presetId,
      _ => null,
    };
    if (pid != null && pinnedIds.contains(pid)) {
      existingPinned.putIfAbsent(pid, () => cr); // первый wins, дубли в хвост? нет — дропаем
    } else {
      tail.add(cr);
    }
  }

  // Собираем: pinned по порядку спеки (существующая запись или seed), затем хвост.
  final head = <CustomRule>[];
  for (final spec in pinnedSpecs) {
    final existing = existingPinned[spec.presetId];
    if (existing != null) {
      head.add(existing);
    } else {
      // Seed: locked-пресет всегда enabled (default:true у traffic-processing);
      // selectableRuleToCustom ставит enabled из defaultEnabled на этапе seed
      // отдельно — здесь создаём напрямую с enabled по defaultEnabled.
      final seeded = selectableRuleToCustom(spec, template);
      head.add(CustomRulePreset(
        name: seeded.name,
        presetId: seeded.presetId,
        enabled: spec.defaultEnabled,
        varsValues: seeded.varsValues,
      ));
    }
  }

  return [...head, ...tail];
}

/// §265/§266 — вычистить ref-var значения из `varsValues` пресетов.
///
/// Ref-var (`{"ref": name}`) хранит значение в ГЛОБАЛЬНОМ userVars, НЕ в
/// varsValues. Но при переезде обычной preset-var в ref (напр. `resolve_enabled`
/// стала ref в §265) старое значение остаётся в varsValues осиротевшим — и
/// subtitle/Debug API/любой varsValues-читатель показывает застрявшее неверное
/// значение (resolve_enabled: true, когда глобаль уже false).
///
/// Проходим по каждому preset-правилу: если в его varsValues есть ключ, который
/// в шаблоне объявлен как ref-var, — удаляем. Возвращает новый список (или тот
/// же, если чистить нечего — вызывающий сравнивает и персистит только при
/// изменении). Идемпотентна.
List<CustomRule> stripRefVarsFromVarsValues(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
) {
  // presetId → множество имён ref-vars этого пресета.
  final refNamesByPreset = <String, Set<String>>{};
  for (final sr in selectableRules) {
    final refs = {for (final v in sr.vars) if (v.isRef) v.ref};
    if (refs.isNotEmpty) refNamesByPreset[sr.presetId] = refs;
  }
  if (refNamesByPreset.isEmpty) return customRules;

  var changed = false;
  final out = <CustomRule>[];
  for (final cr in customRules) {
    if (cr is CustomRulePreset) {
      final refs = refNamesByPreset[cr.presetId];
      if (refs != null && cr.varsValues.keys.any(refs.contains)) {
        final cleaned = {
          for (final e in cr.varsValues.entries)
            if (!refs.contains(e.key)) e.key: e.value,
        };
        out.add(cr.copyWith(varsValues: cleaned));
        changed = true;
        continue;
      }
    }
    out.add(cr);
  }
  return changed ? out : customRules;
}
