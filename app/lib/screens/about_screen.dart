import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/project_links.dart';
import '../services/relative_time.dart';
import '../services/update_checker.dart';
import '../services/url_launcher.dart' as ul;
import '../services/version_info.dart';
import '../vpn/box_vpn_client.dart';
import '../services/l10n/locale_controller.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  // §358 — адреса живут в общем слое `ProjectLinks` (единственный источник:
  // раньше копии лежали здесь, в automation_tab и update_checker). Локальные
  // алиасы оставлены для читаемости call-site'ов ниже.
  static const _repoUrl = ProjectLinks.repo;
  static const _singboxUpstreamUrl = ProjectLinks.singboxUpstream;
  static const _singboxLauncherUrl = ProjectLinks.launcher;

  // §361 — руководство пользователя на языке интерфейса. Пара RU/EN держится
  // синхронной CI-проверкой парности (tool/docs/parity_check.dart), поэтому
  // разделы в обеих версиях одни и те же. Ветка `main` (как у AUTOMATION.md в
  // automation_tab): в APK попадает релизный код, а релиз — это merge в main,
  // который принесёт туда и оба файла гайда.
  //
  // ВАЖНО при бэкпорте/hotfix-сборке из develop: USER_GUIDE.md (EN) создан в
  // §360-цикле и в main появится только со следующим релизом. Сборка этого
  // экрана из ветки, ещё не влитой в main, даст 404 по EN-ссылке — проверять
  // `curl -o /dev/null -w '%{http_code}'` по обоим URL перед выкладкой.
  static const guideUrlEn = ProjectLinks.guideEn;
  static const guideUrlRu = ProjectLinks.guideRu;

  /// Ссылка на руководство под язык интерфейса. Незнакомый тег (язык, для
  /// которого гайда ещё нет) → английская версия, а не 404.
  @visibleForTesting
  static String guideUrlFor(String tag) => ProjectLinks.guideFor(tag);

  /// Текущий язык интерфейса: `effectiveTag` уже разрешён до 'en'/'ru' и
  /// учитывает выбор System default.
  static String get _guideUrl =>
      guideUrlFor(LocaleController.I.effectiveTag);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("About"))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/icons/app_icon.png',
                    width: 72,
                    height: 72,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  // l10n-exempt: app name
                  'L×Box',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  // l10n-exempt: version literal, no translatable words
                  'v${VersionInfo.I.version}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _UpdateBlock(),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(getLocalText.s("User guide")),
                  subtitle: Text(getLocalText.s(
                      "How it works: channels, rules, DNS, detour, recipes")),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => ul.UrlLauncher.open(_guideUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: Text(getLocalText.s("Source Code")),
                  subtitle: const Text(_repoUrl),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => ul.UrlLauncher.open(_repoUrl),
                ),
                const Divider(height: 1),
                // VPN core version — runtime через `Libbox.version()` (вызов
                // из `BoxVpnClient.getCoreVersion`). Подгружается лениво:
                // первый paint показывает "loading", FutureBuilder заменит на
                // значение когда native ответит. Tap — открывает upstream
                // GitHub репо.
                FutureBuilder<String>(
                  future: BoxVpnClient.I.getCoreVersion(),
                  builder: (ctx, snap) {
                    final v = (snap.data ?? '').trim();
                    final subtitle = switch (snap.connectionState) {
                      ConnectionState.waiting => 'Loading…',
                      _ when v.isEmpty => 'sing-box (version unknown)',
                      _ => 'sing-box $v · via libbox',
                    };
                    return ListTile(
                      leading: const Icon(Icons.architecture),
                      title: Text(getLocalText.s("VPN core")),
                      subtitle: Text(subtitle),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => ul.UrlLauncher.open(_singboxUpstreamUrl),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            getLocalText.s("Credits"),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  // l10n-exempt: project name
                  title: const Text('singbox-launcher'),
                  subtitle: Text(getLocalText.s("Config wizard and parser reference")),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => ul.UrlLauncher.open(_singboxLauncherUrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _showDonateDialog(context),
            icon: const Icon(Icons.favorite),
            label: Text(getLocalText.s("Support the project")),
          ),
          const SizedBox(height: 16),
          Text(
            getLocalText.s("Tech Stack"),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: const [
              // l10n-exempt: technology name
              Chip(label: Text('Flutter')),
              // l10n-exempt: technology name
              Chip(label: Text('Dart')),
              // l10n-exempt: technology name
              Chip(label: Text('sing-box')),
              // l10n-exempt: technology name
              Chip(label: Text('libbox')),
              // l10n-exempt: technology name
              Chip(label: Text('CommandClient')),
              // l10n-exempt: technology name
              Chip(label: Text('Material 3')),
            ],
          ),
        ],
      ),
    );
  }

  void _showDonateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: AlertDialog(
          title: Text(getLocalText.s("Support L×Box")),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: getLocalText.s("Crypto")),
                    // l10n-exempt: brand name
                    const Tab(text: 'Boosty'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      // Crypto tab
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: ListView(
                          children: [
                            // l10n-exempt: currency/network name
                            const Text('USDT (ERC20)', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () => _copyToClipboard(ctx, '0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea'),
                              // l10n-exempt: wallet address
                              child: const Text('0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea', style: TextStyle(fontSize: 11)),
                            ),
                            TextButton.icon(
                              onPressed: () => _copyToClipboard(ctx, '0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea'),
                              icon: const Icon(Icons.copy, size: 14),
                              label: Text(getLocalText.s("Copy ERC20"), style: const TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(height: 12),
                            // l10n-exempt: currency/network name
                            const Text('USDT (TRC20)', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () => _copyToClipboard(ctx, 'TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun'),
                              // l10n-exempt: wallet address
                              child: const Text('TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun', style: TextStyle(fontSize: 11)),
                            ),
                            TextButton.icon(
                              onPressed: () => _copyToClipboard(ctx, 'TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun'),
                              icon: const Icon(Icons.copy, size: 14),
                              label: Text(getLocalText.s("Copy TRC20"), style: const TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      // Boosty tab
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Center(child: Text(getLocalText.s("Coming soon"))),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(getLocalText.s("Close"))),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Copied: %s", text))),
    );
  }
}

/// "Latest available" block — pings GitHub Releases (24h cap), shows result
/// inline + manual "Check now" button. Spec §036.
class _UpdateBlock extends StatefulWidget {
  const _UpdateBlock();

  @override
  State<_UpdateBlock> createState() => _UpdateBlockState();
}

class _UpdateBlockState extends State<_UpdateBlock> {
  bool _checking = false;
  String? _statusLine;

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _statusLine = null;
    });
    final result = await UpdateChecker.I.forceCheck(
      localVersion: VersionInfo.I.version,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      switch (result.kind) {
        case UpdateCheckKind.newer:
          _statusLine = null; // banner-block ниже сам отрисует info
        case UpdateCheckKind.upToDate:
          _statusLine = "You're up to date";
        case UpdateCheckKind.failed:
          _statusLine = 'Check failed: ${result.message ?? 'unknown error'}';
        case UpdateCheckKind.skipped:
          _statusLine = 'Check skipped: ${result.message ?? ''}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ValueListenableBuilder<UpdateInfo?>(
        valueListenable: UpdateChecker.I.latest,
        builder: (context, info, _) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      info != null ? Icons.system_update_alt : Icons.check_circle_outline,
                      size: 18,
                      color: info != null ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        info != null
                            ? getLocalText.s("%s available", info.tag)
                            : getLocalText.s("No updates pending"),
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (_checking)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      TextButton(
                        onPressed: _checkNow,
                        child: Text(getLocalText.s("Check now")),
                      ),
                  ],
                ),
                if (info != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text(
                      info.publishedAt != null
                          ? getLocalText.s("Released %s",
                              relativeTime(DateTime.now(), info.publishedAt!))
                          : getLocalText.s("(cached info)"),
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => ul.UrlLauncher.open(info.htmlUrl),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(getLocalText.s("View release")),
                    ),
                  ),
                ],
                if (_statusLine != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text(
                      _statusLine!,
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
