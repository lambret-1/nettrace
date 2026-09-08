import 'package:flutter/material.dart';

import 'app.dart';
import 'storage/capture_store.dart';

/// NetTrace 入口
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地存储
  await CaptureStore().init();

  runApp(const NetTraceApp());
}
