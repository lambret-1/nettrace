import 'package:flutter/material.dart';

import 'app.dart';
import 'proxy/certificate_manager.dart';
import 'storage/capture_store.dart';

/// NetTrace 入口
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地存储
  await CaptureStore().init();

  // 初始化 CA 证书管理器（启动时即生成/加载 CA 证书）
  await CertificateManager().init();

  runApp(const NetTraceApp());
}
