import 'package:flutter/material.dart';

import '../core/theme.dart';

/// HTTP 状态码徽章
class StatusBadge extends StatelessWidget {
  final int? statusCode;
  final String? error;
  final double fontSize;

  const StatusBadge({
    super.key,
    this.statusCode,
    this.error,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return _buildBadge(
        text: '错误',
        color: Colors.red,
        bgColor: Colors.red.withOpacity(0.1),
      );
    }

    if (statusCode == null) {
      return _buildBadge(
        text: '...',
        color: Colors.grey,
        bgColor: Colors.grey.withOpacity(0.1),
      );
    }

    final color = AppTheme.statusColor(statusCode!);
    return _buildBadge(
      text: '$statusCode',
      color: color,
      bgColor: color.withOpacity(0.1),
    );
  }

  Widget _buildBadge({
    required String text,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
