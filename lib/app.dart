import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'storage/capture_store.dart';

/// NetTrace 应用根组件
class NetTraceApp extends StatefulWidget {
  const NetTraceApp({super.key});

  @override
  State<NetTraceApp> createState() => _NetTraceAppState();
}

class _NetTraceAppState extends State<NetTraceApp> {
  final CaptureStore _store = CaptureStore();
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    await _store.init();
    final dark = _store.darkMode;
    setState(() {
      _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetTrace',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: const HomeScreen(),
    );
  }
}
