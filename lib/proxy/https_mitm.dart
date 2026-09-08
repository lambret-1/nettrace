import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/capture_record.dart';
import '../models/http_request.dart';
import '../models/http_response.dart';
import 'certificate_manager.dart';
import 'http_interceptor.dart';

/// HTTPS MITM (Man-In-The-Middle) 解密处理器
///
/// 工作原理：
/// 1. 收到客户端 CONNECT host:443 请求
/// 2. 回复 200 Connection Established
/// 3. 在本地启动 SecureServerSocket（用动态签发的域名证书）
/// 4. 将原始客户端 Socket 桥接到本地 SecureServerSocket
/// 5. 接受 TLS 连接后获得明文 HTTP 数据
/// 6. 用 SecureSocket 连接真实服务器，转发请求并捕获响应
/// 7. 将响应写回客户端，同时记录抓包数据
class HttpsMitm {
  final CertificateManager _certManager = CertificateManager();
  final void Function(CaptureRecord) onRecord;
  final Set<String> _blacklist;
  final Set<String> _whitelist;
  final bool _useWhitelist;

  HttpsMitm({
    required this.onRecord,
    Set<String>? blacklist,
    Set<String>? whitelist,
    bool useWhitelist = false,
  })  : _blacklist = blacklist ?? {},
        _whitelist = whitelist ?? {},
        _useWhitelist = useWhitelist;

  /// 处理一个 CONNECT 请求
  ///
  /// [clientSocket] 已连接的客户端 Socket（CONNECT 请求头已读取完毕）
  /// [host] 目标主机
  /// [port] 目标端口
  Future<void> handleConnect(
    Socket clientSocket,
    String host,
    int port,
  ) async {
    // 检查过滤：黑名单或非白名单域名走纯隧道不解密
    if (_shouldSkip(host)) {
      await _plainTunnel(clientSocket, host, port);
      return;
    }

    try {
      // 1. 回复客户端 200 Connection Established
      clientSocket.add(
        'HTTP/1.1 200 Connection Established\r\n'
        'Proxy-Agent: NetTrace/1.0\r\n'
        '\r\n'.codeUnits,
      );
      await clientSocket.flush();

      // 2. 动态生成域名证书，创建本地 SecureServerSocket
      final context = _certManager.createSecurityContextForHost(host);
      final server = await SecureServerSocket.bind(
        '127.0.0.1',
        0, // 随机端口
        context,
      );

      // 3. 桥接：将原始 clientSocket 的数据转发到本地 SecureServerSocket
      unawaited(_bridgeSockets(clientSocket, server.port));

      // 4. 接受 TLS 连接（此时数据已解密为明文 HTTP）
      final secureSocket = await server.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          server.close();
          throw TimeoutException('TLS 握手超时');
        },
      );

      // 5. 处理解密后的 HTTP 请求
      await _processHttpsRequest(secureSocket, host, port);

