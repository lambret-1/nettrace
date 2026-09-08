import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/filter_result.dart';

/// 筛选页 - 按方法、状态码筛选
class FilterScreen extends StatefulWidget {
  final String? currentMethod;
  final String? currentStatus;

  const FilterScreen({
    super.key,
    this.currentMethod,
    this.currentStatus,
  });

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  String? _selectedMethod;
  String? _selectedStatus;

  final List<String> _methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'];
  final List<String> _statuses = ['2xx', '3xx', '4xx', '5xx'];

  @override
  void initState() {
    super.initState();
    _selectedMethod = widget.currentMethod;
    _selectedStatus = widget.currentStatus;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('筛选'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _selectedMethod = null;
                _selectedStatus = null;
              });
            },
            child: const Text('重置'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '请求方法',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _methods.map((method) {
              final selected = _selectedMethod == method;
              return FilterChip(
                label: Text(method),
                selected: selected,
                selectedColor: AppTheme.methodColor(method).withOpacity(0.2),
                labelStyle: TextStyle(
                  color: selected ? AppTheme.methodColor(method) : null,
                  fontWeight: selected ? FontWeight.bold : null,
                ),
                onSelected: (value) {
                  setState(() {
                    _selectedMethod = value ? method : null;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          const Text(
            '状态码',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _statuses.map((status) {
              final selected = _selectedStatus == status;
              final color = _statusColor(status);
              return FilterChip(
                label: Text(status),
                selected: selected,
                selectedColor: color.withOpacity(0.2),
                labelStyle: TextStyle(
                  color: selected ? color : null,
                  fontWeight: selected ? FontWeight.bold : null,
                ),
                onSelected: (value) {
                  setState(() {
                    _selectedStatus = value ? status : null;
                  });
                },
              );
            }).toList(),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
            onPressed: () {
              Navigator.pop(
                context,
                FilterResult(
                  method: _selectedMethod,
                  status: _selectedStatus,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('应用筛选'),
          ),
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case '2xx':
        return const Color(0xFF10B981);
      case '3xx':
        return const Color(0xFF3B82F6);
      case '4xx':
        return const Color(0xFFF59E0B);
      case '5xx':
        return const Color(0xFFEF4444);
      default:
        return Colors.grey;
    }
  }
}
