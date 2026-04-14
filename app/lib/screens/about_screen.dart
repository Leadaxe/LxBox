import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _version = '1.1.0';
  static const _repoUrl = 'https://github.com/Leadaxe/BoxVPN';

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
                  'BoxVPN',
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
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.volunteer_activism),
                  title: const Text('@igareck'),
                  subtitle: const Text('Free VPN lists for Quick Start'),
                  onTap: () => _copyToClipboard(
                    context,
                    'https://github.com/igareck/vpn-configs-for-russia',
                  ),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.extension_outlined),
                  title: Text('flutter_singbox_vpn'),
                  subtitle: Text('Native Android VPN bridge'),
                ),
              ],
            ),
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

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: $text')),
    );
  }
}
