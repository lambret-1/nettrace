import 'dart:convert';
import 'dart:io';

import '../models/http_request.dart';
import '../models/http_response.dart';
import 'socket_buffer.dart';

/// HTTP 请求/响应拦截解析器
/// 负责从原始字节流中解析 HTTP 报文
class HttpInterceptor {
  /// 从 SocketBuffer 读取并解析一个完整的 HTTP 请求
  static Future<HttpRequestData> parseRequest(SocketBuffer buffer) async {
    final headerEnd = await buffer.readUntilHeaderEnd();

    // 解析请求行和头部
    final headerText = utf8.decode(headerEnd, allowMalformed: true);
    final lines = const LineSplitter().convert(headerText);
    if (lines.isEmpty) {
      throw const HttpException('Empty request');
    }

    // 请求行: METHOD URL HTTP/1.1
    final requestLine = lines[0].trim();
    final parts = requestLine.split(' ');
    if (parts.length < 2) {
      throw HttpException('Invalid request line: $requestLine');
    }

    final method = parts[0].toUpperCase();
    final target = parts[1];

    // 解析头部
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

    // 解析 URL 组件
    final uri = _parseRequestTarget(target, headers);
    final contentType = headers['content-type'];
    final contentLength = int.tryParse(headers['content-length'] ?? '') ?? 0;

    // 读取 Body
    List<int>? body;
    if (contentLength > 0) {
      body = await buffer.readExact(contentLength);
    } else if (headers['transfer-encoding']?.contains('chunked') == true) {
      body = await _readChunked(buffer);
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
      contentType: contentType,
      contentLength: body?.length ?? contentLength,
    );
  }

  /// 从 SocketBuffer 读取并解析一个完整的 HTTP 响应
  static Future<HttpResponseData> parseResponse(
    SocketBuffer buffer, {
    Duration? elapsed,
  }) async {
    final headerEnd = await buffer.readUntilHeaderEnd();

    final headerText = utf8.decode(headerEnd, allowMalformed: true);
    final lines = const LineSplitter().convert(headerText);
    if (lines.isEmpty) {
      throw const HttpException('Empty response');
    }

    // 状态行: HTTP/1.1 200 OK
    final statusLine = lines[0].trim();
    final statusParts = statusLine.split(' ');
    final statusCode = statusParts.length > 1
        ? int.tryParse(statusParts[1]) ?? 0
        : 0;
    final reasonPhrase = statusParts.length > 2
        ? statusParts.sublist(2).join(' ')
        : null;

    // 解析头部
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

    final contentType = headers['content-type'];
    final contentLength = int.tryParse(headers['content-length'] ?? '') ?? 0;

    // 读取 Body
    List<int>? body;
    if (contentLength > 0) {
      body = await buffer.readExact(contentLength);
    } else if (headers['transfer-encoding']?.contains('chunked') == true) {
      body = await _readChunked(buffer);
    }

    return HttpResponseData(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      headers: headers,
      body: body,
      contentType: contentType,
      contentLength: body?.length ?? contentLength,
      duration: elapsed,
    );
  }

  /// 将 HttpRequestData 序列化为原始 HTTP 请求字节
  static List<int> serializeRequest(HttpRequestData request) {
    final buffer = StringBuffer();
    final path = request.path ?? '/';
    final query = request.queryParams?.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
            .join('&') ??
        '';
    final target = query.isNotEmpty ? '$path?$query' : path;

    buffer.writeln('${request.method} $target HTTP/1.1');
    request.headers.forEach((key, value) {
      buffer.writeln('$key: $value');
    });
    buffer.writeln();

    final bytes = <int>[];
    bytes.addAll(utf8.encode(buffer.toString()));
    if (request.body != null) {
      bytes.addAll(request.body!);
    }
    return bytes;
  }

  // ---- 内部工具 ----

  /// 读取 chunked 编码的 body
  static Future<List<int>> _readChunked(SocketBuffer buffer) async {
    final result = <int>[];

    while (true) {
      final sizeLine = await buffer.readLine();
      final size = int.tryParse(sizeLine.split(';')[0].trim(), radix: 16) ?? 0;
      if (size == 0) break;
      final chunk = await buffer.readExact(size);
      result.addAll(chunk);
      await buffer.readLine(); // 跳过 chunk 后的 \r\n
    }
    return result;
  }

  /// 解析请求目标为 Uri
  static Uri _parseRequestTarget(String target, Map<String, String> headers) {
    // 绝对 URI（代理请求）
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return Uri.parse(target);
    }

    // 相对路径，从 Host 头补全
    final host = headers['host'] ?? 'localhost';
    return Uri.parse('http://$host$target');
  }
}
