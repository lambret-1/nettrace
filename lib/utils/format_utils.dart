/// 格式化工具
class FormatUtils {
  /// 格式化时间戳为 HH:mm:ss.SSS
  static String formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// 格式化日期时间
  static String formatDateTime(DateTime time) {
    final y = time.year;
    final mo = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return '$y-$mo-$d ${formatTime(time)}';
  }

  /// 格式化字节大小
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// 格式化耗时
  static String formatDuration(Duration? duration) {
    if (duration == null) return '-';
    if (duration.inMilliseconds < 1000) {
      return '${duration.inMilliseconds} ms';
    }
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(2)} s';
  }

  /// 截断 URL 显示
  static String truncateUrl(String url, {int maxLength = 80}) {
    if (url.length <= maxLength) return url;
    return '${url.substring(0, maxLength - 3)}...';
  }

  /// 获取域名
  static String getHostFromUrl(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  /// 获取路径
  static String getPathFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.path.isEmpty ? '/' : uri.path;
    } catch (_) {
      return '/';
    }
  }

  /// 状态码描述
  static String statusDescription(int statusCode) {
    const map = {
      100: 'Continue',
      101: 'Switching Protocols',
      200: 'OK',
      201: 'Created',
      202: 'Accepted',
      204: 'No Content',
      206: 'Partial Content',
      301: 'Moved Permanently',
      302: 'Found',
      303: 'See Other',
      304: 'Not Modified',
      307: 'Temporary Redirect',
      308: 'Permanent Redirect',
      400: 'Bad Request',
      401: 'Unauthorized',
      403: 'Forbidden',
      404: 'Not Found',
      405: 'Method Not Allowed',
      408: 'Request Timeout',
      409: 'Conflict',
      410: 'Gone',
      413: 'Payload Too Large',
      415: 'Unsupported Media Type',
      429: 'Too Many Requests',
      500: 'Internal Server Error',
      501: 'Not Implemented',
      502: 'Bad Gateway',
      503: 'Service Unavailable',
      504: 'Gateway Timeout',
    };
    return map[statusCode] ?? '';
  }
}
