import 'package:flutter/material.dart';

import '../models/node_spec.dart';
import '../services/l10n/locale_controller.dart';
import '../services/ui_helpers.dart';
import '../widgets/auto_group_form.dart';
import '../widgets/safe_bottom.dart';

export '../widgets/auto_group_form.dart' show AutoPoolCandidate;

/// §322 — редактор узла автовыбора внутри папки.
///
/// Идиома проекта ([direction_edit_screen.dart]): Navigator.push + PopScope
/// back-guard (Save/Keep/Discard) + AppBar delete/save.
///
/// Отличие от Направления: членство здесь — три режима (все / правило / список),
/// и превью показывает, кто именно попал в пул. [candidates] — узлы папки
/// (без самой группы), по ним и считается превью.
///
/// §686 — поля — общий виджет [AutoGroupForm] (он же — на Settings карточки
/// узла); экран — создание (⋮ → Add auto node…): правка существующего узла
/// идёт в карточке.
class AutoGroupEditScreen extends StatefulWidget {
  const AutoGroupEditScreen({
    super.key,
    required this.initial,
    required this.candidates,
    required this.canDelete,
  });

  /// `null` — создание нового узла.
  final AutoSelectSpec? initial;

  /// Кандидаты в пул — узлы того же контейнера: ссылка на члена
  /// `{id папки, сырой тег}` (§439), имя и флаг включения (§686).
  final List<AutoPoolCandidate> candidates;

  final bool canDelete;

  @override
  State<AutoGroupEditScreen> createState() => _AutoGroupEditScreenState();
}

/// Что вернул экран: сохранение или удаление.
sealed class AutoGroupEditResult {
  const AutoGroupEditResult();
  const factory AutoGroupEditResult.saved(AutoSelectSpec spec) = AutoGroupSaved;
  const factory AutoGroupEditResult.deleted() = AutoGroupDeleted;
}

final class AutoGroupSaved extends AutoGroupEditResult {
  final AutoSelectSpec spec;
  const AutoGroupSaved(this.spec);
}

final class AutoGroupDeleted extends AutoGroupEditResult {
  const AutoGroupDeleted();
}

class _AutoGroupEditScreenState extends State<AutoGroupEditScreen> {
  final _form = GlobalKey<AutoGroupFormState>();

  /// Снимок для сравнения «грязно ли» — то, что форма собрала при открытии.
  AutoSelectSpec? _initial;

  AutoSelectSpec? _snapshot() => _form.currentState?.snapshot();

  bool _isDirty() {
    final now = _snapshot();
    final initial = _initial;
    return now != null && initial != null && !now.sameGroupAs(initial);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _initial = _snapshot());
    });
  }

  // ── Навигация ──

  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    if (action == 'save') {
      _save();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  void _save() {
    final spec = _snapshot();
    if (spec == null) return;
    Navigator.pop(context, AutoGroupEditResult.saved(spec));
  }

  Future<void> _delete() async {
    final ok = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete auto node?"),
      message: getLocalText.s(
          "The servers it selects from stay in the folder."),
    );
    if (!mounted || ok != true) return;
    Navigator.pop(context, const AutoGroupEditResult.deleted());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dirty = _isDirty();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.initial == null
              ? getLocalText.s("New auto node")
              : getLocalText.s("Edit auto node")),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            if (widget.canDelete)
              IconButton(
                tooltip: getLocalText.s("Delete"),
                icon: Icon(Icons.delete_outline, color: cs.error),
                onPressed: _delete,
              ),
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: Icon(Icons.check,
                  color: dirty ? cs.primary : cs.onSurfaceVariant),
              onPressed: _save,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32).withSafeBottom(context),
          children: [
            AutoGroupForm(
              key: _form,
              value: widget.initial,
              candidates: widget.candidates,
              // Перерисовка — цвет кнопки Save следует за правками.
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }
}
