import 'package:flutter/material.dart';

import '../../models/dns_ref.dart';
import '../../services/builder/domain_resolver_ref.dart'
    show domainResolverServer;
import '../../services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody, templateDnsServerTag;
import '../../services/l10n/locale_controller.dart';

/// §695 правило 4 — зависимости шаблонных записей [roots] по каталогу
/// [templateByTag] (тег → обёртка), которых нет в [present] и среди
/// [roots]: члены группы (рекурсивно) и цель `domain_resolver` (строка или
/// `{server}`, после подстановки дефолтов vars), в порядке обхода. Тег вне
/// каталога (сервер пресета) пропускается. — pure.
List<String> dnsCatalogDependencies(
  Iterable<String> roots,
  Map<String, Map<String, dynamic>> templateByTag,
  Set<String> present,
) {
  final seen = <String>{...present, ...roots};
  final out = <String>[];
  final queue = [...roots];
  while (queue.isNotEmpty) {
    final tag = queue.removeAt(0);
    final wrapper = templateByTag[tag];
    if (wrapper == null) continue;
    final body = resolveTemplateDnsServerBody(wrapper) ?? const {};
    final refs = <String?>[
      if (body['type'] == 'group')
        for (final m in (body['servers'] as List<dynamic>? ?? const []))
          m?.toString(),
      domainResolverServer(body['domain_resolver']),
    ];
    for (final t in refs) {
      if (t == null || t.isEmpty || !templateByTag.containsKey(t)) continue;
      if (!seen.add(t)) continue;
      out.add(t);
      queue.add(t);
    }
  }
  return out;
}

/// §680 — что вернула страница «Add DNS server»: [custom] — пользователь
/// выбрал строку «Custom server», вызывающий открывает inline-редактор.
enum DnsServerCatalogResult { custom }

/// §680 — полноэкранная страница «Add DNS server» по (+) секции серверов
/// (паттерн §117 №8: экраны, не шиты). Первая строка — свой сервер
/// (inline-редактор), ниже каталог `dns_options.servers` шаблона в его
/// порядке: «Add» дописывает шаблонную запись в конец списка, у уже
/// присутствующих — неактивная «Added». Меню ⋮ — «Add all defaults».
///
/// Каталог — разность «теги шаблона минус теги списка»; версия шаблона не
/// хранится. Страница не пишет хранилище сама: [onAdd] отдаёт записи
/// вкладке, та кладёт их в список и ставит dirty по общей воронке.
class DnsServerCatalogScreen extends StatefulWidget {
  const DnsServerCatalogScreen({
    super.key,
    required this.templateServers,
    required this.presentTags,
    required this.onAdd,
  });

  /// Обёртки `{description, enabled, vars?, server}` в порядке шаблона.
  final List<Map<String, dynamic>> templateServers;

  /// Теги, которые уже есть в списке пользователя (любого вида).
  final Set<String> presentTags;

  /// Добавить записи в конец списка.
  final void Function(List<DnsServerTemplate> refs) onAdd;

  @override
  State<DnsServerCatalogScreen> createState() => _DnsServerCatalogScreenState();
}

class _DnsServerCatalogScreenState extends State<DnsServerCatalogScreen> {
  late final Set<String> _present = {...widget.presentTags};

  DnsServerTemplate _refOf(Map<String, dynamic> wrapper, String tag) =>
      DnsServerTemplate(enabled: wrapper['enabled'] != false, tag: tag);

