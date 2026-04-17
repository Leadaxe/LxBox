import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _version = '1.1.0';
  static const _repoUrl = 'https://github.com/Leadaxe/LxBox';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.shield, size: 56, color: cs.primary),
                const SizedBox(height: 8),
                Text(
                  'L×Box',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'v$_version',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('Source Code'),
                  subtitle: const Text(_repoUrl),
                  onTap: () => _copyToClipboard(context, _repoUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.architecture),
                  title: const Text('Powered by sing-box'),
                  subtitle: const Text('VPN core via libbox'),
                  onTap: () => _copyToClipboard(
                    context,
                    'https://github.com/SagerNet/sing-box',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Credits',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.person_outline),
                  title: Text('singbox-launcher'),
                  subtitle: Text('Config wizard and parser reference'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _showDonateDialog(context),
            icon: const Icon(Icons.favorite),
            label: const Text('Support the project'),
          ),
          const SizedBox(height: 16),
          Text(
            'Tech Stack',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: const [
              Chip(label: Text('Flutter')),
              Chip(label: Text('Dart')),
              Chip(label: Text('sing-box')),
              Chip(label: Text('libbox')),
              Chip(label: Text('Clash API')),
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
          title: const Text('Support L\u00D7Box'),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Crypto'),
                    Tab(text: 'Boosty'),
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
                            const Text('USDT (ERC20)', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () => _copyToClipboard(ctx, '0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea'),
                              child: const Text('0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea', style: TextStyle(fontSize: 11)),
                            ),
                            TextButton.icon(
                              onPressed: () => _copyToClipboard(ctx, '0xde9cff6A529f655E777d6Ce718eD26f9c99046Ea'),
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('Copy ERC20', style: TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(height: 12),
                            const Text('USDT (TRC20)', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () => _copyToClipboard(ctx, 'TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun'),
                              child: const Text('TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun', style: TextStyle(fontSize: 11)),
                            ),
                            TextButton.icon(
                              onPressed: () => _copyToClipboard(ctx, 'TBBEANETx2YTysG1bwg3HjxZjiZWhhBWun'),
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('Copy TRC20', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      // Boosty tab
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Center(child: Text('Coming soon')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: $text')),
    );
  }
}
