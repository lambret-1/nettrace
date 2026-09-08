import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/capture_record.dart';

/// HAR (HTTP Archive) 标准格式导出工具
/// 导出的 .har 文件可直接导入 Charles、Chrome DevTools、Firefox 等工具
class HarExporter {
  /// 将抓包记录列表导出为 HAR 格式 JSON 字符串
  static String exportToHar(List<CaptureRecord> records) {
    final har = {
      'log': {
        'version': '1.2',
        'creator': {
          'name': 'NetTrace',
          'version': '1.0.0',
        },
        'pages': [],
        'entries': records.map((r) => _recordToEntry(r)).toList(),
      },
    };
    return const JsonEncoder.withIndent('  ').convert(har);
  }

  /// 单条记录转 HAR entry
  static Map<String, dynamic> _recordToEntry(CaptureRecord record) {
    final req = record.request;
    final res = record.response;

    final entry = {
      'startedDateTime': record.timestamp.toUtc().toIso8601String(),
      'time': res?.duration?.inMilliseconds ?? 0,
      'request': {
        'method': req.method,
        'url': req.url,
        'httpVersion': 'HTTP/1.1',
        'headers': _headersToList(req.headers),
        'queryString': _queryParamsToList(req.queryParams),
        'cookies': [],
        'headersSize': -1,
        'bodySize': req.contentLength,
      },
      'response': {
        'status': res?.statusCode ?? 0,
        'statusText': res?.reasonPhrase ?? '',
        'httpVersion': 'HTTP/1.1',
        'headers': _headersToList(res?.headers ?? {}),
        'cookies': [],
        'content': {
          'size': res?.contentLength ?? 0,
          'mimeType': res?.contentType ?? '',
          'text': res?.bodyAsString ?? '',
        },
        'redirectURL': '',
        'headersSize': -1,
        'bodySize': res?.contentLength ?? 0,
      },
      'cache': {},
      'timings': {
        'send': 0,
        'wait': res?.duration?.inMilliseconds ?? 0,
        'receive': 0,
      },
    };

    // 请求 body
    if (req.body != null && req.body!.isNotEmpty) {
      final requestMap = entry['request'] as Map<String, dynamic>;
      requestMap['postData'] = {
        'mimeType': req.contentType ?? '',
        'text': req.bodyAsString,
      };
    }

    return entry;
  }

  static List<Map<String, String>> _headersToList(Map<String, String> headers) {
    return headers.entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList();
  }

  static List<Map<String, String>> _queryParamsToList(Map<String, String>? params) {
    if (params == null) return [];
    return params.entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList();
  }

  /// 导出到临时文件，返回文件路径
  static Future<String> exportToFile(List<CaptureRecord> records) async {
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/nettrace_$timestamp.har');
    file.writeAsStringSync(exportToHar(records));
    return file.path;
  }
}
