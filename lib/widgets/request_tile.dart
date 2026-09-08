import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/capture_record.dart';
import '../utils/format_utils.dart';
import 'status_badge.dart';

/// 抓包请求列表项
class RequestTile extends StatelessWidget {
  final CaptureRecord record;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isFavorite;

  const RequestTile({
    super.key,
    required this.record,
    this.onTap,
    this.onLongPress,
    this.isFavorite = false,
  });

  @override
  Widget build(BuildContext context) {
    final methodColor = AppTheme.methodColor(record.method);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 方法标签
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(
                color: methodColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                record.method,
                style: TextStyle(
                  color: methodColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 主内容
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // URL 路径
                  Text(
                    FormatUtils.truncateUrl(record.url, maxLength: 100),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 域名 + 时间
                  Row(
                    children: [
                      Icon(
                        record.isHttps ? Icons.lock : Icons.http,
                        size: 12,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          record.host,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        FormatUtils.formatTime(record.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 底部信息行
                  Row(
                    children: [
                      StatusBadge(
                        statusCode: record.statusCode,
                        error: record.error,
                        fontSize: 10,
                      ),
                      const SizedBox(width: 8),
                      if (record.duration != null)
                        Text(
                          FormatUtils.formatDuration(record.duration),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        FormatUtils.formatBytes(record.responseSize),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      const Spacer(),
                      if (isFavorite)
                        const Icon(
                          Icons.star,
                          size: 14,
                          color: Colors.amber,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            // 箭头
            Icon(
              Icons.chevron_right,
              size: 18,
              color: Colors.grey[400],
            ),
          ],
        ),
      ),
    );
  }
}
