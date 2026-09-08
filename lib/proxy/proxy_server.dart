import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/capture_record.dart';
import '../models/http_request.dart';
import '../models/http_response.dart';
import '../utils/background_keepalive.dart';
import 'certificate_manager.dart';
import 'http_interceptor.dart';
import 'https_mitm.dart';
import 'socket_buffer.dart';

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

      // 启动后台保活（播放无声音频，防止APP进入后台被挂起）
      await BackgroundKeepAlive().start();

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
    await BackgroundKeepAlive().stop();
    await _server?.close();
    _server = null;
    _isRunning = false;
    onStateChanged?.call(false);
    _log('代理服务已停止');
  }

  /// 处理新的客户端连接
  Future<void> _handleConnection(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);

    final clientAddr = '${client.remoteAddress.address}:${client.remotePort}';
    _log('[连接] 新客户端连接: $clientAddr');

    try {
      // 使用 SocketBuffer 读取，避免反复订阅/取消导致数据丢失
      final socketBuffer = SocketBuffer(client);

      // 读取请求首行，判断是 HTTP 还是 CONNECT
      final line = await socketBuffer.readLine();
      _log('[连接] 收到首行: $line (来自 $clientAddr)');

      if (line.isEmpty) {
        _log('[连接] 首行为空，关闭连接: $clientAddr');
        client.close();
        socketBuffer.dispose();
        return;
      }

      final parts = line.split(' ');
      if (parts.isEmpty) {
        client.close();
        socketBuffer.dispose();
        return;
      }

      final method = parts[0].toUpperCase();

      if (method == 'CONNECT') {
        // HTTPS CONNECT 请求
        await _handleConnectRequest(client, parts, socketBuffer);
      } else {
        // 普通 HTTP 请求
        await _handleHttpRequest(client, socketBuffer);
      }

      socketBuffer.dispose();
      _log('[连接] 连接处理完成: $clientAddr');
    } catch (e, stackTrace) {
      _log('[连接] 处理异常: $e (来自 $clientAddr)');
      _log('[连接] 堆栈: $stackTrace');
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// 处理 CONNECT 请求（HTTPS）
  Future<void> _handleConnectRequest(
    Socket client,
    List<String> parts,
    SocketBuffer socketBuffer,
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
    while (true) {
      final headerLine = await socketBuffer.readLine();
      if (headerLine.isEmpty) break;
    }

    // 交给 MITM 处理
    await _mitm?.handleConnect(client, host, port);
  }

  /// 处理普通 HTTP 请求
  Future<void> _handleHttpRequest(Socket client, SocketBuffer socketBuffer) async {
    final startTime = DateTime.now();
    final clientAddr = '${client.remoteAddress.address}:${client.remotePort}';

    try {
      // 从 socketBuffer 解析完整请求
      _log('[HTTP] 开始解析请求 (来自 $clientAddr)');
      final request = await _parseRequest(socketBuffer);
      _log('[HTTP] 解析完成: ${request.method} ${request.url}');

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
      _log('[HTTP] 连接目标服务器: $host:$port');

      final server = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: AppConstants.connectTimeout),
      );
      _log('[HTTP] 已连接目标服务器: $host:$port');
      final serverBuffer = SocketBuffer(server);

      // 转发请求（需要修改为相对路径，因为目标服务器不是代理）
      final forwardRequest = _buildForwardRequest(request);
      server.add(forwardRequest);
      await server.flush();
      _log('[HTTP] 已转发请求到 $host:$port');

      // 读取响应
      final elapsed = DateTime.now().difference(startTime);
      _log('[HTTP] 等待响应...');
      final response = await HttpInterceptor.parseResponse(serverBuffer, elapsed: elapsed);
      _log('[HTTP] 收到响应: ${response.statusCode} (耗时 ${elapsed.inMilliseconds}ms)');

      // 将响应写回客户端
      client.add(_serializeResponseRaw(response));
      await client.flush();
      _log('[HTTP] 已写回响应到客户端');

      // 通知记录
      final completedRecord = record.copyWith(response: response);
      _handleRecord(completedRecord);

      // keep-alive 后续请求
      await _handleHttpKeepAlive(client, server, socketBuffer, serverBuffer, startTime);

      await server.close();
    } catch (e, stackTrace) {
      _log('[HTTP] 处理异常: $e (来自 $clientAddr)');
      _log('[HTTP] 堆栈: $stackTrace');
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
    SocketBuffer socketBuffer,
    SocketBuffer serverBuffer,
    DateTime baseTime,
  ) async {
    try {
      while (true) {
        final line = await socketBuffer.readLine();
        if (line.isEmpty) break;

        final request = await _parseRequest(socketBuffer, firstLine: line);
        final startTime = DateTime.now();

        server.add(_buildForwardRequest(request));
        await server.flush();

        final elapsed = DateTime.now().difference(startTime);
        final response = await HttpInterceptor.parseResponse(serverBuffer, elapsed: elapsed);

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

  /// 从 SocketBuffer 解析完整 HTTP 请求
  Future<HttpRequestData> _parseRequest(
    SocketBuffer socketBuffer, {
    String? firstLine,
  }) async {
    // 读取请求首行
    final requestLine = firstLine ?? await socketBuffer.readLine();
    if (requestLine.isEmpty) {
      throw Exception('Empty request line');
    }

    final parts = requestLine.split(' ');
    if (parts.length < 2) {
      throw Exception('Invalid request line: $requestLine');
    }

    final method = parts[0].toUpperCase();
    final target = parts[1];

    // 读取头部直到空行
    final headers = <String, String>{};
    while (true) {
      final line = await socketBuffer.readLine();
      if (line.isEmpty) break;
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim().toLowerCase();
        final value = line.substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }

    final uri = Uri.parse(
      target.startsWith('http')
          ? target
          : 'http://${headers['host'] ?? 'localhost'}$target',
    );
    final contentLength = int.tryParse(headers['content-length'] ?? '') ?? 0;

    List<int>? body;
    if (contentLength > 0) {
      body = await socketBuffer.readExact(contentLength);
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

    final body = response.body;
    response.headers.forEach((key, value) {
      // 移除 transfer-encoding，因为 body 已经被解码
      if (key.toLowerCase() == 'transfer-encoding') return;
      // content-length 重新计算
      if (key.toLowerCase() == 'content-length') return;
      buffer.writeln('$key: $value');
    });

    if (body != null) {
      buffer.writeln('content-length: ${body.length}');
    }
    buffer.writeln('connection: close');
    buffer.writeln();

    final bytes = <int>[];
    bytes.addAll(utf8.encode(buffer.toString()));
    if (body != null) {
      bytes.addAll(body);
    }
    return bytes;
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
