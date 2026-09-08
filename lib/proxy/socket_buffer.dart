import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 带缓冲区的 Socket 读取器
///
/// 解决反复 socket.listen/cancel 导致数据丢失的问题。
/// 订阅一次 socket 流，数据全部进入内部缓冲区，
/// 读取方法从缓冲区中按需提取，不会丢失任何数据。
class SocketBuffer {
  final Socket socket;
  final List<int> _buffer = [];
  final List<Completer<void>> _waiters = [];
  late final StreamSubscription<List<int>> _sub;
  bool _isClosed = false;

  SocketBuffer(this.socket) {
    _sub = socket.listen(
      (data) {
        _buffer.addAll(data);
        _wakeWaiters();
      },
      onDone: () {
        _isClosed = true;
        _wakeWaiters();
      },
      onError: (e) {
        _isClosed = true;
        for (final w in _waiters) {
          if (!w.isCompleted) w.completeError(e);
        }
        _waiters.clear();
      },
      cancelOnError: false,
    );
  }

  void _wakeWaiters() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<void> _waitForData() async {
    if (_buffer.isNotEmpty || _isClosed) return;
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  /// 读取一行（直到 \n），返回去除 \r\n 的字符串
  /// 如果连接关闭且缓冲区为空，返回空字符串
  Future<String> readLine() async {
    while (true) {
      for (var i = 0; i < _buffer.length; i++) {
        if (_buffer[i] == 10) {
          // \n
          final lineBytes = _buffer.sublist(0, i);
          _buffer.removeRange(0, i + 1);
          // 去除末尾的 \r
          if (lineBytes.isNotEmpty && lineBytes.last == 13) {
            lineBytes.removeLast();
          }
          return utf8.decode(lineBytes, allowMalformed: true);
        }
      }
      if (_isClosed) {
        // 连接关闭，返回剩余内容
        if (_buffer.isEmpty) return '';
        final line = utf8.decode(_buffer, allowMalformed: true);
        _buffer.clear();
        return line;
      }
      await _waitForData();
    }
  }

  /// 读取直到遇到空行（HTTP 头部结束），返回包含头部的全部字节
  Future<List<int>> readUntilHeaderEnd() async {
    final result = <int>[];
    var consecutiveNewlines = 0;

    while (true) {
      while (_buffer.isNotEmpty) {
        final byte = _buffer.removeAt(0);
        result.add(byte);
        if (byte == 10) {
          consecutiveNewlines++;
          if (consecutiveNewlines >= 2) {
            return result;
          }
        } else if (byte != 13) {
          consecutiveNewlines = 0;
        }
      }
      if (_isClosed) return result;
      await _waitForData();
    }
  }

  /// 读取指定长度的字节
  Future<List<int>> readExact(int length) async {
    final result = <int>[];
    while (result.length < length) {
      if (_buffer.isNotEmpty) {
        final take = (length - result.length).clamp(0, _buffer.length);
        result.addAll(_buffer.sublist(0, take));
        _buffer.removeRange(0, take);
      } else {
        if (_isClosed) break;
        await _waitForData();
      }
    }
    return result;
  }

  /// 查看缓冲区中是否有数据
  bool get hasData => _buffer.isNotEmpty;

  /// 是否已经关闭
  bool get isClosed => _isClosed;

  /// 销毁，取消订阅
  void dispose() {
    _sub.cancel();
  }
}
