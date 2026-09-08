import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/capture_record.dart';
import '../models/http_request.dart';
import '../models/http_response.dart';
import 'certificate_manager.dart';
import 'http_interceptor.dart';
import 'https_mitm.dart';

/// 本地代理服务器 - 核心入口
/// 监听 127.0.0.1:8888，处理 HTTP 明文和 HTTPS CONNECT 请求
class ProxyServer {
  static final ProxyServer _instance = ProxyServer._internal();
  factory ProxyServer() => _instance;
  ProxyServer._internal();

  ServerSocket? _server;
  HttpsMitm? _mitm;
  bool _isRunning = false;
  int _requestCount = 0;

  // 事件回调
  void Function(CaptureRecord)? onRequestCaptured;
  void Function(String)? onLog;
  void Function(bool)? onStateChanged;

  // 过滤配置
  Set<String> blacklist = {};
  Set<String> whitelist = {};
  bool useWhitelist = false;

  bool get isRunning => _isRunning;
  int get requestCount => _requestCount;

  /// 获取本机 WiFi 局域网 IP 地址
  ///
  /// 用于展示给用户，在 WiFi 设置中配置 HTTP 代理。
  /// 优先返回 192.168.x.x / 10.x.x.x / 172.16-31.x.x 网段地址。
  Future<String> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          // 过滤常见局域网网段
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            return ip;
          }
        }
      }
      // 如果没有匹配到局域网网段，返回第一个非回环地址
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
      return '未获取到IP';
    } catch (e) {
      return '获取IP失败';
    }
  }

  bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  /// 启动代理服务
  Future<bool> start() async {
    if (_isRunning) return true;

    try {
      // 初始化证书管理器
      await CertificateManager().init();

      // 初始化 MITM
      _mitm = HttpsMitm(
        onRecord: _handleRecord,
        blacklist: blacklist,
        whitelist: whitelist,
        useWhitelist: useWhitelist,
      );

      // 启动监听
      _server = await ServerSocket.bind(
        AppConstants.proxyHost,
        AppConstants.proxyPort,
        shared: false,
      );

      _isRunning = true;
      _requestCount = 0;
      onStateChanged?.call(true);
      _log('代理服务已启动: ${AppConstants.proxyHost}:${AppConstants.proxyPort}');

      _server!.listen(
        _handleConnection,
        onError: (e) => _log('监听错误: $e'),
        onDone: () {
          _isRunning = false;
          onStateChanged?.call(false);
        },
      );

      return true;
    } catch (e) {
      _log('启动代理失败: $e');
      _isRunning = false;
      return false;
    }
  }

  /// 停止代理服务
  Future<void> stop() async {
    if (!_isRunning) return;
    await _server?.close();
    _server = null;
    _isRunning = false;
    onStateChanged?.call(false);
    _log('代理服务已停止');
  }

  /// 处理新的客户端连接
  Future<void> _handleConnection(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);

    try {
      // 读取请求首行，判断是 HTTP 还是 CONNECT
      final buffer = <int>[];
      final line = await _readLine(client, buffer);

      if (line.isEmpty) {
        client.close();
        return;
      }

      final parts = line.split(' ');
      if (parts.isEmpty) {
        client.close();
        return;
      }

      final method = parts[0].toUpperCase();

      if (method == 'CONNECT') {
        // HTTPS CONNECT 请求
        await _handleConnectRequest(client, parts, buffer);
      } else {
        // 普通 HTTP 请求
        await _handleHttpRequest(client, buffer);
      }
    } catch (e) {
      _log('连接处理错误: $e');
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// 处理 CONNECT 请求（HTTPS）
  Future<void> _handleConnectRequest(
    Socket client,
    List<String> parts,
    List<int> buffer,
  ) async {
    if (parts.length < 2) {
      client.close();
      return;
    }

    final target = parts[1]; // host:port
    final targetParts = target.split(':');
    final host = targetParts[0];
    final port = targetParts.length > 1
        ? int.tryParse(targetParts[1]) ?? 443
        : 443;

    _log('HTTPS CONNECT: $host:$port');

    // 读取并丢弃剩余的请求头（CONNECT 请求只有头没有 body）
    await _drainHeaders(client, buffer);

    // 交给 MITM 处理
    await _mitm?.handleConnect(client, host, port);
  }

  /// 处理普通 HTTP 请求
  Future<void> _handleHttpRequest(Socket client, List<int> buffer) async {
    final startTime = DateTime.now();

    try {
      // 从已有 buffer + socket 解析完整请求
      final request = await _parseRequestFromBuffer(client, buffer);

      _log('HTTP ${request.method} ${request.url}');
      _requestCount++;

      final recordId = _generateId();
      final record = CaptureRecord(
        id: recordId,
        timestamp: startTime,
        request: request,
        isHttps: false,
      );

      // 连接目标服务器
      final host = request.host ?? 'localhost';
      final port = request.port ?? 80;

      final server = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: AppConstants.connectTimeout),
      );

      // 转发请求（需要修改为相对路径，因为目标服务器不是代理）
      final forwardRequest = _buildForwardRequest(request);
      server.add(forwardRequest);
      await server.flush();

      // 读取响应
      final elapsed = DateTime.now().difference(startTime);
      final response = await HttpInterceptor.parseResponse(server, elapsed: elapsed);

      // 将响应写回客户端
      client.add(_serializeResponseRaw(response));
      await client.flush();

      // 通知记录
      final completedRecord = record.copyWith(response: response);
      _handleRecord(completedRecord);

      // keep-alive 后续请求
      await _handleHttpKeepAlive(client, server, startTime);

      await server.close();
    } catch (e) {
      _log('HTTP 请求处理错误: $e');
      _handleRecord(CaptureRecord(
        id: _generateId(),
        timestamp: startTime,
        request: HttpRequestData(
          method: 'ERROR',
          url: '',
        ),
        error: e.toString(),
      ));
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// HTTP keep-alive 后续请求
  Future<void> _handleHttpKeepAlive(
    Socket client,
    Socket server,
    DateTime baseTime,
  ) async {
    try {
      while (true) {
        final buffer = <int>[];
        final line = await _readLine(client, buffer);
        if (line.isEmpty) break;

        final request = await _parseRequestFromBuffer(client, buffer);
        final startTime = DateTime.now();

        server.add(_buildForwardRequest(request));
        await server.flush();

        final elapsed = DateTime.now().difference(startTime);
        final response = await HttpInterceptor.parseResponse(server, elapsed: elapsed);

        client.add(_serializeResponseRaw(response));
        await client.flush();

        _handleRecord(CaptureRecord(
          id: _generateId(),
          timestamp: startTime,
          request: request,
          response: response,
          isHttps: false,
        ));
      }
    } catch (_) {
      // 连接关闭
    }
  }

  /// 从已有 buffer + socket 解析完整请求
  Future<HttpRequestData> _parseRequestFromBuffer(
    Socket client,
    List<int> initialBuffer,
  ) async {
    // 我们需要把 initialBuffer 已经读取的数据"还给"解析器
    // 简单做法：先读取完整头部，再解析
    final fullBuffer = List<int>.from(initialBuffer);
    final headerEnd = await _readUntilHeaderEndFromSocket(client, fullBuffer);

    final headerText = utf8.decode(headerEnd, allowMalformed: true);
    final lines = const LineSplitter().convert(headerText);

    final requestLine = lines[0].trim();
    final parts = requestLine.split(' ');
    final method = parts[0].toUpperCase();
    final target = parts[1];

    final headers = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim().toLowerCase();
        final value = line.substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }

    final uri = Uri.parse(target.startsWith('http') ? target : 'http://${headers['host'] ?? 'localhost'}$target');
    final contentLength = int.tryParse(headers['content-length'] ?? '') ?? 0;

    List<int>? body;
    if (contentLength > 0) {
      body = await _readExactFromSocket(client, contentLength);
    }

    return HttpRequestData(
      method: method,
      url: uri.toString(),
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      headers: headers,
      body: body,
      queryParams: uri.queryParameters,
      contentType: headers['content-type'],
      contentLength: body?.length ?? contentLength,
    );
  }

  /// 构建转发到目标服务器的请求（去掉代理相关头）
  List<int> _buildForwardRequest(HttpRequestData request) {
    final buffer = StringBuffer();
    final path = request.path ?? '/';
    final query = request.queryParams?.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
            .join('&') ??
        '';
    final target = query.isNotEmpty ? '$path?$query' : path;

    buffer.writeln('${request.method} $target HTTP/1.1');

    request.headers.forEach((key, value) {
      // 跳过代理相关头
      if (key == 'proxy-connection' || key == 'proxy-authorization') return;
      buffer.writeln('$key: $value');
    });
    // 确保 connection: close（简化处理）
    buffer.writeln('connection: close');
    buffer.writeln();

    final bytes = <int>[];
    bytes.addAll(utf8.encode(buffer.toString()));
    if (request.body != null) {
      bytes.addAll(request.body!);
    }
    return bytes;
  }

  List<int> _serializeResponseRaw(HttpResponseData response) {
    final buffer = StringBuffer();
    buffer.writeln('HTTP/1.1 ${response.statusCode} ${response.reasonPhrase ?? ''}');
    response.headers.forEach((key, value) {
      buffer.writeln('$key: $value');
    });
    buffer.writeln();

    final bytes = <int>[];
    bytes.addAll(utf8.encode(buffer.toString()));
    if (response.body != null) {
      bytes.addAll(response.body!);
    }
    return bytes;
  }

  // ---- 底层 Socket 读取工具 ----

  Future<String> _readLine(Socket socket, List<int> buffer) async {
    var lineBuffer = <int>[];
    // 先从已有 buffer 中读取
    var i = 0;
    for (; i < buffer.length; i++) {
      final byte = buffer[i];
      if (byte == 10) {
        // \n
        i++;
        break;
      }
      if (byte != 13) lineBuffer.add(byte);
    }
    // 移除已读取的部分
    buffer.removeRange(0, i);

    if (lineBuffer.isNotEmpty || i > 0) {
      return utf8.decode(lineBuffer, allowMalformed: true).trim();
    }

    // 从 socket 读取
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) {
        for (final byte in data) {
          if (byte == 10) {
            sub.cancel();
            completer.complete(utf8.decode(lineBuffer, allowMalformed: true).trim());
            return;
          }
          if (byte != 13) lineBuffer.add(byte);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(utf8.decode(lineBuffer, allowMalformed: true).trim());
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    return completer.future;
  }

  Future<void> _drainHeaders(Socket socket, List<int> buffer) async {
    // 读取直到遇到空行（头部结束）
    var consecutiveNewlines = 0;
    final completer = Completer<void>();
    late StreamSubscription<List<int>> sub;

    // 先检查已有 buffer
    for (final byte in buffer) {
      if (byte == 10) {
        consecutiveNewlines++;
        if (consecutiveNewlines >= 2) {
          completer.complete();
          return;
        }
      } else if (byte != 13) {
        consecutiveNewlines = 0;
      }
    }

    sub = socket.listen(
      (data) {
        for (final byte in data) {
          if (byte == 10) {
            consecutiveNewlines++;
            if (consecutiveNewlines >= 2) {
              sub.cancel();
              if (!completer.isCompleted) completer.complete();
              return;
            }
          } else if (byte != 13) {
            consecutiveNewlines = 0;
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    await completer.future;
  }

  Future<List<int>> _readUntilHeaderEndFromSocket(
    Socket socket,
    List<int> buffer,
  ) async {
    const endMarker = [13, 10, 13, 10];
    var matchLen = 0;

    // 检查已有 buffer
    for (final byte in buffer) {
      if (byte == endMarker[matchLen]) {
        matchLen++;
        if (matchLen == endMarker.length) {
          return List<int>.from(buffer);
        }
      } else {
        matchLen = (byte == endMarker[0]) ? 1 : 0;
      }
    }

    final completer = Completer<List<int>>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) {
        for (final byte in data) {
          buffer.add(byte);
          if (byte == endMarker[matchLen]) {
            matchLen++;
            if (matchLen == endMarker.length) {
              sub.cancel();
              if (!completer.isCompleted) {
                completer.complete(List<int>.from(buffer));
              }
              return;
            }
          } else {
            matchLen = (byte == endMarker[0]) ? 1 : 0;
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(List<int>.from(buffer));
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    return completer.future;
  }

  Future<List<int>> _readExactFromSocket(Socket socket, int length) async {
    final result = <int>[];
    final completer = Completer<List<int>>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) {
        result.addAll(data);
        if (result.length >= length) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.complete(result.sublist(0, length));
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(result);
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    return completer.future;
  }

  void _handleRecord(CaptureRecord record) {
    onRequestCaptured?.call(record);
  }

  void _log(String message) {
    onLog?.call(message);
  }

  String _generateId() {
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  }
}
