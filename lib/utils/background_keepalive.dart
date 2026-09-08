import 'package:audioplayers/audioplayers.dart';

/// 后台保活工具
///
/// iOS 后台限制：APP 进入后台后会被挂起，网络监听停止。
/// 通过播放无声音频（audio 后台模式）保持 APP 在后台持续运行。
/// 这是 iOS 抓包工具（Thor、Stream 等）通用的后台保活方案。
class BackgroundKeepAlive {
  static final BackgroundKeepAlive _instance = BackgroundKeepAlive._internal();
  factory BackgroundKeepAlive() => _instance;
  BackgroundKeepAlive._internal();

  final AudioPlayer _player = AudioPlayer();
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// 开始后台保活（循环播放无声音频）
  Future<void> start() async {
    if (_isRunning) return;
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(0.0); // 静音
      await _player.play(AssetSource('audio/silent.wav'));
      _isRunning = true;
    } catch (e) {
      // 音频播放失败不影响代理功能
      _isRunning = false;
    }
  }

  /// 停止后台保活
  Future<void> stop() async {
    if (!_isRunning) return;
    try {
      await _player.stop();
    } catch (_) {}
    _isRunning = false;
  }
}
