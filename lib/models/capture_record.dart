import 'http_request.dart';
import 'http_response.dart';

/// 抓包记录完整模型
class CaptureRecord {
  final String id;
  final DateTime timestamp;
  final HttpRequestData request;
  final HttpResponseData? response;
  final bool isHttps;
  final String? error;
  bool isFavorite;

  CaptureRecord({
    required this.id,
    required this.timestamp,
    required this.request,
    this.response,
    this.isHttps = false,
    this.error,
    this.isFavorite = false,
  });

  // 便捷属性
  String get method => request.method;
  String get url => request.url;
  String get host => request.host ?? '';
  String get path => request.path ?? '';
  int? get statusCode => response?.statusCode;
  Duration? get duration => response?.duration;
  int get requestSize => request.contentLength;
  int get responseSize => response?.contentLength ?? 0;
  String? get contentType => response?.contentType ?? request.contentType;

  bool get hasError => error != null;
  bool get isCompleted => response != null || error != null;

  String get statusText {
    if (error != null) return '错误';
    if (response == null) return '进行中';
    return '${response!.statusCode} ${response!.reasonPhrase ?? ''}';
  }

  factory CaptureRecord.fromMap(Map<String, dynamic> map) {
    return CaptureRecord(
      id: map['id'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestamp'] as int? ?? 0,
      ),
      request: HttpRequestData.fromMap(
        Map<String, dynamic>.from(map['request'] as Map? ?? {}),
      ),
      response: map['response'] != null
          ? HttpResponseData.fromMap(
              Map<String, dynamic>.from(map['response'] as Map),
            )
          : null,
      isHttps: map['isHttps'] as bool? ?? false,
      error: map['error'] as String?,
      isFavorite: map['isFavorite'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'request': request.toMap(),
      'response': response?.toMap(),
      'isHttps': isHttps,
      'error': error,
      'isFavorite': isFavorite,
    };
  }

  CaptureRecord copyWith({
    HttpResponseData? response,
    String? error,
    bool? isFavorite,
  }) {
    return CaptureRecord(
      id: id,
      timestamp: timestamp,
      request: request,
      response: response ?? this.response,
      isHttps: isHttps,
      error: error ?? this.error,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}
