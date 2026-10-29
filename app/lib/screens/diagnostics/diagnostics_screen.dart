import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../services/l10n/locale_controller.dart';
import '../speed_test_screen.dart';
import 'url_check_tab.dart';

/// §687 — вкладки раздела Diagnostics в порядке показа.
enum DiagnosticsTab { urlCheck, speedTest }

/// §687 — раздел Diagnostics: URL Check | Speed Test. Обе вкладки держат
/// состояние при переключении (идущий тест не обрывается).
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({
    super.key,
    required this.homeController,
    this.initialTab = DiagnosticsTab.urlCheck,
  });

  final HomeController homeController;
  final DiagnosticsTab initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: DiagnosticsTab.values.length,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("Diagnostics")),
          bottom: TabBar(
            tabs: [
              Tab(
                icon: const Icon(Icons.travel_explore),
                text: getLocalText.s("URL Check"),
              ),
              Tab(
                icon: const Icon(Icons.speed_outlined),
                text: getLocalText.s("Speed Test"),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            UrlCheckTab(homeController: homeController),
            SpeedTestScreen(homeController: homeController, embedded: true),
          ],
        ),
      ),
    );
  }
}