      await server.close();
    } catch (e) {
      // MITM 失败，降级为纯隧道（不解密）
      try {
        await _plainTunnel(clientSocket, host, port);
      } catch (_) {}
    }
  }

  /// 将客户端 Socket 桥接到本地 SecureServerSocket
  Future<void> _bridgeSockets(Socket client, int localPort) async {
    try {
      final bridge = await Socket.connect('127.0.0.1', localPort);
      final sub1 = client.listen(
        (data) => bridge.add(data),
        onDone: () => bridge.close(),
        onError: (_) => bridge.close(),
      );
      final sub2 = bridge.listen(
        (data) => client.add(data),
        onDone: () => client.close(),
        onError: (_) => client.close(),
      );
      await Future.any([sub1.asFuture(), sub2.asFuture()]);
    } catch (_) {}
  }

  /// 处理解密后的 HTTPS 请求
  Future<void> _processHttpsRequest(
    Socket clientSecure,
    String host,
    int port,
  ) async {
    final startTime = DateTime.now();

    try {
      // 解析客户端请求
      final request = await HttpInterceptor.parseRequest(clientSecure);
      final fullUrl = 'https://$host${request.path ?? '/'}';

      final updatedRequest = HttpRequestData(
        method: request.method,
        url: fullUrl,
        scheme: 'https',
        host: host,
        port: port,
        path: request.path,
        headers: request.headers,
        body: request.body,
        queryParams: request.queryParams,
        contentType: request.contentType,
        contentLength: request.contentLength,
      );

      // 连接真实服务器
      final serverSecure = await SecureSocket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: AppConstants.connectTimeout),
        onBadCertificate: (_) => true, // 代理接受所有证书
      );

      // 转发请求到真实服务器
      serverSecure.add(HttpInterceptor.serializeRequest(updatedRequest));
      await serverSecure.flush();

      // 读取真实服务器响应
      final elapsed = DateTime.now().difference(startTime);
      final response = await HttpInterceptor.parseResponse(
        serverSecure,
        elapsed: elapsed,
      );

      // 将响应写回客户端
      clientSecure.add(_serializeResponse(response));
      await clientSecure.flush();

      // 记录抓包数据
      onRecord(CaptureRecord(
        id: _generateId(),
        timestamp: startTime,
        request: updatedRequest,
        response: response,
        isHttps: true,
      ));

      // 处理 keep-alive 连接上的后续请求
      await _handleKeepAlive(clientSecure, serverSecure, host, port);
    } catch (e) {
      onRecord(CaptureRecord(
        id: _generateId(),
        timestamp: startTime,
        request: HttpRequestData(
          method: 'UNKNOWN',
          url: 'https://$host/',
          host: host,
        ),
        isHttps: true,
        error: e.toString(),
      ));
    }
  }

  /// 处理 keep-alive 连接上的后续请求
  Future<void> _handleKeepAlive(
    Socket client,
    Socket server,
    String host,
    int port,
  ) async {
    try {
      while (true) {
        final request = await HttpInterceptor.parseRequest(client);
        final startTime = DateTime.now();
        final fullUrl = 'https://$host${request.path ?? '/'}';

        final updatedRequest = HttpRequestData(
          method: request.method,
          url: fullUrl,
          scheme: 'https',
          host: host,
          port: port,
          path: request.path,
          headers: request.headers,
          body: request.body,
          queryParams: request.queryParams,
          contentType: request.contentType,
          contentLength: request.contentLength,
        );

        server.add(HttpInterceptor.serializeRequest(updatedRequest));
        await server.flush();

        final elapsed = DateTime.now().difference(startTime);
        final response = await HttpInterceptor.parseResponse(
          server,
          elapsed: elapsed,
        );

        client.add(_serializeResponse(response));
        await client.flush();

        onRecord(CaptureRecord(
          id: _generateId(),
          timestamp: startTime,
          request: updatedRequest,
          response: response,
          isHttps: true,
        ));
      }
    } catch (_) {
      // 连接关闭，正常退出
    }
  }

  /// 纯隧道转发（不解密，用于黑名单/非白名单域名）
  Future<void> _plainTunnel(Socket client, String host, int port) async {
    client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
    await client.flush();

    final server = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: AppConstants.connectTimeout),
    );

    final sub1 = client.listen(
      (data) => server.add(data),
      onDone: () => server.close(),
      onError: (_) => server.close(),
    );
    final sub2 = server.listen(
      (data) => client.add(data),
      onDone: () => client.close(),
      onError: (_) => client.close(),
    );

    await Future.any([sub1.asFuture(), sub2.asFuture()]);
  }

  /// 序列化 HTTP 响应为原始字节
  List<int> _serializeResponse(HttpResponseData response) {
    final buffer = StringBuffer();
    buffer.writeln(
      'HTTP/1.1 ${response.statusCode} ${response.reasonPhrase ?? ''}',
    );
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

  /// 判断是否应该跳过解密（走纯隧道）
  bool _shouldSkip(String host) {
    if (_useWhitelist) {
      return !_whitelist.any((d) => host == d || host.endsWith('.$d'));
    }
    return _blacklist.any((d) => host == d || host.endsWith('.$d'));
  }

  String _generateId() {
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  }
}