  String _titleOf(Map<String, dynamic> wrapper, String tag) {
    final d = wrapper['description']?.toString() ?? '';
    return d.isNotEmpty ? d : tag;
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  late final Map<String, Map<String, dynamic>> _byTag = {
    for (final w in widget.templateServers)
      ?templateDnsServerTag(w): w,
  };

  /// §695 правило 4 — зависимости [roots] включёнными записями каталога.
  List<DnsServerTemplate> _dependencies(Iterable<String> roots) => [
        for (final t in dnsCatalogDependencies(roots, _byTag, _present))
          DnsServerTemplate(enabled: true, tag: t),
      ];

  /// «Also added: …» — подписи записей, добавленных по цепочке.
  String _alsoAdded(List<DnsServerTemplate> deps) => getLocalText.s(
      "Also added: %s",
      deps.map((d) => _titleOf(_byTag[d.tag] ?? const {}, d.tag)).join(', '));

  void _add(Map<String, dynamic> wrapper, String tag) {
    if (_present.contains(tag)) return;
    final deps = _dependencies([tag]);
    widget.onAdd([_refOf(wrapper, tag), ...deps]);
    setState(() => _present
      ..add(tag)
      ..addAll(deps.map((d) => d.tag)));
    final added = getLocalText.s("Added \"%s\"", _titleOf(wrapper, tag));
    _snack(deps.isEmpty ? added : '$added\n${_alsoAdded(deps)}');
  }

  /// Досев всех отсутствующих — как посев первого запуска.
  void _addAll() {
    final refs = <DnsServerTemplate>[];
    for (final w in widget.templateServers) {
      final tag = templateDnsServerTag(w);
      if (tag == null || _present.contains(tag)) continue;
      refs.add(_refOf(w, tag));
    }
    if (refs.isEmpty) {
      _snack(getLocalText.s("All defaults are already in the list"));
      return;
    }
    // §695 правило 4 — каталог целиком, зависимости вне его не тянутся;
    // замыкание — для единообразия (пусто, пока каталог замкнут).
    final deps = _dependencies(refs.map((r) => r.tag));
    widget.onAdd([...refs, ...deps]);
    setState(() => _present
      ..addAll(refs.map((r) => r.tag))
      ..addAll(deps.map((d) => d.tag)));
    final added = getLocalText.plural("Added %d servers", refs.length);
    _snack(deps.isEmpty ? added : '$added\n${_alsoAdded(deps)}');
  }

  /// `tag · type · addr` — как у тайла сервера; адрес с `@`-плейсхолдером —
  /// дефолт переменной.
  String _subtitleOf(Map<String, dynamic> wrapper, String tag) {
    final body = resolveTemplateDnsServerBody(wrapper) ?? const {};
    final type = body['type']?.toString() ?? '';
    final addr = body['server']?.toString() ?? '';
    final groupInfo = type == 'group'
        ? ' · ${(body['mode'] as String?) ?? 'stable'}'
              ' · ${(body['servers'] as List?)?.length ?? 0}'
        : '';
    return '$tag · $type$groupInfo${addr.isNotEmpty ? ' · $addr' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtle = TextStyle(
      fontSize: 12,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Add DNS server")),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'add_all') _addAll();
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                value: 'add_all',
                child: Text(getLocalText.s("Add all defaults")),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 24),
        children: [
          _CatalogRow(
            title: getLocalText.s("Custom server"),
            subtitle: getLocalText.s("Your own UDP / DoT / DoH / group…"),
            added: false,
            subtitleStyle: subtle,
            onAdd: () =>
                Navigator.pop(context, DnsServerCatalogResult.custom),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              getLocalText.s("From template").toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final w in widget.templateServers)
            if (templateDnsServerTag(w) case final tag?)
              _CatalogRow(
                key: ValueKey('dns-catalog-$tag'),
                title: _titleOf(w, tag),
                subtitle: _subtitleOf(w, tag),
                added: _present.contains(tag),
                subtitleStyle: subtle,
                onAdd: () => _add(w, tag),
              ),
        ],
      ),
    );
  }
}

/// Строка каталога по образцу `PresetCatalogTile`: заголовок + кнопка
/// справа, подпись ниже, разделитель.
class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.added,
    required this.subtitleStyle,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final bool added;
  final TextStyle subtitleStyle;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              TextButton.icon(
                icon: Icon(added ? Icons.check : Icons.add, size: 16),
                label: Text(
                    added ? getLocalText.s("Added") : getLocalText.s("Add")),
                onPressed: added ? null : onAdd,
              ),
            ],
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(subtitle, style: subtitleStyle),
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
