/// HTTP 请求数据模型
class HttpRequestData {
  final String method;
  final String url;
  final String? scheme;
  final String? host;
  final int? port;
  final String? path;
  final Map<String, String> headers;
  final List<int>? body;
  final Map<String, String>? queryParams;
  final String? contentType;
  final int contentLength;

  const HttpRequestData({
    required this.method,
    required this.url,
    this.scheme,
    this.host,
    this.port,
    this.path,
    this.headers = const {},
    this.body,
    this.queryParams,
    this.contentType,
    this.contentLength = 0,
  });

  String get bodyAsString {
    if (body == null || body!.isEmpty) return '';
    try {
      return String.fromCharCodes(body!);
    } catch (_) {
      return '[二进制数据 ${body!.length} 字节]';
    }
  }

  bool get isJson {
    final ct = contentType ?? headers['content-type'] ?? '';
    return ct.contains('application/json') || ct.contains('+json');
  }

  bool get isFormData {
    final ct = contentType ?? headers['content-type'] ?? '';
    return ct.contains('application/x-www-form-urlencoded') ||
        ct.contains('multipart/form-data');
  }

  factory HttpRequestData.fromMap(Map<String, dynamic> map) {
    return HttpRequestData(
      method: map['method'] as String? ?? 'GET',
      url: map['url'] as String? ?? '',
      scheme: map['scheme'] as String?,
      host: map['host'] as String?,
      port: map['port'] as int?,
      path: map['path'] as String?,
      headers: Map<String, String>.from(map['headers'] as Map? ?? {}),
      body: map['body'] != null
          ? List<int>.from(map['body'] as List)
          : null,
      queryParams: map['queryParams'] != null
          ? Map<String, String>.from(map['queryParams'] as Map)
          : null,
      contentType: map['contentType'] as String?,
      contentLength: map['contentLength'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'method': method,
      'url': url,
      'scheme': scheme,
      'host': host,
      'port': port,
      'path': path,
      'headers': headers,
      'body': body,
      'queryParams': queryParams,
      'contentType': contentType,
      'contentLength': contentLength,
    };
  }
}
