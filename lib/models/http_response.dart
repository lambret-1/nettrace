/// HTTP 响应数据模型
class HttpResponseData {
  final int statusCode;
  final String? reasonPhrase;
  final Map<String, String> headers;
  final List<int>? body;
  final String? contentType;
  final int contentLength;
  final Duration? duration;

  const HttpResponseData({
    required this.statusCode,
    this.reasonPhrase,
    this.headers = const {},
    this.body,
    this.contentType,
    this.contentLength = 0,
    this.duration,
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

  bool get isImage {
    final ct = contentType ?? headers['content-type'] ?? '';
    return ct.startsWith('image/');
  }

  bool get isText {
    final ct = contentType ?? headers['content-type'] ?? '';
    return ct.contains('text/') ||
        ct.contains('javascript') ||
        ct.contains('xml') ||
        isJson;
  }

  factory HttpResponseData.fromMap(Map<String, dynamic> map) {
    return HttpResponseData(
      statusCode: map['statusCode'] as int? ?? 0,
      reasonPhrase: map['reasonPhrase'] as String?,
      headers: Map<String, String>.from(map['headers'] as Map? ?? {}),
      body: map['body'] != null
          ? List<int>.from(map['body'] as List)
          : null,
      contentType: map['contentType'] as String?,
      contentLength: map['contentLength'] as int? ?? 0,
      duration: map['duration'] != null
          ? Duration(milliseconds: map['duration'] as int)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'statusCode': statusCode,
      'reasonPhrase': reasonPhrase,
      'headers': headers,
      'body': body,
      'contentType': contentType,
      'contentLength': contentLength,
      'duration': duration?.inMilliseconds,
    };
  }
}
