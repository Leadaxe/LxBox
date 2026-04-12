import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BoxVpnApp());
}

class BoxVpnApp extends StatelessWidget {
  const BoxVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BoxVPN',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
